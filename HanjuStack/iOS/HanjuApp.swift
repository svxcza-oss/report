import SwiftUI
import UIKit
import WebKit
import WidgetKit

// 한 주 쌓기 — 아이폰·아이패드. 화면은 맥과 같은 웹 페이지(index.html)이고,
// 저장은 위젯과 같은 App Group 파일(HanjuStore)을 써요. 레서 채팅도 맥과 같아요.

@main
struct HanjuApp: App {
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            BoardView()
                .ignoresSafeArea()
                .onOpenURL { BoardController.shared.open($0) }
                .onChange(of: phase) { _, now in
                    if now == .active { BoardController.shared.becameActive() }
                }
        }
    }
}

struct BoardView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BoardController { BoardController.shared }
    func updateUIViewController(_ controller: BoardController, context: Context) {}
}

final class BoardController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = BoardController()

    private var web: WKWebView!
    private var store: HanjuStore!
    private var chat: ChatBridge?
    private var cloud: CloudSync?
    private var loaded = false
    private var pending: [String] = []
    private var lastRevision = -1
    private var watcher: Timer?

    override func loadView() {
        var initial: [String: Any]?
        do {
            store = try HanjuStore.production()
        } catch {
            // 서명 없이 빌드한 시뮬레이터처럼 App Group이 없으면 앱 안에만 저장해요 (위젯과는 공유되지 않아요).
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            store = HanjuStore(url: folder.appendingPathComponent("HanjuStack/state.json"))
        }
        // 맥 ↔ 아이폰 iCloud 동기화: 화면을 띄우기 전에 더 새로운 쪽으로 맞춰요.
        cloud = CloudSync(store: store)
        cloud?.onApplied = { [weak self] in
            self?.lastRevision = -1; self?.pull(); WidgetCenter.shared.reloadAllTimelines()
        }
        cloud?.start()
        initial = try? store.read()
        lastRevision = HanjuStore.revision(initial)

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "native")
        let state = initial.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        config.userContentController.addUserScript(WKUserScript(source: "window.hanjuPlatform = 'ios'; window.savedState = \(state);",
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.scrollView.contentInsetAdjustmentBehavior = .never   // 페이지가 safe-area를 직접 맞춰요
        web.allowsLinkPreview = false
        view = web
        chat = ChatBridge(web: web)

        let page = Bundle.main.url(forResource: "index", withExtension: "html")!
        let html = (try? String(contentsOf: page, encoding: .utf8)) ?? ""
        web.loadHTMLString("<!doctype html>\n<html lang=\"ko\">\n" + html, baseURL: page.deletingLastPathComponent())
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        WidgetCenter.shared.reloadAllTimelines()
        watcher?.invalidate()
        // 앱이 켜져 있는 동안 위젯에서 체크한 것을 1~2초 안에 가져와요.
        watcher = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.pull() }
    }

    // MARK: 페이지 ↔ 저장

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        if chat?.handle(body) == true { return }   // 레서 채팅
        guard body["action"] as? String == "save", let state = body["state"] as? [String: Any] else { return }
        do {
            let saved = try store.update(expected: HanjuStore.revision(state)) { _ in state }
            lastRevision = HanjuStore.revision(saved)
            cloud?.push(saved)
            run("window.hanjuDidSave && window.hanjuDidSave(\(lastRevision))")
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            run("window.hanjuSaveRejected && window.hanjuSaveRejected()")
            lastRevision = -1
            pull()
            if (error as? HanjuStore.StoreError) != .stale { show(error) }
        }
    }

    func becameActive() {
        cloud?.reconcile()
        pull()
    }

    func pull() {
        guard loaded, let store, let state = try? store.read() else { return }
        let revision = HanjuStore.revision(state)
        guard revision != lastRevision else { return }
        cloud?.localChanged(state)   // 위젯에서 바뀐 것도 맥으로
        guard
              let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.hanjuLoad && window.hanjuLoad(\(text))") { [weak self] value, error in
            if error == nil, value as? Bool == true { self?.lastRevision = revision }
        }
    }

    private func show(_ error: Error) {
        let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func run(_ js: String) {
        if loaded { web.evaluateJavaScript(js) } else { pending.append(js) }
    }

    // hanju://day/2026-11-02 (위젯의 요일 이름) → 그 주를 보여줘요.
    func open(_ url: URL) {
        guard url.scheme == "hanju" else { return }
        if url.host == "todo" {   // 위젯의 + : 할 일 입력칸으로
            run("window.hanjuAddTodo && window.hanjuAddTodo('\(url.lastPathComponent == "week" ? "week" : "day")')")
            return
        }
        guard url.host == "day" else { return }
        let day = url.lastPathComponent
        if day.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil {
            run("window.hanjuShowDate && window.hanjuShowDate('\(day)')")
        }
    }

    // MARK: 탐색

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.isFileURL == true || url?.scheme == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        let queued = pending
        pending = []
        queued.forEach { web.evaluateJavaScript($0) }
    }
}
