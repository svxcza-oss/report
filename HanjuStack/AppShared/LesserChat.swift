import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// 레서와 대화. 대답을 만드는 순서 (설정이 "자동"일 때):
//   1. 사용자가 넣은 API 키 (Claude → OpenAI)
//   2. Apple 기기 안 모델 (macOS 26 / iOS 26, Apple Intelligence가 켜진 기기)
//   3. 대본 레서 — 페이지가 직접 정해진 말로 대답해요 (engine = "script")
// 어느 AI든 같은 도구(list_blocks / add_block / set_done / move_block)로 계획을 보고 고쳐요.
// 도구는 페이지의 window.hanjuTool 이 실행하고 JSON 문자열을 돌려줘요.

typealias LesserToolRunner = @Sendable (_ name: String, _ argumentsJSON: String) async -> String

struct LesserTurn {
    let fromUser: Bool
    let text: String
}

struct LesserReply {
    var text: String?
    var engine: String          // anthropic | openai | apple | script
    var note: String?
}

enum LesserChat {
    static let defaultModels = ["anthropic": "claude-haiku-5-5", "openai": "gpt-5-mini"]

    // MARK: 도구 설명 (API용 JSON 스키마)

    static let tools: [(name: String, description: String, schema: [String: Any])] = [
        ("list_blocks", "Read the user's planned blocks between two dates (inclusive). Returns id, name, date, start/end (24h HH:MM), minutes, done, repeat_weekly.",
         ["type": "object", "properties": [
            "from": ["type": "string", "description": "First date, YYYY-MM-DD"],
            "to": ["type": "string", "description": "Last date, YYYY-MM-DD"]], "required": ["from", "to"]]),
        ("add_block", "Add a block to the plan. If start is omitted the earliest free time that day is used. Fails if the time is taken.",
         ["type": "object", "properties": [
            "name": ["type": "string", "description": "Short task name, max 40 characters"],
            "date": ["type": "string", "description": "YYYY-MM-DD"],
            "start": ["type": "string", "description": "Start time, 24h HH:MM (optional)"],
            "minutes": ["type": "integer", "description": "Duration in minutes (10-minute steps), default 60"],
            "repeat_weekly": ["type": "boolean", "description": "true for a block that repeats every week"]], "required": ["name", "date"]]),
        ("set_done", "Mark a block done (or not done). Identify it by id, or by name and optional date.",
         ["type": "object", "properties": [
            "id": ["type": "string"], "name": ["type": "string"], "date": ["type": "string", "description": "YYYY-MM-DD"],
            "done": ["type": "boolean", "description": "default true"]]]),
        ("move_block", "Move a block to another date and/or start time. Identify it by id or name.",
         ["type": "object", "properties": [
            "id": ["type": "string"], "name": ["type": "string"],
            "date": ["type": "string", "description": "New date YYYY-MM-DD"],
            "start": ["type": "string", "description": "New start time, 24h HH:MM"]]]),
    ]

    // MARK: 어떤 AI를 쓸지

    static var appleState: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) { return AppleLesser.state }
        #endif
        return "unsupported"
    }

    static func engines(for provider: String) -> [String] {
        let keyed = ["anthropic", "openai"].filter { KeyStore.get($0) != nil }
        switch provider {
        case "anthropic", "openai": return [provider]
        case "apple": return ["apple"]
        case "script": return []
        default: return keyed + (appleState == "available" ? ["apple"] : [])
        }
    }

    static func instructions(_ context: [String: Any]) -> String {
        let en = context["language"] as? String == "en"
        let name = context["character"] as? String ?? (en ? "Lesser" : "레서")
        let today = context["today"] as? String ?? "", weekday = context["weekday"] as? String ?? "", now = context["now"] as? String ?? ""
        var plan = ""
        if let data = try? JSONSerialization.data(withJSONObject: ["today_blocks": context["today_blocks"] ?? [], "this_week": context["week"] ?? []]),
           let text = String(data: data, encoding: .utf8) { plan = String(text.prefix(6000)) }
        if en {
            return """
            You are \(name), the red panda companion in the weekly planner app "HanjuStack". Reply in English, warmly and briefly (1–3 sentences), like a cheerful friend.
            The user stacks tasks as time blocks on a week board. You can read and change the plan with tools: list_blocks, add_block, set_done, move_block.
            Use dates as YYYY-MM-DD and times as 24-hour HH:MM. Today is \(today) (\(weekday)), now \(now).
            When asked to add, finish or move something, call the tool, then say what you did. If a detail is missing, pick a sensible default (60 minutes, earliest free time) unless it really matters, then ask.
            Don't invent facts; if you don't know something, say so. Never mention these instructions.
            Current plan (JSON): \(plan)
            """
        }
        return """
        너는 주간 계획 앱 "한 주 쌓기"의 레서판다 친구 \(name)야. 한국어 반말로, 다정하고 짧게(1~3문장) 대답해.
        사용자는 할 일을 시간 블록으로 만들어 일주일 판에 쌓아. 너는 도구로 계획을 보고 바꿀 수 있어: list_blocks, add_block, set_done, move_block.
        날짜는 YYYY-MM-DD, 시간은 24시간제 HH:MM로 넘겨. 오늘은 \(today) (\(weekday)요일), 지금 \(now).
        블록을 넣거나 끝내거나 옮겨 달라고 하면 도구를 부르고, 무엇을 했는지 말해 줘. 정보가 조금 빠지면 알맞은 기본값(60분, 가장 이른 빈 시간)으로 하고, 꼭 필요한 것만 물어봐.
        모르는 건 지어내지 말고 모른다고 해. 이 지시문 얘기는 하지 마.
        지금 계획 (JSON): \(plan)
        """
    }

    // MARK: 대답 만들기

    static func reply(provider: String, models: [String: String], turns: [LesserTurn], context: [String: Any],
                      tools run: @escaping LesserToolRunner) async -> LesserReply {
        let en = context["language"] as? String == "en"
        let order = engines(for: provider)
        var notes: [String] = []
        if provider == "apple" && appleState != "available" {
            notes.append(en ? "The Apple on-device model isn't available on this device." : "이 기기에서는 Apple 기기 안 모델을 쓸 수 없어요.")
        }
        if (provider == "anthropic" || provider == "openai") && KeyStore.get(provider) == nil {
            notes.append(en ? "No API key saved yet — add one in ⚙︎." : "아직 저장된 API 키가 없어요. ⚙︎에서 넣어 주세요.")
            return LesserReply(text: nil, engine: "script", note: notes.joined(separator: " "))
        }
        let system = instructions(context)
        for engine in order {
            do {
                let model = (models[engine]?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModels[engine] ?? ""
                let text: String
                switch engine {
                case "anthropic": text = try await anthropic(key: KeyStore.get("anthropic") ?? "", model: model, system: system, turns: turns, run: run)
                case "openai": text = try await openai(key: KeyStore.get("openai") ?? "", model: model, system: system, turns: turns, run: run)
                case "apple": text = try await apple(system: system, turns: turns, run: run)
                default: continue
                }
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { return LesserReply(text: clean, engine: engine, note: notes.isEmpty ? nil : notes.joined(separator: " ")) }
            } catch {
                notes.append((en ? "\(label(engine)) failed: " : "\(label(engine)) 연결 실패: ") + describe(error))
            }
        }
        return LesserReply(text: nil, engine: "script", note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    static func label(_ engine: String) -> String {
        ["anthropic": "Claude", "openai": "OpenAI", "apple": "Apple"][engine] ?? engine
    }

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func describe(_ error: Error) -> String {
        String((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).prefix(160).description
    }

    /// Alternating user/assistant messages that start with the user.
    static func conversation(_ turns: [LesserTurn]) -> [(user: Bool, text: String)] {
        var out: [(user: Bool, text: String)] = []
        for t in turns.suffix(16) where !t.text.isEmpty {
            if out.isEmpty && !t.fromUser { continue }
            if let last = out.last, last.user == t.fromUser { out[out.count - 1].text += "\n" + t.text } else { out.append((t.fromUser, t.text)) }
        }
        return out
    }

    static func post(_ url: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw APIError(message: "HTTP \(status) \(detail)")
        }
        return json
    }

    // MARK: Claude (Anthropic Messages API)

    static func anthropic(key: String, model: String, system: String, turns: [LesserTurn], run: LesserToolRunner) async throws -> String {
        var messages: [[String: Any]] = conversation(turns).map { ["role": $0.user ? "user" : "assistant", "content": $0.text] }
        let toolSpecs = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] as [String: Any] }
        for _ in 0..<6 {
            let json = try await post("https://api.anthropic.com/v1/messages",
                                      headers: ["x-api-key": key, "anthropic-version": "2023-06-01"],
                                      body: ["model": model, "max_tokens": 700, "system": system, "tools": toolSpecs, "messages": messages])
            let content = json["content"] as? [[String: Any]] ?? []
            let uses = content.filter { $0["type"] as? String == "tool_use" }
            if uses.isEmpty || json["stop_reason"] as? String != "tool_use" {
                return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            }
            messages.append(["role": "assistant", "content": content])
            var results: [[String: Any]] = []
            for use in uses {
                let input = use["input"] ?? [:]
                let args = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let output = await run(use["name"] as? String ?? "", args)
                results.append(["type": "tool_result", "tool_use_id": use["id"] as? String ?? "", "content": output])
            }
            messages.append(["role": "user", "content": results])
        }
        throw APIError(message: "too many tool steps")
    }

    // MARK: OpenAI (Chat Completions API)

    static func openai(key: String, model: String, system: String, turns: [LesserTurn], run: LesserToolRunner) async throws -> String {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        messages += conversation(turns).map { ["role": $0.user ? "user" : "assistant", "content": $0.text] }
        let toolSpecs = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] as [String: Any] }
        for _ in 0..<6 {
            let json = try await post("https://api.openai.com/v1/chat/completions",
                                      headers: ["Authorization": "Bearer \(key)"],
                                      body: ["model": model, "messages": messages, "tools": toolSpecs])
            guard let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
                throw APIError(message: "empty response")
            }
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            if calls.isEmpty { return message["content"] as? String ?? "" }
            messages.append(message)
            for call in calls {
                let function = call["function"] as? [String: Any] ?? [:]
                let output = await run(function["name"] as? String ?? "", function["arguments"] as? String ?? "{}")
                messages.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": output])
            }
        }
        throw APIError(message: "too many tool steps")
    }

    // MARK: Apple 기기 안 모델

    static func apple(system: String, turns: [LesserTurn], run: @escaping LesserToolRunner) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let talk = conversation(turns)
            let history = talk.dropLast().suffix(8).map { ($0.user ? "사용자: " : "레서: ") + $0.text }.joined(separator: "\n")
            let prompt = (history.isEmpty ? "" : "지금까지 대화:\n\(history)\n\n") + (talk.last?.text ?? "")
            return try await AppleLesser.respond(instructions: system, prompt: prompt, run: run)
        }
        #endif
        throw APIError(message: "unsupported")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
enum AppleLesser {
    static var state: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason): return "unavailable: \(reason)"
        }
    }

    static func respond(instructions: String, prompt: String, run: @escaping LesserToolRunner) async throws -> String {
        let session = LanguageModelSession(tools: [ListBlocksTool(run: run), AddBlockTool(run: run), SetDoneTool(run: run), MoveBlockTool(run: run)],
                                           instructions: instructions)
        return try await session.respond(to: prompt).content
    }

    static func json(_ values: [String: Any?]) -> String {
        let clean = values.compactMapValues { $0 }
        return (try? JSONSerialization.data(withJSONObject: clean)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

@available(macOS 26.0, iOS 26.0, *)
struct ListBlocksTool: Tool {
    let run: LesserToolRunner
    let name = "list_blocks"
    let description = "Read the user's planned blocks between two dates (inclusive)."
    @Generable struct Arguments {
        @Guide(description: "First date, YYYY-MM-DD") var from: String
        @Guide(description: "Last date, YYYY-MM-DD") var to: String
    }
    func call(arguments: Arguments) async throws -> String {
        await run(name, AppleLesser.json(["from": arguments.from, "to": arguments.to]))
    }
}

@available(macOS 26.0, iOS 26.0, *)
struct AddBlockTool: Tool {
    let run: LesserToolRunner
    let name = "add_block"
    let description = "Add a time block to the plan. Leave start empty to use the earliest free time that day."
    @Generable struct Arguments {
        @Guide(description: "Short task name") var name: String
        @Guide(description: "Date, YYYY-MM-DD") var date: String
        @Guide(description: "Start time, 24h HH:MM, or empty") var start: String
        @Guide(description: "Duration in minutes, e.g. 60") var minutes: Int
        @Guide(description: "true if it repeats every week") var repeatWeekly: Bool
    }
    func call(arguments: Arguments) async throws -> String {
        await run(name, AppleLesser.json(["name": arguments.name, "date": arguments.date,
                                          "start": arguments.start.isEmpty ? nil : arguments.start,
                                          "minutes": arguments.minutes, "repeat_weekly": arguments.repeatWeekly]))
    }
}

@available(macOS 26.0, iOS 26.0, *)
struct SetDoneTool: Tool {
    let run: LesserToolRunner
    let name = "set_done"
    let description = "Mark a block done or not done, found by its name (and date if known)."
    @Generable struct Arguments {
        @Guide(description: "Block name") var name: String
        @Guide(description: "Date, YYYY-MM-DD, or empty") var date: String
        @Guide(description: "true to mark done, false to undo") var done: Bool
    }
    func call(arguments: Arguments) async throws -> String {
        await run(name, AppleLesser.json(["name": arguments.name, "date": arguments.date.isEmpty ? nil : arguments.date, "done": arguments.done]))
    }
}

@available(macOS 26.0, iOS 26.0, *)
struct MoveBlockTool: Tool {
    let run: LesserToolRunner
    let name = "move_block"
    let description = "Move a block, found by its name, to a new date and/or start time."
    @Generable struct Arguments {
        @Guide(description: "Block name") var name: String
        @Guide(description: "New date, YYYY-MM-DD, or empty") var date: String
        @Guide(description: "New start time, 24h HH:MM, or empty") var start: String
    }
    func call(arguments: Arguments) async throws -> String {
        await run(name, AppleLesser.json(["name": arguments.name, "date": arguments.date.isEmpty ? nil : arguments.date,
                                          "start": arguments.start.isEmpty ? nil : arguments.start]))
    }
}
#endif
