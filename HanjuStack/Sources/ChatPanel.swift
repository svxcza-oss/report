import Cocoa
import WebKit

/// 바탕화면 레서를 누르면 뜨는 작은 채팅 창. 앱 큰 창은 그대로 두고 레서 위에 대화만 띄워요.
/// 페이지(index.html)는 같은 걸 쓰고 `hanjuChatOnly`로 채팅만 보여줘요. 저장·도구는 큰 창과 같은 길(AppDelegate)로 가요.
final class ChatPanel: NSObject, WKNavigationDelegate {
    /// 앱을 앞으로 가져오지 않고도 글자를 칠 수 있는 창 (Spotlight처럼).
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    let panel: Panel
    let web: WKWebView
    private(set) var chat: ChatBridge!
    private var loaded = false
    private var pending: [String] = []
    var onClose: (() -> Void)?

    init(handler: WKScriptMessageHandler, state: [String: Any]?) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
                      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 300, height: 360)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let frost = NSVisualEffectView()
        frost.material = .popover
        frost.blendingMode = .behindWindow
        frost.state = .active
        panel.contentView = frost

        let config = WKWebViewConfiguration()
        config.userContentController.add(handler, name: "native")
        let json = state.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        config.userContentController.addUserScript(WKUserScript(source: "window.hanjuChatOnly = true; window.savedState = \(json);",
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: config)
        web.underPageBackgroundColor = .clear
        web.translatesAutoresizingMaskIntoConstraints = false
        frost.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: frost.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: frost.trailingAnchor),
            web.topAnchor.constraint(equalTo: frost.topAnchor, constant: 22),
            web.bottomAnchor.constraint(equalTo: frost.bottomAnchor),
        ])
        super.init()
        web.navigationDelegate = self
        chat = ChatBridge(web: web)
        let page = Bundle.main.url(forResource: "index", withExtension: "html")!
        let html = (try? String(contentsOf: page, encoding: .utf8)) ?? ""
        web.loadHTMLString("<!doctype html>\n<html lang=\"ko\">\n" + html, baseURL: page.deletingLastPathComponent())
    }

    /// 레서 바로 위에 띄워요 (화면 밖으로 안 나가게).
    func show(above anchor: NSRect?) {
        let screen = NSScreen.screens.first { anchor.map { s in $0.frame.intersects(s) } ?? false } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var frame = panel.frame
        if let anchor {
            frame.origin.x = anchor.midX - frame.width / 2
            frame.origin.y = anchor.maxY + 6
        } else {
            frame.origin.x = area.maxX - frame.width - 24
            frame.origin.y = area.minY + 24
        }
        frame.origin.x = min(max(frame.origin.x, area.minX + 8), area.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.origin.y, area.minY + 8), area.maxY - frame.height - 8)
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        run("window.hanjuOpenChat && window.hanjuOpenChat()")
    }

    var isVisible: Bool { panel.isVisible }

    func close() {
        panel.orderOut(nil)
        onClose?()
    }

    /// 큰 창이나 위젯·다른 기기에서 바뀐 계획을 채팅 창에도.
    func load(_ state: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        run("window.hanjuLoad && window.hanjuLoad(\(text))")
    }

    func run(_ js: String) {
        if loaded { web.evaluateJavaScript(js) } else { pending.append(js) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.isFileURL == true || url?.scheme == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        let queued = pending; pending = []
        queued.forEach { web.evaluateJavaScript($0) }
    }
}
