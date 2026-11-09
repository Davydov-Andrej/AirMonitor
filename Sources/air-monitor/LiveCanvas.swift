import SwiftUI
import AppKit
import CoreVideo
import yaCore

/// NSView с CVDisplayLink — тик отрисовки синхронно с экраном и ВНЕ
/// коалесценции event-loop. Ключевое отличие от SwiftUI TimelineView:
/// график обновляется даже когда окно активно и event-loop занят
/// обработкой событий мыши — именно это было причиной «пропадающей» АЧХ.
final class LiveCanvasNSView: NSView {
    /// Замыкание отрисовки: пишется с main (updateNSView), читается на
    /// display-link потоке — под локом (замыкание — не атомарный тип).
    private var drawerStorage: ((CGContext, CGSize, CGPoint?, String) -> Void)?

    /// Отрисовка динамики: ctx, размер, позиция мыши (или nil), текст hover-подсказки.
    var drawer: ((CGContext, CGSize, CGPoint?, String) -> Void)?

    // Контекст для CGChart.drawText (DL-поток ставит, CoreText читает).
    private func setCurrentDrawContext(_ ctx: CGContext?) {
        currentDrawContextLock.lock()
        currentDrawContext = ctx
        currentDrawContextLock.unlock()
    }

    // Hover-состояние: пишется с main (mouseMoved), читается с DL-потока — под локом.
    // ВАЖНО: замыкание-провайдер текста — MainActor-isolated (создаётся в View.body),
    // поэтому ВЫЗЫВАЕТСЯ ТОЛЬКО на main (в mouseMoved). DL-поток читает ГОТОВЫЙ текст
    // из hoverTextCache — иначе dispatch_assert_queue краш (v0.9.17 регрессия).
    private var hoverStorage: CGPoint?
    private let hoverLock = NSLock()
    var hoverPointSafe: CGPoint? {
        get { hoverLock.lock(); defer { hoverLock.unlock() }; return hoverStorage }
        set { hoverLock.lock(); hoverStorage = newValue; hoverLock.unlock() }
    }
    private var hoverTextStorage: ((CGPoint) -> String)?
    private var hoverTextCache: String = ""
    private let hoverTextLock = NSLock()
    var hoverTextProviderSafe: ((CGPoint) -> String)? {
        get { hoverTextLock.lock(); defer { hoverTextLock.unlock() }; return hoverTextStorage }
        set { hoverTextLock.lock(); hoverTextStorage = newValue; hoverTextLock.unlock() }
    }

    /// main-поток: обновить позицию мыши и пересчитать текст подсказки.
    private func updateHover(on mainPoint: CGPoint) {
        let provider = hoverTextProviderSafe
        let text = provider?(mainPoint) ?? ""
        hoverLock.lock()
        hoverStorage = mainPoint
        hoverLock.unlock()
        hoverTextLock.lock()
        hoverTextCache = text
        hoverTextLock.unlock()
    }

    /// DL-поток: готовый текст для отрисовки.
    private func cachedHoverText() -> String {
        hoverTextLock.lock()
        defer { hoverTextLock.unlock() }
        return hoverTextCache
    }
    private let drawerLock = NSLock()
    nonisolated(unsafe) private var displayLink: CVDisplayLink?
    private let proxy = DisplayLinkProxy()
    private let stateLock = NSLock()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        proxy.view = self

        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
        CVDisplayLinkSetOutputHandler(link) { [proxy] _, _, _, _, _ in
            proxy.tick()
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
        displayLink = link
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Colorspace экрана — чтобы makeImage() не гонял цветоконверсию.
        if let screen = window?.screen ?? NSScreen.main {
            cachedColorSpace = screen.colorSpace?.cgColorSpace
        }
        stateLock.lock()
        let link = self.displayLink
        let visible = window != nil
        stateLock.unlock()
        guard let link else { return }
        if visible {
            if !CVDisplayLinkIsRunning(link) { CVDisplayLinkStart(link) }
        } else {
            if CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
        }
    }

    /// Вызывается с display-link потока: рендерим в offscreen bitmap и
    /// выставляем layer.contents. Полностью асинхронно — event-loop и активность
    /// окна не влияют на частоту обновления графика.
    ///
    /// Троттлинг: 30 Гц вместо 60 — bitmap-конвейер (makeImage + CA-текстура)
    /// дорог: 60 Гц × 4 графика × ~1 МБ = 240 МБ/с через window server,
    /// что грузит main на 35% и вызывает пропуски отрисовки.
    private var lastRenderTime: CFAbsoluteTime = 0
    private let minFrameInterval: CFAbsoluteTime = 1.0 / 30.0
    /// Переиспользуемый bitmap-контекст (без аллокации на каждый кадр).
    private var bitmapCtx: CGContext?
    private var bitmapSize: (w: Int, h: Int) = (0, 0)
    private let bitmapLock = NSLock()
    /// Colorspace layer'а/экрана: создание битмапа в нём исключает
    /// цветоконверсию (vImage AnyToAny — 21% main в профиле).
    /// Пишется на main (viewDidMoveToWindow), читается на link-потоке.
    nonisolated(unsafe) private var cachedColorSpace: CGColorSpace?
    /// Фоновый слой (сетка+подписи): рисуется один раз, blit-ится в каждый кадр.
    /// Снимает ~40% стоимости кадра (текст — самая дорогая часть отрисовки).
    private var backgroundLayer: CGImage?
    private var needsBackgroundRedraw = true
    /// Рендер статичного фона (сетка/подписи), задаётся вместе с drawer.
    var backgroundRenderer: ((_ ctx: CGContext, _ size: CGSize) -> Void)?
    /// Версия данных: кадр рисуется только если версия изменилась.
    var versionProvider: (() -> Int)?
    private var lastDrawnVersion: Int = -1

    func frameTick() {
        stateLock.lock()
        let shouldDraw = window != nil && !isHiddenOrHasHiddenAncestor
        stateLock.unlock()
        guard shouldDraw, let drawer else { return }

        // Троттлинг кадров.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRenderTime >= minFrameInterval else { return }

        // Пропуск кадров без новых данных: publish 15 Гц, display-link 30 Гц —
        // иначе половина кадров перерисовывает одинаковый битмап (x N шин).
        if let vp = versionProvider {
            let v = vp()
            if v == lastDrawnVersion { return }
            lastDrawnVersion = v
        }
        lastRenderTime = now

        // Рендер в 1x (не Retina 2x): линии 1px на графике всё равно сглаживаются,
        // а пикселей в 4 раза меньше — clear/blit/текстура дешевле вчетверо.
        // CoreAnimation масштабирует содержимое без потерь для такого контента.
        let scale: CGFloat = 1
        let w = max(1, Int(bounds.width * scale))
        let h = max(1, Int(bounds.height * scale))

        // Переиспользуем контекст, пересоздаём только при изменении размера.
        bitmapLock.lock()
        if bitmapCtx == nil || bitmapSize.w != w || bitmapSize.h != h {
            let space = cachedColorSpace ?? CGColorSpaceCreateDeviceRGB()
            bitmapCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            bitmapSize = (w, h)
            needsBackgroundRedraw = true
        }
        let ctx = bitmapCtx
        bitmapLock.unlock()
        guard let ctx else { return }

        // CGContext битмапа: Y снизу-вверх, как в AppKit. Флип для совместимости.
        // Очистка от предыдущего кадра (контекст переиспользуется — без этого
        // кадры накапливаются: линии «размножаются», изображение контрастнеет).
        // clear() обнуляет байты напрямую (memset) — без alpha-blend.
        ctx.clear(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))

        // Blit закэшированного фона (сетка+подписи) вместо его перерисовки.
        if needsBackgroundRedraw || backgroundLayer == nil {
            if let bgRenderer = backgroundRenderer {
                // Фон рисуется в ТЕХ ЖЕ координатах, что и динамика (флип).
                ctx.saveGState()
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: scale, y: -scale)
                bgRenderer(ctx, bounds.size)
                ctx.restoreGState()
                backgroundLayer = ctx.makeImage()
                needsBackgroundRedraw = false
                ctx.clear(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            }
        }
        if let bg = backgroundLayer {
            // bg уже в экранных координатах — рисуем напрямую, без флипа.
            ctx.draw(bg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        }

        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)

        let cachedText = cachedHoverText()
        let cachedPoint = hoverPointSafe
        // Текст рисуется CoreText-ом через этот контекст (CGChart.drawText).
        setCurrentDrawContext(ctx)
        drawer(ctx, bounds.size, cachedPoint, cachedText)
        setCurrentDrawContext(nil)
        ctx.restoreGState()

        // ВАЖНО: makeImage() копирует буфер — это обязательная цена безопасности.
        // Zero-copy вариант (CGDataProvider поверх ctx.data) вызывал SEGFAULT:
        // CA читала память с display-link потока, пока мы её перезаписывали
        // следующим кадром (краш: CGDataProvider_BufferIsNotReadable).
        if let image = ctx.makeImage() {
            // Прямой CA-коммит с display-link потока: полностью минует event-loop.
            // (Предыдущий «чёрный экран» был скриншотом заблокированного Мака,
            // не глюком приложения — проверено с пользователем.)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer?.contents = image
            self.layer?.contentsGravity = .resize
            CATransaction.commit()
        }
    }

    // MARK: - Hover (позиция мыши внутри вью)

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        updateHover(on: local)  // main-поток: провайдер вызывается здесь
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoverPointSafe = nil
    }

    // mouseMoved-события включаются через tracking area (activeInKeyWindow)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.options.contains(.mouseMoved) {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    deinit {
        let link = displayLink
        if let link {
            CVDisplayLinkStop(link)
        }
    }
}

/// Прокси для CVDisplayLink-колбэка (вызывается с display-link потока).
private final class DisplayLinkProxy: NSObject {
    weak var view: LiveCanvasNSView?

    func tick() {
        view?.frameTick()
    }
}

/// SwiftUI-обёртка над LiveCanvasNSView.
/// `makeDrawer` должен захватывать ЖИВЫЕ источники данных (holder), а не снимки:
/// замыкание создаётся один раз, и drawer сам читает свежие данные каждый кадр.
struct LiveCanvas: NSViewRepresentable {
    let makeDrawer: () -> (CGContext, CGSize, CGPoint?, String) -> Void
    var makeBackground: (() -> (CGContext, CGSize) -> Void)?
    /// Источник версии данных: nil = рисовать каждый кадр.
    var dataVersion: (() -> Int)?
    /// Текст hover-подсказки для точки (в координатах вью). nil = нет подсказки.
    var hoverText: ((_ localPoint: CGPoint) -> String)?

    init(makeDrawer: @escaping () -> (CGContext, CGSize, CGPoint?, String) -> Void,
         makeBackground: (() -> (CGContext, CGSize) -> Void)? = nil,
         dataVersion: (() -> Int)? = nil,
         hoverText: ((_ localPoint: CGPoint) -> String)? = nil) {
        self.makeDrawer = makeDrawer
        self.makeBackground = makeBackground
        self.dataVersion = dataVersion
        self.hoverText = hoverText
    }

    func makeNSView(context: Context) -> LiveCanvasNSView {
        let v = LiveCanvasNSView(frame: .zero)
        v.drawer = makeDrawer()
        v.backgroundRenderer = makeBackground?()
        v.versionProvider = dataVersion
        v.hoverTextProviderSafe = hoverText
        return v
    }

    func updateNSView(_ nsView: LiveCanvasNSView, context: Context) {
        nsView.drawer = makeDrawer()
        nsView.hoverTextProviderSafe = hoverText
    }
}

/// CG-хелперы отрисовки.
enum ChartCG {
    static func drawCenteredText(_ ctx: CGContext, _ text: String, in size: CGSize) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let b = str.boundingRect(with: size, options: [.usesLineFragmentOrigin])
        str.draw(at: CGPoint(x: (size.width - b.width) / 2, y: (size.height - b.height) / 2))
    }
}
