import SwiftUI
import AppKit
import CoreVideo

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

    /// Вызывается с display-link потока — только пометка перерисовки
    /// (draw происходит на main через needsDisplay).
    func frameTick() {
        stateLock.lock()
        let shouldDraw = window != nil && !isHiddenOrHasHiddenAncestor
        stateLock.unlock()
        if shouldDraw {
            DispatchQueue.main.async { [weak self] in
                self?.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        drawer?(ctx, bounds.size)
        ctx.restoreGState()
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
