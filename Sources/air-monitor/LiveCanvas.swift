import SwiftUI
import AppKit
import CoreVideo
import yaCore

/// NSView с CVDisplayLink — тик отрисовки синхронно с экраном и ВНЕ
/// коалесценции event-loop. Ключевое отличие от SwiftUI TimelineView:
/// график обновляется даже когда окно активно и event-loop занят
/// обработкой событий мыши — именно это было причиной «пропадающей» АЧХ.
final class LiveCanvasNSView: NSView {
    var drawer: ((CGContext, CGSize) -> Void)?
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

    func frameTick() {
        stateLock.lock()
        let shouldDraw = window != nil && !isHiddenOrHasHiddenAncestor
        stateLock.unlock()
        guard shouldDraw, let drawer else { return }

        // Троттлинг кадров.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRenderTime >= minFrameInterval else { return }
        lastRenderTime = now

        let scale = window?.backingScaleFactor ?? 2
        let w = max(1, Int(bounds.width * scale))
        let h = max(1, Int(bounds.height * scale))

        // Переиспользуем контекст, пересоздаём только при изменении размера.
        bitmapLock.lock()
        if bitmapCtx == nil || bitmapSize.w != w || bitmapSize.h != h {
            bitmapCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            bitmapSize = (w, h)
        }
        let ctx = bitmapCtx
        bitmapLock.unlock()
        guard let ctx else { return }

        // CGContext битмапа: Y снизу-вверх, как в AppKit. Флип для совместимости.
        // Очистка от предыдущего кадра (контекст переиспользуется — без этого
        // кадры накапливаются: линии «размножаются», изображение контрастнеет).
        ctx.clear(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        ctx.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 0, 0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))

        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)

        drawer(ctx, bounds.size)
        ctx.restoreGState()

        if let image = ctx.makeImage() {
            DispatchQueue.main.async { [weak self] in
                self?.layer?.contents = image
                self?.layer?.contentsGravity = .resize
            }
        }
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
    let makeDrawer: () -> (CGContext, CGSize) -> Void

    func makeNSView(context: Context) -> LiveCanvasNSView {
        let v = LiveCanvasNSView(frame: .zero)
        v.drawer = makeDrawer()
        return v
    }

    func updateNSView(_ nsView: LiveCanvasNSView, context: Context) {
        nsView.drawer = makeDrawer()
        nsView.needsDisplay = true
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
