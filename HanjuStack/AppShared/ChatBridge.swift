import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 페이지의 레서 채팅 메시지(chat / aiKey / aiStatus)와 링크 열기(openURL)를 처리해요. 맥·아이폰 앱이 같이 써요.
final class ChatBridge: @unchecked Sendable {
    weak var web: WKWebView?

    init(web: WKWebView?) { self.web = web }

    /// Returns true when the message belonged to the chat.
    func handle(_ body: [String: Any]) -> Bool {
        switch body["action"] as? String {
        case "aiStatus":
            sendStatus()
        case "aiKey":
            let provider = body["provider"] as? String ?? ""
            guard provider == "anthropic" || provider == "openai" else { return true }
            KeyStore.set(provider, (body["key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            sendStatus()
        case "chat":
            let id = body["id"] as? Int ?? (body["id"] as? NSNumber)?.intValue ?? 0
            let provider = body["provider"] as? String ?? "auto"
            let models = body["models"] as? [String: String] ?? [:]
            let context = body["context"] as? [String: Any] ?? [:]
            let turns = (body["turns"] as? [[String: Any]] ?? []).compactMap { row -> LesserTurn? in
                guard let text = row["text"] as? String else { return nil }
                return LesserTurn(fromUser: row["role"] as? String == "me", text: String(text.prefix(2000)))
            }
            let run: LesserToolRunner = { [weak self] name, args in await self?.runTool(name, args) ?? "{\"error\":\"app closed\"}" }
            Task {
                let reply = await LesserChat.reply(provider: provider, models: models, turns: turns, context: context, tools: run)
                var payload: [String: Any] = ["id": id, "engine": reply.engine]
                if let text = reply.text { payload["text"] = text }
                if let note = reply.note { payload["note"] = note }
                self.call("hanjuChatEvent", payload)
            }
        case "openURL":   // 챌린지 항목의 링크 (http/https만) → 기본 브라우저로
            guard let text = body["url"] as? String, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return true }
            Task { @MainActor in
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
            }
        default:
            return false
        }
        return true
    }

    func sendStatus() {
        call("hanjuAIStatus", ["anthropic": KeyStore.get("anthropic") != nil,
                               "openai": KeyStore.get("openai") != nil,
                               "apple": LesserChat.appleState])
    }

    private func call(_ function: String, _ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor in
            self.web?.evaluateJavaScript("window.\(function) && window.\(function)(\(json))")
        }
    }

    /// Runs one tool inside the page (window.hanjuTool) and returns its JSON result.
    func runTool(_ name: String, _ args: String) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            Task { @MainActor in
                guard let web = self.web else { continuation.resume(returning: "{\"error\":\"app closed\"}"); return }
                web.callAsyncJavaScript("return window.hanjuTool(name, args)", arguments: ["name": name, "args": args],
                                        in: nil, in: .page) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? String ?? "{}")
                    case .failure(let error): continuation.resume(returning: "{\"error\":\"\(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))\"}")
                    }
                }
            }
        }
    }
}
