import Foundation

package struct AIChatMessage: Sendable {
    package enum Role: String, Sendable {
        case user
        case assistant
    }

    package let role: Role
    package var text: String

    package init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

package enum AIAPIError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case invalidURL
    case transport(String)
    case http(Int, String)
    case api(String)
    case invalidResponse(String)
    case emptyResponse
    case cancelled

    package var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .invalidURL:
            return "接口地址无效，请填写以 http:// 或 https:// 开头的完整地址。"
        case .transport(let message):
            return "网络请求失败：\(message)"
        case .http(let code, let message):
            return "接口返回 HTTP \(code)：\(message)"
        case .api(let message):
            return "接口返回错误：\(message)"
        case .invalidResponse(let message):
            return "接口响应无法解析：\(message)"
        case .emptyResponse:
            return "AI 没有返回内容。"
        case .cancelled:
            return "请求已取消。"
        }
    }
}

/// 可取消的一次 AI 请求。
package final class AITask: @unchecked Sendable {
    fileprivate var dataTask: URLSessionDataTask?
    fileprivate var session: URLSession?
    package private(set) var isCancelled = false

    package func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        dataTask?.cancel()
        session?.invalidateAndCancel()
    }
}

package enum AIClient {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // MARK: - 对外接口

    package static func testConnection(
        settings: AISettings,
        apiKey: String?,
        completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void
    ) -> AITask {
        let task = AITask()
        do {
            let messages: [[String: Any]] = [
                ["role": "system", "content": "你是接口连通性测试助手。"],
                ["role": "user", "content": "请只回复：连接成功"],
            ]
            let request = try makeRequest(
                settings: settings,
                apiKey: apiKey,
                messages: messages,
                stream: false,
                maxTokens: 128,
                temperature: 0
            )
            execute(request: request, task: task, completion: completion)
        } catch {
            Task { @MainActor in completion(.failure(error)) }
        }
        return task
    }

    package static func testVision(
        settings: AISettings,
        apiKey: String?,
        completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void
    ) -> AITask {
        let task = AITask()
        guard let testImage = AIImageEncoder.testImageDataURL() else {
            DispatchQueue.main.async {
                completion(.failure(AIAPIError.invalidConfiguration("测试图片生成失败。")))
            }
            return task
        }
        do {
            let messages: [[String: Any]] = [
                ["role": "system", "content": "你是图片识别测试助手，只回复图片中看到的文字。"],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "请读出图片中的文字，只回复你看到的内容。"],
                        imagePart(testImage),
                    ],
                ],
            ]
            let request = try makeRequest(
                settings: settings,
                apiKey: apiKey,
                messages: messages,
                stream: false,
                maxTokens: 256,
                temperature: 0
            )
            execute(request: request, task: task, completion: completion)
        } catch {
            Task { @MainActor in completion(.failure(error)) }
        }
        return task
    }

    package static func recognize(
        imageDataURL: String,
        mode: AIMode,
        settings: AISettings,
        apiKey: String?,
        paragraphMode: Bool = false,
        completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void
    ) -> AITask {
        let task = AITask()
        do {
            var systemPrompt = settings.prompt(for: mode)
            if mode == .extract && paragraphMode {
                systemPrompt +=
                    "\n\n【本次输出格式】请按截图中的语义段落组织文字：同一段落内的视觉换行合并为一行，段落之间保留一个空行；列表项、编号项和独立标题各占一行。不要为了匹配截图宽度而断行，也不要改变原文措辞；无法辨认的字仍用 [无法辨认]。"
            }
            let messages: [[String: Any]] = [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "请按系统提示处理这张截图。"],
                        imagePart(imageDataURL),
                    ],
                ],
            ]
            let request = try makeRequest(
                settings: settings,
                apiKey: apiKey,
                messages: messages,
                stream: false,
                maxTokens: 4096,
                temperature: 0
            )
            execute(request: request, task: task, completion: completion)
        } catch {
            Task { @MainActor in completion(.failure(error)) }
        }
        return task
    }

    package static func translate(
        imageDataURL: String,
        lines: [String],
        source: TranslationLanguage,
        target: TranslationLanguage,
        settings: AISettings,
        apiKey: String?,
        completion: @escaping @MainActor @Sendable (Result<TranslationOutcome, Error>) -> Void
    ) -> AITask {
        let task = AITask()
        guard target != .auto else {
            DispatchQueue.main.async {
                completion(.failure(AIAPIError.invalidConfiguration("目标语言不能是自动检测。")))
            }
            return task
        }
        guard !lines.isEmpty else {
            DispatchQueue.main.async {
                completion(.failure(AIAPIError.invalidConfiguration("没有可翻译的文字。")))
            }
            return task
        }

        do {
            let sourceDescription =
                source.isAuto
                ? "自动检测"
                : "\(source.displayName)（\(source.rawValue)）"
            let sameLanguageRule =
                source.isAuto
                ? "只有当所有非空行都已经是目标语言时，才把 sameLanguage 设为 true，并让 translations 返回空数组；否则必须逐行翻译。"
                : "源语言已由用户指定，sameLanguage 必须为 false，不能跳过翻译。"
            let inputData = try JSONSerialization.data(withJSONObject: lines, options: [.withoutEscapingSlashes])
            let inputJSON = String(data: inputData, encoding: .utf8) ?? "[]"
            let totalCharacters = lines.reduce(0) { $0 + $1.count }
            let maxTokens = min(8192, max(1024, totalCharacters * 3))

            let systemPrompt = """
                你是逐行翻译助手。用户会同时提供一张截图和一份从截图提取出来的 JSON 字符串数组。截图只用于理解上下文；你必须翻译 JSON 数组里的文字，不要重新 OCR 截图，不要增加、删除、合并或拆分行。只输出一个 JSON 对象，不要 Markdown 代码块，不要解释。
                """

            let userText = """
                请把下面的文字翻译成\(target.displayName)。
                源语言：\(sourceDescription)
                目标语言代码：\(target.rawValue)

                规则：
                1. \(sameLanguageRule)
                2. 没有跳过翻译时，translations 数组的元素数量、顺序必须与输入完全一致；每个元素只包含对应那一行的译文。
                3. 每个 translations 元素只输出一行，不能包含换行符；不合并、不拆分、不增删、不总结、不解释。
                4. 保留数字、编号、专有名词、代码、URL、标点和 [无法辨认] 占位，译文自然准确。
                5. detectedLanguage 使用 en、zh-Hans、zh-Hant、ja、ko 或 unknown。
                6. 只输出 JSON 对象，不要前后说明。格式：
                {"detectedLanguage":"en","sameLanguage":false,"translations":["第一行译文","第二行译文"]}

                输入（共 \(lines.count) 行）：
                \(inputJSON)
                """

            let messages: [[String: Any]] = [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": userText],
                        imagePart(imageDataURL),
                    ],
                ],
            ]
            let request = try makeRequest(
                settings: settings,
                apiKey: apiKey,
                messages: messages,
                stream: false,
                maxTokens: maxTokens,
                temperature: 0
            )
            execute(request: request, task: task) { result in
                switch result {
                case .success(let text):
                    do {
                        let outcome = try parseTranslationResponse(
                            text,
                            expectedCount: lines.count,
                            source: source,
                            target: target
                        )
                        completion(.success(outcome))
                    } catch {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        } catch {
            Task { @MainActor in completion(.failure(error)) }
        }
        return task
    }

    package static func chatStream(
        imageDataURL: String,
        currentResult: String,
        history: [AIChatMessage],
        question: String,
        settings: AISettings,
        apiKey: String?,
        onDelta: @escaping @MainActor @Sendable (String) -> Void,
        onDone: @escaping @MainActor @Sendable () -> Void,
        onError: @escaping @MainActor @Sendable (Error) -> Void
    ) -> AITask {
        let task = AITask()
        do {
            var system = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if system.isEmpty { system = AIDefaults.systemPrompt }
            if !currentResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                system += "\n\n当前识别结果（用户可能编辑过，请以此为准）：\n\(currentResult)"
            }

            var messages: [[String: Any]] = [
                ["role": "system", "content": system],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "这是当前截图。"],
                        imagePart(imageDataURL),
                    ],
                ],
            ]
            for item in history where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append([
                    "role": item.role.rawValue,
                    "content": item.text,
                ])
            }
            messages.append(["role": "user", "content": question])

            let request = try makeRequest(
                settings: settings,
                apiKey: apiKey,
                messages: messages,
                stream: true,
                maxTokens: 2048,
                temperature: 0.3
            )
            startStream(request: request, task: task, onDelta: onDelta, onDone: onDone, onError: onError)
        } catch {
            DispatchQueue.main.async { onError(error) }
        }
        return task
    }

    // MARK: - 请求构造

    private static func imagePart(_ dataURL: String) -> [String: Any] {
        [
            "type": "image_url",
            "image_url": [
                "url": dataURL,
                "detail": "high",
            ],
        ]
    }

    package static func endpointURL(from baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            components.host != nil,
            let parsed = components.url,
            AIEndpointPolicy.allows(parsed)
        else {
            throw AIAPIError.invalidURL
        }
        if let message = AIEndpointPolicy.httpRejectionMessage(for: parsed) {
            throw AIAPIError.invalidConfiguration(message)
        }
        var path = components.path
        if !path.lowercased().hasSuffix("/chat/completions") {
            if path.hasSuffix("/") { path.removeLast() }
            components.path = path + "/chat/completions"
        }
        guard let url = components.url else { throw AIAPIError.invalidURL }
        return url
    }

    private static func makeRequest(
        settings: AISettings,
        apiKey: String?,
        messages: [[String: Any]],
        stream: Bool,
        maxTokens: Int,
        temperature: Double
    ) throws -> URLRequest {
        guard !settings.trimmedModel.isEmpty else {
            throw AIAPIError.invalidConfiguration("还没有填写模型名称。")
        }
        let url = try endpointURL(from: settings.trimmedBaseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")

        if settings.authEnabled, let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "model": settings.trimmedModel,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": stream,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        return request
    }

    // MARK: - 非流式请求

    private static func execute(
        request: URLRequest,
        task: AITask,
        completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void
    ) {
        let dataTask = session.dataTask(with: request) { data, response, error in
            if task.isCancelled { return }
            if let error {
                Task { @MainActor in completion(.failure(AIAPIError.transport(error.localizedDescription))) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                Task { @MainActor in completion(.failure(AIAPIError.invalidResponse("没有收到 HTTP 响应。"))) }
                return
            }
            let body = data ?? Data()
            guard (200..<300).contains(http.statusCode) else {
                let message = apiErrorMessage(data: body)
                Task { @MainActor in completion(.failure(AIAPIError.http(http.statusCode, message))) }
                return
            }
            guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                let raw = String(data: body, encoding: .utf8) ?? ""
                Task { @MainActor in
                    completion(
                        .failure(AIAPIError.invalidResponse(raw.isEmpty ? "响应不是 JSON。" : String(raw.prefix(300)))))
                }
                return
            }
            if let text = extractText(from: object) {
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty {
                    Task { @MainActor in completion(.failure(AIAPIError.emptyResponse)) }
                } else {
                    Task { @MainActor in completion(.success(cleaned)) }
                }
            } else {
                let message = apiErrorMessage(from: object)
                Task { @MainActor in completion(.failure(AIAPIError.api(message))) }
            }
        }
        task.dataTask = dataTask
        dataTask.resume()
    }

    private static func apiErrorMessage(data: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            return raw.isEmpty ? "没有详细信息。" : String(raw.prefix(500))
        }
        return apiErrorMessage(from: object)
    }

    private static func apiErrorMessage(from object: [String: Any]) -> String {
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty { return message }
            if let code = error["code"] { return "错误码 \(code)" }
        }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        if let error = object["error"] as? String, !error.isEmpty { return error }
        return "接口没有返回可读内容。"
    }

    private static func extractText(from object: [String: Any]) -> String? {
        guard let choices = object["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            return nil
        }
        return text(fromContent: message["content"])
    }

    private static func text(fromContent content: Any?) -> String? {
        if let string = content as? String {
            return string
        }
        if let parts = content as? [[String: Any]] {
            let texts = parts.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                if let text = part["content"] as? String { return text }
                return nil
            }
            return texts.isEmpty ? nil : texts.joined()
        }
        return nil
    }

    // MARK: - 翻译结果解析

    private static func parseTranslationResponse(
        _ raw: String,
        expectedCount: Int,
        source: TranslationLanguage,
        target: TranslationLanguage
    ) throws -> TranslationOutcome {
        guard let object = translationJSONObject(from: raw) else {
            throw AIAPIError.invalidResponse("翻译结果不是可解析的 JSON。")
        }

        if let array = object as? [String] {
            let translated = try normalizeTranslatedLines(array, expectedCount: expectedCount)
            return .translated(lines: translated, detected: nil)
        }

        guard let dictionary = object as? [String: Any] else {
            throw AIAPIError.invalidResponse("翻译结果既不是 JSON 数组，也不是 JSON 对象。")
        }

        let detected = TranslationLanguage.detected(from: dictionary["detectedLanguage"] as? String)
        let flaggedSameLanguage = (dictionary["sameLanguage"] as? Bool) ?? false
        if source.isAuto && (flaggedSameLanguage || detected == target) {
            return .sameLanguage(detected: detected)
        }

        guard let array = dictionary["translations"] as? [String] else {
            throw AIAPIError.invalidResponse("翻译结果缺少 translations 数组。")
        }
        let translated = try normalizeTranslatedLines(array, expectedCount: expectedCount)
        return .translated(lines: translated, detected: detected)
    }

    private static func normalizeTranslatedLines(_ lines: [String], expectedCount: Int) throws -> [String] {
        guard lines.count == expectedCount else {
            throw AIAPIError.invalidResponse(
                "译文行数与原文不一致（原文 \(expectedCount) 行，返回 \(lines.count) 行）。"
            )
        }
        let normalized = lines.map { line in
            line
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let emptyIndex = normalized.firstIndex(where: { $0.isEmpty }) {
            throw AIAPIError.invalidResponse("第 \(emptyIndex + 1) 行没有返回译文。")
        }
        return normalized
    }

    private static func translationJSONObject(from raw: String) -> Any? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            var lines = trimmed.components(separatedBy: "\n")
            if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" { lines.removeLast() }
            trimmed = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var candidates = [trimmed]
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            candidates.append(String(trimmed[start...end]))
        }
        if let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]") {
            candidates.append(String(trimmed[start...end]))
        }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let object = try? JSONSerialization.jsonObject(with: data) {
                return object
            }
        }
        return nil
    }

    // MARK: - 流式请求

    private static func startStream(
        request: URLRequest,
        task: AITask,
        onDelta: @escaping @MainActor @Sendable (String) -> Void,
        onDone: @escaping @MainActor @Sendable () -> Void,
        onError: @escaping @MainActor @Sendable (Error) -> Void
    ) {
        let delegate = SSEStreamDelegate(
            task: task,
            onDelta: onDelta,
            onDone: onDone,
            onError: onError
        )
        let streamSession = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let dataTask = streamSession.dataTask(with: request)
        task.session = streamSession
        task.dataTask = dataTask
        dataTask.resume()
    }
}

private final class SSEStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let task: AITask
    private let onDelta: @MainActor @Sendable (String) -> Void
    private let onDone: @MainActor @Sendable () -> Void
    private let onError: @MainActor @Sendable (Error) -> Void
    private var buffer = ""
    private var statusCode = 0
    private var errorData = Data()
    private var finished = false

    init(
        task: AITask,
        onDelta: @escaping @MainActor @Sendable (String) -> Void,
        onDone: @escaping @MainActor @Sendable () -> Void,
        onError: @escaping @MainActor @Sendable (Error) -> Void
    ) {
        self.task = task
        self.onDelta = onDelta
        self.onDone = onDone
        self.onError = onError
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, !task.isCancelled else { return }
        if statusCode >= 400 {
            errorData.append(data)
            return
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { consume(line: line) }
        }
    }

    func urlSession(_ session: URLSession, task sessionTask: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if self.task.isCancelled {
            session.finishTasksAndInvalidate()
            return
        }
        if let error {
            fail(AIAPIError.transport(error.localizedDescription), session: session)
            return
        }
        if statusCode >= 400 {
            let message = apiErrorMessage(data: errorData)
            fail(AIAPIError.http(statusCode, message), session: session)
            return
        }
        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            consume(line: buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            buffer = ""
        }
        finish(session: session)
    }

    private func consume(line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" {
            finish(session: nil)
            return
        }
        guard let data = payload.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return
        }
        if object["error"] != nil {
            let message = apiErrorMessage(from: object)
            fail(AIAPIError.api(message), session: nil)
            return
        }
        guard let choices = object["choices"] as? [[String: Any]],
            let first = choices.first
        else { return }
        if let delta = first["delta"] as? [String: Any],
            let content = delta["content"],
            let deltaText = contentText(from: content), !deltaText.isEmpty
        {
            Task { @MainActor in self.onDelta(deltaText) }
        }
    }

    private func finish(session: URLSession?) {
        guard !finished else { return }
        finished = true
        (session ?? task.session)?.finishTasksAndInvalidate()
        Task { @MainActor in self.onDone() }
    }

    private func fail(_ error: Error, session: URLSession?) {
        guard !finished else { return }
        finished = true
        (session ?? task.session)?.finishTasksAndInvalidate()
        Task { @MainActor in self.onError(error) }
    }

    private func apiErrorMessage(data: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            return raw.isEmpty ? "没有详细信息。" : String(raw.prefix(500))
        }
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty { return message }
        }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        return "接口没有返回可读内容。"
    }

    private func apiErrorMessage(from object: [String: Any]) -> String {
        if let error = object["error"] as? [String: Any],
            let message = error["message"] as? String, !message.isEmpty
        {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        return "接口没有返回可读内容。"
    }

    private func contentText(from content: Any?) -> String? {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            let texts = parts.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                if let text = part["content"] as? String { return text }
                return nil
            }
            return texts.isEmpty ? nil : texts.joined()
        }
        return nil
    }
}
