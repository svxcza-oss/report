import Cocoa
import WebKit
import WidgetKit
import CoreText
import UniformTypeIdentifiers

// Sandboxed app and widget share one coordinated App Group store.

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var loaded = false
    var pending: [String] = []
    var uiLanguage = HanjuLanguage.system
    func text(_ ko: String, _ en: String) -> String { HanjuLanguage.text(ko, en, language: uiLanguage) }
    var lastRevision = -1
    var store: HanjuStore!
    var chat: ChatBridge?
    var cloud: CloudPlan? { CloudPlan.shared }
    var cloudTimer: Timer?
    var runningCopy: NSRunningApplication?   // 이미 켜져 있는 한 주 쌓기 (중복 실행 막기)
    var watcher: Timer?
    var clockTimer: Timer?
    lazy var lesser = MenuBarLesser()
    lazy var walker = DesktopLesser()
    var chatPanel: ChatPanel?   // 바탕화면 레서를 누르면 뜨는 작은 채팅 창

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 같은 앱이 이미 켜져 있으면(다른 위치에 깔린 복사본 포함) 그쪽을 앞으로 가져오고 이건 닫아요.
        let me = NSRunningApplication.current
        runningCopy = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.processIdentifier != me.processIdentifier }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = runningCopy {
            other.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        let initial: [String: Any]?
        do {
            store = try HanjuStore.production()
            initial = try store.read(); lastRevision = HanjuStore.revision(initial)
        }
        catch { NSAlert(error: error).runModal(); NSApp.terminate(nil); return }
        uiLanguage = HanjuLanguage.resolve(initial?["language"]); buildMenu()

        window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 1040, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = text("한 주 쌓기", "HanjuStack")
        window.minSize = NSSize(width: 600, height: 560)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("HanjuStackWindow")
        // 투명 매트: frosted window, the page draws on top without its own background.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        let frost = NSVisualEffectView()
        frost.material = .underWindowBackground
        frost.blendingMode = .behindWindow
        frost.state = .active
        window.contentView = frost

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "native")
        let state = initial.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        config.userContentController.addUserScript(WKUserScript(source: "window.savedState = \(state);",
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        chat = ChatBridge(web: web)
        web.underPageBackgroundColor = .clear
        web.translatesAutoresizingMaskIntoConstraints = false
        frost.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: frost.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: frost.trailingAnchor),
            web.topAnchor.constraint(equalTo: frost.topAnchor, constant: 28),
            web.bottomAnchor.constraint(equalTo: frost.bottomAnchor),
        ])
        let page = Bundle.main.url(forResource: "index", withExtension: "html")!
        let html = (try? String(contentsOf: page, encoding: .utf8)) ?? ""
        web.loadHTMLString("<!doctype html>\n<html lang=\"ko\">\n" + html, baseURL: page.deletingLastPathComponent())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        WidgetCenter.shared.reloadAllTimelines()

        lesser.onOpen = { [weak self] in self?.showWindow() }
        lesser.onCharacter = { [weak self] c in self?.run("window.hanjuSetMascot && window.hanjuSetMascot('\(c)')") }
        walker.playback = lesser.playback
        // 바탕화면 레서를 누르면 큰 창은 그대로 두고 레서 위에 작은 채팅 창만 떠요. 한 번 더 누르면 닫혀요.
        walker.onClick = { [weak self] in self?.toggleChatPanel() }
        // 레서 켜기/끄기는 앱 안·바탕화면이 하나로 움직여요 (저장 파일의 "lesser").
        // 메뉴 막대에서 위치를 고르면 켜지고, "끄기"를 고르면 앱 안 레서도 같이 숨어요.
        lesser.onPlace = { [weak self] place in
            guard let self else { return }
            if place != .off { UserDefaults.standard.set(place.rawValue, forKey: "desktopLesser") }
            self.applyLesserPlace(on: place != .off)
            self.run("window.hanjuSetLesser && window.hanjuSetLesser(\(place != .off))")
        }
        refreshLesser()
        // The 레서 works while a block's time is running, so look again as the clock moves.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshLesser() }

        // 맥 ↔ 아이폰 iCloud 동기화: 다른 기기에서 바뀌면 조용한 알림으로, 켜져 있는 동안은 20초마다도 확인해요.
        cloud?.onApplied = { [weak self] in self?.lastRevision = -1; self?.pullFromWidget() }
        cloud?.sync()
        NSApp.registerForRemoteNotifications()
        cloudTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.cloud?.sync() }

        // While the app is open, pick up widget taps within a second or two.
        watcher = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pullFromWidget()
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: text("계획 가져오기…", "Import Plan…"), action: #selector(importPlan), keyEquivalent: "o")
        appMenu.addItem(withTitle: text("계획 백업 내보내기…", "Export Plan Backup…"), action: #selector(exportPlan), keyEquivalent: "s")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: text("한 주 쌓기 종료", "Quit HanjuStack"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: text("편집", "Edit"))
        for (title, sel, key) in [("실행 취소", "undo:", "z"), ("잘라내기", "cut:", "x"), ("복사", "copy:", "c"),
                                  ("붙여넣기", "paste:", "v"), ("전체 선택", "selectAll:", "a")] {
            edit.addItem(withTitle: text(title, ["실행 취소":"Undo","잘라내기":"Cut","복사":"Copy","붙여넣기":"Paste","전체 선택":"Select All"][title] ?? title), action: Selector(sel), keyEquivalent: key)
        }
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // The page's copy is merged item by item into the shared file, so widget or other-device edits are kept.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        let panel = chatPanel.flatMap { message.webView === $0.web ? $0 : nil }   // 작은 채팅 창에서 왔는지
        if body["action"] as? String == "closeChat" { panel?.close(); return }
        if (panel?.chat ?? chat)?.handle(body) == true { return }   // 레서 채팅
        guard body["action"] as? String == "save", let state = body["state"] as? [String: Any] else { return }
        let reply: (String) -> Void = { [weak self] js in if let panel { panel.run(js) } else { self?.run(js) } }
        do {
            let saved = try store.update { current in PlanMerge.merge(current, state) ?? state }
            let revision = HanjuStore.revision(saved)
            reply("window.hanjuDidSave && window.hanjuDidSave(\(revision))")
            if panel != nil {
                lastRevision = -1; pullFromWidget()          // 채팅 창에서 바꾼 걸 큰 창에도
            } else {
                lastRevision = revision
                if !PlanMerge.same(saved, state) { lastRevision = -1; pullFromWidget() }   // 합쳐진 내용을 화면에도
                if chatPanel?.isVisible == true { chatPanel?.load(saved) }
            }
            WidgetCenter.shared.reloadAllTimelines(); refreshLesser()
            cloud?.sync()
        } catch {
            reply("window.hanjuSaveRejected && window.hanjuSaveRejected()")
            lastRevision = -1; pullFromWidget(); showError(error)
        }
    }

    func toggleChatPanel() {
        if let chatPanel, chatPanel.isVisible { chatPanel.close(); return }
        if chatPanel == nil { chatPanel = ChatPanel(handler: self, state: try? store.read()) }
        else if let state = try? store.read() { chatPanel?.load(state) }
        chatPanel?.show(above: walker.frame)
    }

    func pullFromWidget() {
        do {
            guard let state = try store.read() else { return }
            let revision = HanjuStore.revision(state)
            guard revision != lastRevision else { return }
            if lastRevision >= 0 { cloud?.sync() }   // 위젯에서 바뀐 것도 아이폰으로
            let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else { return }
            if chatPanel?.isVisible == true { chatPanel?.load(state) }
            guard loaded else { return }
            web.evaluateJavaScript("window.hanjuLoad && window.hanjuLoad(\(text))") { [weak self] value, error in
                if error == nil, value as? Bool == true { self?.lastRevision = revision; self?.refreshLesser() }
            }
        } catch { NSLog("Shared state read failed: %@", error.localizedDescription) }
    }

    func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @objc func importPlan() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.message = text("이전 한 주 쌓기의 state.json 또는 백업 파일을 선택하세요. 현재 계획은 교체 전에 자동 백업돼요.", "Choose a previous state.json or backup. Your current plan is backed up before importing.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let imported = try HanjuStore.decode(Data(contentsOf: url))
                _ = try self.store.update { old in
                    if let old {
                        let backup = self.store.url.deletingLastPathComponent().appendingPathComponent("before-import-" + UUID().uuidString + ".json")
                        try JSONSerialization.data(withJSONObject: old).write(to: backup, options: .atomic)
                    }
                    return imported
                }
                self.lastRevision = -1; self.pullFromWidget(); WidgetCenter.shared.reloadAllTimelines()
                let count = (imported["blocks"] as? [Any])?.count ?? 0, weekly = (imported["fixed"] as? [Any])?.count ?? 0
                let done = NSAlert()
                done.messageText = "가져왔어요"
                done.informativeText = "블록 \(count)개, 매주 고정 \(weekly)개를 불러왔어요." + (count + weekly == 0 ? " 이 파일은 비어 있어요. 다른 파일을 골라 보세요." : "")
                done.beginSheetModal(for: self.window)
            } catch { self.showError(error) }
        }
    }

    @objc func exportPlan() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "hanju-backup.json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                guard let state = try self.store.read() else { throw HanjuStore.StoreError.invalidData }
                try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            } catch { self.showError(error) }
        }
    }

    /// Menu bar 레서 + window look follow the saved state (character, 절전/라이트).
    func refreshLesser() {
        let root = (try? store.read()) ?? [:]
        let language = HanjuLanguage.resolve(root["language"])
        if language != uiLanguage { uiLanguage = language; buildMenu() }
        window?.title = text("한 주 쌓기", "HanjuStack")
        lesser.character = root["mascot"] as? String == "passion" ? "passion" : "planner"
        let saver = root["theme"] as? String == "saver"
        walker.character = lesser.character
        if let ch = Challenge.today(root["challenges"] as? [[String: Any]] ?? []), ch.state == "active" {
            walker.vessel = (ch.vessel, ch.percent)
        } else {
            walker.vessel = nil
        }
        applyLesserPlace(on: root["lesser"] as? Bool != false)
        if root["theme"] != nil { window?.appearance = NSAppearance(named: saver ? .darkAqua : .aqua) }
        lesser.update(root)
    }

    /// 바탕화면 레서가 어디서 걷는지 (바탕화면 / 모든 창 위). 끈 동안에도 고른 위치는 기억해요.
    var desktopSpot: DesktopLesserPlace {
        let saved = DesktopLesserPlace(rawValue: UserDefaults.standard.string(forKey: "desktopLesser") ?? "") ?? .desktop
        return saved == .off ? .desktop : saved
    }

    func applyLesserPlace(on: Bool) {
        let place: DesktopLesserPlace = on ? desktopSpot : .off
        walker.place = place
        lesser.place = place
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

    func run(_ js: String) {
        if loaded { web.evaluateJavaScript(js) } else { pending.append(js) }
    }

    // hanju://day/2026-10-29 (a weekday name in the widget) opens that week.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let other = runningCopy, let appURL = other.bundleURL {   // 중복 실행이면 켜져 있는 쪽으로 넘겨요
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        guard let url = urls.first, url.scheme == "hanju" else { return }
        if url.host == "todo" {   // 위젯의 + : 할 일 입력칸으로
            showWindow()
            run("window.hanjuAddTodo && window.hanjuAddTodo('\(url.lastPathComponent == "week" ? "week" : "day")')")
            return
        }
        if url.host == "challenge" {   // 위젯의 챌린지 칸
            showWindow()
            run("window.hanjuShowChallenge && window.hanjuShowChallenge()")
            return
        }
        guard url.host == "day" else { return }
        showWindow()
        let day = url.lastPathComponent
        if day.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil {
            run("window.hanjuShowDate && window.hanjuShowDate('\(day)')")
        }
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard runningCopy == nil, store != nil else { return }
        cloud?.sync(); pullFromWidget()
    }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) { cloud?.sync() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window != nil { showWindow() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
