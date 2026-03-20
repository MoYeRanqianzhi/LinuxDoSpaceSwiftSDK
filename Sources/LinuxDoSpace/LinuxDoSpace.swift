import Foundation

public enum Suffix: String, Sendable {
    /// Semantic first-party namespace suffix resolved as
    /// `<owner_username>.linuxdo.space` after the ready handshake.
    case linuxdoSpace = "linuxdo.space"
}

public enum LinuxDoSpaceError: Error, Sendable {
    case invalidArgument(String)
    case authenticationFailed(String)
    case streamFailed(String)
    case mailboxClosed
    case mailboxAlreadyListening
}

public struct MailMessage: Sendable {
    public let address: String
    public let sender: String
    public let recipients: [String]
    public let receivedAt: Date
    public let subject: String
    public let messageId: String?
    public let date: Date?
    public let fromHeader: String
    public let toHeader: String
    public let ccHeader: String
    public let replyToHeader: String
    public let fromAddresses: [String]
    public let toAddresses: [String]
    public let ccAddresses: [String]
    public let replyToAddresses: [String]
    public let text: String
    public let html: String
    public let headers: [String: String]
    public let raw: String
    public let rawBytes: Data
}

public final actor MailBox {
    public let mode: String
    public let suffix: String
    public let allowOverlap: Bool
    public let prefix: String?
    public let pattern: String?
    public let address: String?

    private var closed = false
    private var listening = false
    private var failure: Error?
    private var queue: [MailMessage] = []
    private var continuation: AsyncThrowingStream<MailMessage, Error>.Continuation?
    private let unbind: @Sendable () async -> Void

    init(mode: String, suffix: String, allowOverlap: Bool, prefix: String?, pattern: String?, unbind: @escaping @Sendable () async -> Void) {
        self.mode = mode
        self.suffix = suffix
        self.allowOverlap = allowOverlap
        self.prefix = prefix
        self.pattern = pattern
        self.address = prefix.map { "\($0)@\(suffix)" }
        self.unbind = unbind
    }

    public func listen() -> AsyncThrowingStream<MailMessage, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.attachListener(continuation) }
        }
    }

    public func close() async {
        if closed { return }
        closed = true
        continuation?.finish()
        continuation = nil
        listening = false
        queue.removeAll(keepingCapacity: false)
        await unbind()
    }

    func enqueue(_ message: MailMessage) {
        if closed || !listening { return }
        queue.append(message)
        flushQueue()
    }

    func fail(_ error: Error) {
        if closed { return }
        failure = error
        continuation?.finish(throwing: error)
        continuation = nil
        listening = false
        queue.removeAll(keepingCapacity: false)
    }

    private func attachListener(_ continuation: AsyncThrowingStream<MailMessage, Error>.Continuation) {
        if closed {
            continuation.finish(throwing: LinuxDoSpaceError.mailboxClosed)
            return
        }
        if listening {
            continuation.finish(throwing: LinuxDoSpaceError.mailboxAlreadyListening)
            return
        }
        if let failure {
            continuation.finish(throwing: failure)
            return
        }
        listening = true
        self.continuation = continuation
        continuation.onTermination = { _ in
            Task { await self.listenerTerminated() }
        }
        flushQueue()
    }

    private func listenerTerminated() {
        continuation = nil
        listening = false
        queue.removeAll(keepingCapacity: false)
    }

    private func flushQueue() {
        guard let continuation else { return }
        while !queue.isEmpty {
            continuation.yield(queue.removeFirst())
        }
    }
}

private struct Binding: Sendable {
    let mode: String
    let suffix: String
    let allowOverlap: Bool
    let prefix: String?
    let regex: NSRegularExpression?
    let mailbox: MailBox

    func matches(localPart: String) -> Bool {
        if mode == "exact" { return prefix == localPart }
        guard let regex else { return false }
        let range = NSRange(location: 0, length: localPart.utf16.count)
        guard let m = regex.firstMatch(in: localPart, options: [], range: range) else { return false }
        return m.range.location == 0 && m.range.length == localPart.utf16.count
    }
}

public final class Client: @unchecked Sendable {
    private let token: String
    private let baseURL: URL
    private let connectTimeout: TimeInterval
    private let streamTimeout: TimeInterval
    private let lock = NSLock()
    private var closed = false
    private var fatalError: LinuxDoSpaceError?
    private var initialError: LinuxDoSpaceError?
    private var ownerUsername: String?
    private var initialReadySignaled = false
    private let initialReadySemaphore = DispatchSemaphore(value: 0)
    private var fullListeners: [UUID: AsyncThrowingStream<MailMessage, Error>.Continuation] = [:]
    private var bindingsBySuffix: [String: [Binding]] = [:]
    private var readerTask: Task<Void, Never>?

    public init(token: String, baseURL: String = "https://api.linuxdo.space", connectTimeout: TimeInterval = 10, streamTimeout: TimeInterval = 30) throws {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedToken.isEmpty { throw LinuxDoSpaceError.invalidArgument("token must not be empty") }
        guard let normalizedURL = Self.normalizeBaseURL(baseURL) else { throw LinuxDoSpaceError.invalidArgument("invalid base_url") }
        self.token = normalizedToken
        self.baseURL = normalizedURL
        self.connectTimeout = connectTimeout
        self.streamTimeout = streamTimeout
        self.readerTask = Task.detached { [weak self] in await self?.readLoop() }
        let timeoutInterval = DispatchTimeInterval.milliseconds(Int((connectTimeout + 1) * 1000))
        if initialReadySemaphore.wait(timeout: .now() + timeoutInterval) == .timedOut {
            readerTask?.cancel()
            throw LinuxDoSpaceError.streamFailed("timed out while opening LinuxDoSpace stream")
        }
        if let initialError {
            readerTask?.cancel()
            throw initialError
        }
    }

    deinit {
        readerTask?.cancel()
    }

    public func listen() -> AsyncThrowingStream<MailMessage, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            if let failure = fatalError {
                lock.unlock()
                continuation.finish(throwing: failure)
                return
            }
            if closed {
                lock.unlock()
                continuation.finish()
                return
            }
            let listenerID = UUID()
            fullListeners[listenerID] = continuation
            lock.unlock()

            continuation.onTermination = { _ in
                self.lock.lock()
                self.fullListeners.removeValue(forKey: listenerID)
                self.lock.unlock()
            }
        }
    }

    public func bind(prefix: String? = nil, pattern: String? = nil, suffix: String = Suffix.linuxdoSpace.rawValue, allowOverlap: Bool = false) throws -> MailBox {
        lock.lock()
        let failure = fatalError
        let localClosed = closed
        lock.unlock()
        if let failure { throw failure }
        if localClosed { throw LinuxDoSpaceError.streamFailed("client is already closed") }
        let hasPrefix = !(prefix ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPattern = !(pattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasPrefix == hasPattern { throw LinuxDoSpaceError.invalidArgument("exactly one of prefix or pattern must be provided") }
        let normalizedSuffix = try resolveBindingSuffix(suffix)
        if normalizedSuffix.isEmpty { throw LinuxDoSpaceError.invalidArgument("suffix must not be empty") }

        let normalizedPrefix = hasPrefix ? prefix!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil
        let mode = hasPrefix ? "exact" : "pattern"
        let regex = hasPattern ? try NSRegularExpression(pattern: "^(?:\(pattern!))$", options: []) : nil

        var token = UUID().uuidString
        let box = MailBox(mode: mode, suffix: normalizedSuffix, allowOverlap: allowOverlap, prefix: normalizedPrefix, pattern: hasPattern ? pattern : nil) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard var list = self.bindingsBySuffix[normalizedSuffix] else { return }
            list.removeAll { ObjectIdentifier($0.mailbox).hashValue.description == token }
            if list.isEmpty { self.bindingsBySuffix.removeValue(forKey: normalizedSuffix) } else { self.bindingsBySuffix[normalizedSuffix] = list }
        }
        token = ObjectIdentifier(box).hashValue.description

        let binding = Binding(mode: mode, suffix: normalizedSuffix, allowOverlap: allowOverlap, prefix: normalizedPrefix, regex: regex, mailbox: box)
        lock.lock()
        var list = bindingsBySuffix[normalizedSuffix] ?? []
        list.append(binding)
        bindingsBySuffix[normalizedSuffix] = list
        lock.unlock()
        return box
    }

    public func route(_ message: MailMessage) -> [MailBox] {
        matchBindings(address: message.address).map(\.mailbox)
    }

    public func close() async {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let listeners = Array(fullListeners.values)
        fullListeners.removeAll()
        let boxes = bindingsBySuffix.values.flatMap { $0.map(\.mailbox) }
        bindingsBySuffix.removeAll()
        lock.unlock()
        for continuation in listeners {
            continuation.finish()
        }
        for box in boxes { await box.close() }
        readerTask?.cancel()
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                try await consumeOnce()
            } catch let error as LinuxDoSpaceError {
                if case .streamFailed(let message) = error, message == "stream stalled" {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                signalInitialReadyIfNeeded(error: error)
                await failAll(error)
                return
            } catch {
                signalInitialReadyIfNeeded(error: .streamFailed("unexpected stream failure"))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func consumeOnce() async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("/v1/token/email/stream"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        req.timeoutInterval = connectTimeout

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LinuxDoSpaceError.streamFailed("invalid response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw LinuxDoSpaceError.authenticationFailed("token rejected") }
        if !(200...299).contains(http.statusCode) { throw LinuxDoSpaceError.streamFailed("unexpected stream status: \(http.statusCode)") }

        var lastData = Date()
        for try await line in bytes.lines {
            if Task.isCancelled { return }
            if Date().timeIntervalSince(lastData) > streamTimeout {
                throw LinuxDoSpaceError.streamFailed("stream stalled")
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            lastData = Date()
            try handleLine(trimmed)
        }
        signalInitialReadyIfNeeded(error: .streamFailed("mail stream ended before ready event"))
    }

    private func handleLine(_ line: String) throws {
        guard let data = line.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            throw LinuxDoSpaceError.streamFailed("invalid NDJSON event")
        }
        if type == "ready" {
            try handleReady(json)
            return
        }
        if type == "heartbeat" { return }
        if type != "mail" { return }
        let recipients = ((json["original_recipients"] as? [Any]) ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let sender = (json["original_envelope_from"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let receivedAtText = (json["received_at"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let receivedAt = ISO8601DateFormatter().date(from: receivedAtText) ?? Date()
        let rawBytes = Data(base64Encoded: json["raw_message_base64"] as? String ?? "") ?? Data()
        let rawText = String(data: rawBytes, encoding: .utf8) ?? String(decoding: rawBytes, as: UTF8.self)
        let parsed = parseRawMessage(rawText)
        let primary = recipients.first ?? ""
        let fullMessage = parsed.toMailMessage(
            address: primary,
            sender: sender,
            recipients: recipients,
            receivedAt: receivedAt,
            rawBytes: rawBytes,
            raw: rawText
        )
        broadcastToFullListeners(fullMessage)
        var seen = Set<String>()
        for recipient in recipients where seen.insert(recipient).inserted {
            let recipientMessage = parsed.toMailMessage(
                address: recipient,
                sender: sender,
                recipients: recipients,
                receivedAt: receivedAt,
                rawBytes: rawBytes,
                raw: rawText
            )
            for binding in matchBindings(address: recipient) {
                Task { await binding.mailbox.enqueue(recipientMessage) }
            }
        }
    }

    private func matchBindings(address: String) -> [Binding] {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = normalized.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count != 2 || parts[0].isEmpty || parts[1].isEmpty { return [] }
        let local = String(parts[0])
        let suffix = String(parts[1])

        lock.lock()
        let chain = bindingsBySuffix[suffix] ?? []
        lock.unlock()
        var matched: [Binding] = []
        for b in chain {
            if !b.matches(localPart: local) { continue }
            matched.append(b)
            if !b.allowOverlap { break }
        }
        return matched
    }

    private func failAll(_ error: LinuxDoSpaceError) async {
        lock.lock()
        fatalError = error
        closed = true
        let listeners = Array(fullListeners.values)
        fullListeners.removeAll()
        let boxes = bindingsBySuffix.values.flatMap { $0.map(\.mailbox) }
        bindingsBySuffix.removeAll()
        lock.unlock()
        for continuation in listeners {
            continuation.finish(throwing: error)
        }

        for box in boxes {
            await box.fail(error)
            await box.close()
        }
        readerTask?.cancel()
    }

    private func broadcastToFullListeners(_ message: MailMessage) {
        lock.lock()
        let listeners = Array(fullListeners.values)
        lock.unlock()
        for continuation in listeners {
            continuation.yield(message)
        }
    }

    private func handleReady(_ payload: [String: Any]) throws {
        let ownerUsername = (payload["owner_username"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ownerUsername.isEmpty {
            throw LinuxDoSpaceError.streamFailed("ready event did not include owner_username")
        }

        lock.lock()
        self.ownerUsername = ownerUsername
        lock.unlock()
        signalInitialReadyIfNeeded(error: nil)
    }

    private func resolveBindingSuffix(_ suffix: String) throws -> String {
        let normalizedSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedSuffix.isEmpty {
            throw LinuxDoSpaceError.invalidArgument("suffix must not be empty")
        }
        if normalizedSuffix != Suffix.linuxdoSpace.rawValue {
            return normalizedSuffix
        }

        lock.lock()
        let ownerUsername = self.ownerUsername
        lock.unlock()
        let normalizedOwnerUsername = (ownerUsername ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedOwnerUsername.isEmpty {
            throw LinuxDoSpaceError.streamFailed("stream bootstrap did not provide owner_username required to resolve Suffix.linuxdoSpace")
        }
        return "\(normalizedOwnerUsername).\(normalizedSuffix)"
    }

    private func signalInitialReadyIfNeeded(error: LinuxDoSpaceError?) {
        lock.lock()
        if initialReadySignaled {
            lock.unlock()
            return
        }
        initialReadySignaled = true
        if let error {
            initialError = error
        }
        lock.unlock()
        initialReadySemaphore.signal()
    }

    private static func normalizeBaseURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        if scheme != "https" && scheme != "http" { return nil }
        if scheme == "http" {
            let local = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
            if !local { return nil }
        }
        return URL(string: trimmed)
    }

    private struct ParsedRawMessage {
        let subject: String
        let messageId: String?
        let date: Date?
        let fromHeader: String
        let toHeader: String
        let ccHeader: String
        let replyToHeader: String
        let fromAddresses: [String]
        let toAddresses: [String]
        let ccAddresses: [String]
        let replyToAddresses: [String]
        let text: String
        let html: String
        let headers: [String: String]

        func toMailMessage(address: String, sender: String, recipients: [String], receivedAt: Date, rawBytes: Data, raw: String) -> MailMessage {
            MailMessage(
                address: address,
                sender: sender,
                recipients: recipients,
                receivedAt: receivedAt,
                subject: subject,
                messageId: messageId,
                date: date,
                fromHeader: fromHeader,
                toHeader: toHeader,
                ccHeader: ccHeader,
                replyToHeader: replyToHeader,
                fromAddresses: fromAddresses,
                toAddresses: toAddresses,
                ccAddresses: ccAddresses,
                replyToAddresses: replyToAddresses,
                text: text,
                html: html,
                headers: headers,
                raw: raw,
                rawBytes: rawBytes
            )
        }
    }

    private func parseRawMessage(_ raw: String) -> ParsedRawMessage {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let splitRange = normalized.range(of: "\n\n")
        let headerText = splitRange.map { String(normalized[..<$0.lowerBound]) } ?? normalized
        let bodyText = splitRange.map { String(normalized[$0.upperBound...]) } ?? ""
        let headers = parseHeaders(headerText)
        let contentType = headers["Content-Type"] ?? ""
        let extractedBody = extractBody(contentType: contentType, body: bodyText)
        return ParsedRawMessage(
            subject: headers["Subject"] ?? "",
            messageId: optionalHeader(headers, key: "Message-ID"),
            date: parseMailDate(optionalHeader(headers, key: "Date")),
            fromHeader: headers["From"] ?? "",
            toHeader: headers["To"] ?? "",
            ccHeader: headers["Cc"] ?? "",
            replyToHeader: headers["Reply-To"] ?? "",
            fromAddresses: parseAddresses(headers["From"] ?? ""),
            toAddresses: parseAddresses(headers["To"] ?? ""),
            ccAddresses: parseAddresses(headers["Cc"] ?? ""),
            replyToAddresses: parseAddresses(headers["Reply-To"] ?? ""),
            text: extractedBody.text,
            html: extractedBody.html,
            headers: headers
        )
    }

    private func parseHeaders(_ source: String) -> [String: String] {
        var headers: [String: String] = [:]
        var activeKey: String?
        for line in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty { continue }
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), let activeKey {
                let current = headers[activeKey] ?? ""
                headers[activeKey] = current + " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
            activeKey = key
        }
        return headers
    }

    private func extractBody(contentType: String, body: String) -> (text: String, html: String) {
        let loweredType = contentType.lowercased()
        if loweredType.contains("multipart/"), let boundary = parseBoundary(contentType: contentType) {
            let delimiter = "--\(boundary)"
            let endDelimiter = "--\(boundary)--"
            var textParts: [String] = []
            var htmlParts: [String] = []
            var collecting = false
            var current: [String] = []
            for line in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                if line == delimiter || line == endDelimiter {
                    if collecting, !current.isEmpty {
                        let part = current.joined(separator: "\n")
                        current.removeAll(keepingCapacity: false)
                        let splitRange = part.range(of: "\n\n")
                        let partHead = splitRange.map { String(part[..<$0.lowerBound]) } ?? part
                        let partBody = splitRange.map { String(part[$0.upperBound...]) } ?? ""
                        let partHeaders = parseHeaders(partHead)
                        let partType = (partHeaders["Content-Type"] ?? "").lowercased()
                        if partType.contains("text/plain") {
                            textParts.append(partBody.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else if partType.contains("text/html") {
                            htmlParts.append(partBody.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                    collecting = line != endDelimiter
                    continue
                }
                if collecting {
                    current.append(line)
                }
            }
            return (textParts.joined(separator: "\n"), htmlParts.joined(separator: "\n"))
        }
        if loweredType.contains("text/html") {
            return ("", body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    private func parseBoundary(contentType: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "boundary=([^;]+)", options: [.caseInsensitive]) else { return nil }
        let nsRange = NSRange(location: 0, length: contentType.utf16.count)
        guard let match = regex.firstMatch(in: contentType, options: [], range: nsRange), match.numberOfRanges > 1 else { return nil }
        guard let range = Range(match.range(at: 1), in: contentType) else { return nil }
        var boundary = String(contentType[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        if boundary.hasPrefix("\""), boundary.hasSuffix("\""), boundary.count >= 2 {
            boundary.removeFirst()
            boundary.removeLast()
        }
        return boundary.isEmpty ? nil : boundary
    }

    private func parseAddresses(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .compactMap { chunk in
                let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if let left = trimmed.firstIndex(of: "<"), let right = trimmed.firstIndex(of: ">"), left < right {
                    let mail = trimmed[trimmed.index(after: left)..<right].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return mail.contains("@") ? mail : nil
                }
                let lower = trimmed.lowercased()
                return lower.contains("@") ? lower : nil
            }
    }

    private func optionalHeader(_ headers: [String: String], key: String) -> String? {
        guard let value = headers[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func parseMailDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let iso = ISO8601DateFormatter().date(from: value) {
            return iso
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.date(from: value)
    }
}
