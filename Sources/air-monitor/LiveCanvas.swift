import SwiftUI
import AppKit
import CoreVideo
import yaCore

/// NSView с CVDisplayLink. Сигнал display-link coalesce-ится и отрисовка
/// запускается на main: AppKit/CoreAnimation не читаются и не меняются с
/// фонового потока, а очередь UI не заполняется кадрами при занятости main.
final class LiveCanvasNSView: NSView {
    /// Замыкание отрисовки: обновляется на main и читается display-link потоком.
    private let drawerLock = NSLock()
    private var drawerStorage: ((CGContext, CGSize, CGPoint?, String) -> Void)?
    var drawer: ((CGContext, CGSize, CGPoint?, String) -> Void)? {
        get { drawerLock.lock(); defer { drawerLock.unlock() }; return drawerStorage }
        set { drawerLock.lock(); drawerStorage = newValue; drawerLock.unlock() }
    }

    // Hover-состояние: пишется с main (mouseMoved), читается с DL-потока — под локом.
    // ВАЖНО: замыкание-провайдер текста — MainActor-isolated (создаётся в View.body),
    // поэтому ВЫЗЫВАЕТСЯ ТОЛЬКО на main (в mouseMoved). DL-поток читает ГОТОВЫЙ текст
    // из hoverTextCache — иначе dispatch_assert_queue краш (v0.9.17 регрессия).
    private var hoverStorage: CGPoint?
    private var hoverTextCache: String = ""
    private var hoverBadgeImage: CGImage?
    private var hoverBadgeScale: CGFloat = 1
    private var hoverRevision = 0
    private let hoverLock = NSLock()
    var hoverPointSafe: CGPoint? {
        get { hoverLock.lock(); defer { hoverLock.unlock() }; return hoverStorage }
        set { hoverLock.lock(); hoverStorage = newValue; hoverLock.unlock() }
    }
    private var hoverTextStorage: ((CGPoint, CGSize) -> String)?
    private let hoverTextLock = NSLock()
    var hoverTextProviderSafe: ((CGPoint, CGSize) -> String)? {
        get { hoverTextLock.lock(); defer { hoverTextLock.unlock() }; return hoverTextStorage }
        set { hoverTextLock.lock(); hoverTextStorage = newValue; hoverTextLock.unlock() }
    }

    /// main-поток: обновить позицию мыши и пересчитать текст подсказки.
    private func updateHover(on mainPoint: CGPoint, size: CGSize) {
        let provider = hoverTextProviderSafe
        let text = provider?(mainPoint, size) ?? ""
        let scale = max(1, window?.backingScaleFactor ?? 1)
        hoverLock.lock()
        let previousText = hoverTextCache
        let previousImage = hoverBadgeImage
        let previousScale = hoverBadgeScale
        hoverLock.unlock()
        let badgeWidth = min(640, max(320, CGFloat(text.count) * 6.5 + 24))
        let image: CGImage?
        if text.isEmpty {
            image = nil
        } else if text == previousText, scale == previousScale, let previousImage {
            image = previousImage
        } else {
            var rendered: CGImage?
            let drawBadge = {
                rendered = Self.renderHoverBadge(
                    text: text,
                    size: CGSize(width: badgeWidth, height: 44),
                    scale: scale,
                    space: self.colorSpaceSnapshot() ?? CGColorSpaceCreateDeviceRGB()
                )
            }
            if let drawingAppearance {
                drawingAppearance.performAsCurrentDrawingAppearance {
                    drawBadge()
                }
            } else {
                drawBadge()
            }
            image = rendered
        }
        hoverLock.lock()
        hoverStorage = mainPoint
        hoverTextCache = text
        hoverBadgeImage = image
        hoverBadgeScale = scale
        hoverRevision &+= 1
        hoverLock.unlock()
    }

    private func cachedHoverState() -> (point: CGPoint?, image: CGImage?, revision: Int) {
        hoverLock.lock()
        defer { hoverLock.unlock() }
        return (hoverStorage, hoverBadgeImage, hoverRevision)
    }
    nonisolated(unsafe) private var displayLink: CVDisplayLink?
    private let proxy = DisplayLinkProxy()
    private let stateLock = NSLock()
    private var cachedBackingScale: CGFloat = 1
    private var renderColorScheme: ColorScheme?
    private var drawingAppearance: NSAppearance?

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
        updateBackingProperties()
        guard let link = self.displayLink else { return }
        if window != nil {
            if !CVDisplayLinkIsRunning(link) { CVDisplayLinkStart(link) }
        } else if CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingProperties()
    }

    private func updateBackingProperties() {
        let scale = max(1, window?.backingScaleFactor ?? 1)
        // Экранный colorspace и backing scale: текст и линии должны растрироваться
        // сразу в плотности Retina, а не растягиваться из 1x bitmap.
        stateLock.lock()
        if let screen = window?.screen ?? NSScreen.main {
            cachedColorSpace = screen.colorSpace?.cgColorSpace
        }
        let scaleChanged = cachedBackingScale != scale
        cachedBackingScale = scale
        if scaleChanged {
            needsBackgroundRedraw = true
            backgroundLayer = nil
            backgroundRevision &+= 1
            lastDrawnVersion = -1
        }
        stateLock.unlock()
        layer?.contentsScale = scale
        if scaleChanged {
            hoverLock.lock()
            hoverBadgeImage = nil
            hoverBadgeScale = scale
            hoverRevision &+= 1
            hoverLock.unlock()
        }
    }

    /// Вызывается на main после coalescing display-link сигналов.
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
    private func colorSpaceSnapshot() -> CGColorSpace? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedColorSpace
    }
    /// Фоновый слой (сетка+подписи): рисуется один раз, blit-ится в каждый кадр.
    /// Снимает ~40% стоимости кадра (текст — самая дорогая часть отрисовки).
    private var backgroundLayer: CGImage?
    private var needsBackgroundRedraw = true
    private var bgRendering = false
    /// Рендер статичного фона (сетка/подписи), задаётся вместе с drawer.
    var backgroundRenderer: ((_ ctx: CGContext, _ size: CGSize) -> Void)?
    /// Версия данных: кадр рисуется только если версия изменилась.
    var versionProvider: (() -> Int)?
    private var lastDrawnVersion: Int = -1
    private var lastDrawnHoverRevision = -1
    private var backgroundRevision = 0
    private var lastDrawnBackgroundRevision = -1
    private var backgroundSize: CGSize = .zero

    func updateRenderAppearance(_ colorScheme: ColorScheme,
                                backgroundRenderer: ((CGContext, CGSize) -> Void)?) {
        self.backgroundRenderer = backgroundRenderer
        let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        updateDrawingAppearance(colorScheme, appearance: NSAppearance(named: appearanceName))
    }

    private func updateDrawingAppearance(_ colorScheme: ColorScheme, appearance: NSAppearance?) {
        guard renderColorScheme != colorScheme || drawingAppearance?.name != appearance?.name else { return }
        renderColorScheme = colorScheme
        drawingAppearance = appearance

        stateLock.lock()
        needsBackgroundRedraw = true
        backgroundLayer = nil
        backgroundRevision &+= 1
        stateLock.unlock()
        lastDrawnVersion = -1
        lastDrawnBackgroundRevision = -1

        hoverLock.lock()
        hoverBadgeImage = nil
        hoverRevision &+= 1
        hoverLock.unlock()
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        stateLock.lock()
        if size != backgroundSize {
            backgroundSize = size
            backgroundRevision &+= 1
            needsBackgroundRedraw = true
            backgroundLayer = nil
        }
        stateLock.unlock()
    }

    func frameTick() {
        stateLock.lock()
        let shouldDraw = window != nil && !isHiddenOrHasHiddenAncestor
        let bgRevision = backgroundRevision
        let bgNeedsRender = needsBackgroundRedraw || backgroundLayer == nil
        let bgRenderer = backgroundRenderer
        let bgRenderingNow = bgRendering
        let cachedBackground = backgroundLayer
        let scale = cachedBackingScale
        stateLock.unlock()
        guard shouldDraw, let drawer else { return }

        // Троттлинг кадров.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRenderTime >= minFrameInterval else { return }

        // Пропуск кадров без новых данных: publish 15 Гц, display-link 30 Гц —
        // иначе половина кадров перерисовывает одинаковый битмап (x N шин).
        let currentVersion = versionProvider?()
        let hover = cachedHoverState()
        if let currentVersion,
           currentVersion == lastDrawnVersion,
           hover.revision == lastDrawnHoverRevision,
           bgRevision == lastDrawnBackgroundRevision {
            return
        }
        lastRenderTime = now

        // Сохраняем логические координаты drawer-ов, но создаём bitmap в backing
        // scale окна (обычно 2x на Retina), чтобы текст и тонкие линии не мылить.
        let w = max(1, Int(bounds.width * scale))
        let h = max(1, Int(bounds.height * scale))

        // Переиспользуем контекст, пересоздаём только при изменении размера.
        bitmapLock.lock()
        if bitmapCtx == nil || bitmapSize.w != w || bitmapSize.h != h {
            let space = colorSpaceSnapshot() ?? CGColorSpaceCreateDeviceRGB()
            bitmapCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            bitmapSize = (w, h)
            stateLock.lock()
            needsBackgroundRedraw = true
            backgroundRevision &+= 1
            stateLock.unlock()
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
        // Фон содержит ТЕКСТ (CoreText не потокобезопасен с main-шрифтовой
        // системой) — рендер фона выполняется ТОЛЬКО на main (async), DL blit-ит.
        if bgNeedsRender {
            if let bgRenderer, !bgRenderingNow {
                stateLock.lock()
                bgRendering = true
                stateLock.unlock()
                let wMain = w, hMain = h
                let sizeMain = bounds.size
                let scaleMain = scale
                let space = colorSpaceSnapshot() ?? CGColorSpaceCreateDeviceRGB()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard let bgCtx = CGContext(
                        data: nil, width: wMain, height: hMain,
                        bitsPerComponent: 8, bytesPerRow: wMain * 4,
                        space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ) else {
                        self.stateLock.lock()
                        self.bgRendering = false
                        self.stateLock.unlock()
                        return
                    }
                    bgCtx.saveGState()
                    bgCtx.translateBy(x: 0, y: CGFloat(hMain))
                    bgCtx.scaleBy(x: scaleMain, y: -scaleMain)
                    if let appearance = self.drawingAppearance {
                        appearance.performAsCurrentDrawingAppearance {
                            bgRenderer(bgCtx, sizeMain)
                        }
                    } else {
                        bgRenderer(bgCtx, sizeMain)
                    }
                    bgCtx.restoreGState()
                    let img = bgCtx.makeImage()
                    self.stateLock.lock()
                    if self.bounds.size == sizeMain, let img {
                        self.backgroundLayer = img
                        self.needsBackgroundRedraw = false
                    }
                    self.bgRendering = false
                    self.stateLock.unlock()
                }
            }
            if bgRenderer != nil { return }  // фон подготавливается на main
        }
        if let bg = cachedBackground {
            // bg уже в экранных координатах — рисуем напрямую, без флипа.
            ctx.draw(bg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        }

        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)

        if let appearance = drawingAppearance {
            appearance.performAsCurrentDrawingAppearance {
                drawer(ctx, bounds.size, nil, "")
            }
        } else {
            drawer(ctx, bounds.size, nil, "")
        }
        ctx.restoreGState()

        if let point = hover.point, let badge = hover.image {
            let badgeW = CGFloat(badge.width) / scale
            let badgeH = CGFloat(badge.height) / scale
            var x = point.x + 12
            var top = point.y + 10
            if x + badgeW > CGFloat(w) / scale { x = max(2, CGFloat(w) / scale - badgeW - 2) }
            if top + badgeH > CGFloat(h) / scale { top = max(2, point.y - badgeH - 6) }
            ctx.draw(badge, in: CGRect(x: x * scale, y: CGFloat(h) - (top + badgeH) * scale,
                                       width: CGFloat(badge.width), height: CGFloat(badge.height)))
        }

        // Коммит кадра и слой принадлежат main-потоку.
        if let image = ctx.makeImage() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer?.contents = image
            self.layer?.contentsGravity = .resize
            CATransaction.commit()
        }

        stateLock.lock()
        lastDrawnBackgroundRevision = bgRevision
        stateLock.unlock()
        if let currentVersion { lastDrawnVersion = currentVersion }
        lastDrawnHoverRevision = hover.revision
    }

    /// Рендер hover-плашки с текстом (выполняется на main — CoreText безопасен).
    static func renderHoverBadge(text: String, size: CGSize, scale: CGFloat, space: CGColorSpace) -> CGImage? {
        let scale = max(1, scale)
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        guard let ctx = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10 * scale, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let str = NSAttributedString(string: "  " + text + "  ", attributes: attrs)
        let line = CTLineCreateWithAttributedString(str)
        ctx.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(scale * 0.5)
        ctx.stroke(CGRect(x: scale * 0.25, y: scale * 0.25,
                          width: CGFloat(pixelWidth) - scale * 0.5,
                          height: CGFloat(pixelHeight) - scale * 0.5))
        ctx.textPosition = CGPoint(x: 8 * scale, y: (CGFloat(pixelHeight) - 10 * scale) / 2)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    // MARK: - Hover (позиция мыши внутри вью)

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let topDown = CGPoint(x: local.x, y: bounds.height - local.y)
        updateHover(on: topDown, size: bounds.size)  // main-поток: провайдер и CoreText выполняются здесь
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoverLock.lock()
        hoverStorage = nil
        hoverTextCache = ""
        hoverBadgeImage = nil
        hoverRevision &+= 1
        hoverLock.unlock()
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
private final class DisplayLinkProxy: NSObject, @unchecked Sendable {
    nonisolated(unsafe) weak var view: LiveCanvasNSView?
    private let lock = NSLock()
    private var mainTickScheduled = false

    func tick() {
        lock.lock()
        guard !mainTickScheduled else {
            lock.unlock()
            return
        }
        mainTickScheduled = true
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.mainTickScheduled = false
            let view = self.view
            self.lock.unlock()
            view?.frameTick()
        }
    }
}

/// SwiftUI-обёртка над LiveCanvasNSView.
/// `makeDrawer` должен захватывать ЖИВЫЕ источники данных (holder), а не снимки:
/// замыкание создаётся один раз, и drawer сам читает свежие данные каждый кадр.
struct LiveCanvas: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let makeDrawer: () -> (CGContext, CGSize, CGPoint?, String) -> Void
    var makeBackground: (() -> (CGContext, CGSize) -> Void)?
    /// Источник версии данных: nil = рисовать каждый кадр.
    var dataVersion: (() -> Int)?
    /// Текст hover-подсказки для точки (в координатах вью). nil = нет подсказки.
    var hoverText: ((_ localPoint: CGPoint, _ size: CGSize) -> String)?

    init(makeDrawer: @escaping () -> (CGContext, CGSize, CGPoint?, String) -> Void,
         makeBackground: (() -> (CGContext, CGSize) -> Void)? = nil,
         dataVersion: (() -> Int)? = nil,
         hoverText: ((_ localPoint: CGPoint, _ size: CGSize) -> String)? = nil) {
        self.makeDrawer = makeDrawer
        self.makeBackground = makeBackground
        self.dataVersion = dataVersion
        self.hoverText = hoverText
    }

    func makeNSView(context: Context) -> LiveCanvasNSView {
        let v = LiveCanvasNSView(frame: .zero)
        v.updateRenderAppearance(colorScheme, backgroundRenderer: makeBackground?())
        v.drawer = makeDrawer()
        v.versionProvider = dataVersion
        v.hoverTextProviderSafe = hoverText
        return v
    }

    func updateNSView(_ nsView: LiveCanvasNSView, context: Context) {
        nsView.updateRenderAppearance(colorScheme, backgroundRenderer: makeBackground?())
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
