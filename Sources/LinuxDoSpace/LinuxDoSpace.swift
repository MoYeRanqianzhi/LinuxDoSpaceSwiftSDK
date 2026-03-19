import Foundation

public enum Suffix: String, Sendable {
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
    private var queue: [MailMessage] = []
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
            Task {
                if closed {
                    continuation.finish(throwing: LinuxDoSpaceError.mailboxClosed)
                    return
                }
                if listening {
                    continuation.finish(throwing: LinuxDoSpaceError.mailboxAlreadyListening)
                    return
                }
                listening = true
                while !closed {
                    if !queue.isEmpty {
                        continuation.yield(queue.removeFirst())
                    } else {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                continuation.finish()
            }
        }
    }

    public func close() async {
        if closed { return }
        closed = true
        await unbind()
    }

    func enqueue(_ message: MailMessage) {
        if closed || !listening { return }
        queue.append(message)
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
    private var fullQueue: [MailMessage] = []
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
    }

    deinit {
        readerTask?.cancel()
    }

    public func listen() -> AsyncThrowingStream<MailMessage, Error> {
        AsyncThrowingStream { continuation in
            Task.detached { [weak self] in
                while let self, !Task.isCancelled {
                    self.lock.lock()
                    let localClosed = self.closed
                    let item = self.fullQueue.isEmpty ? nil : self.fullQueue.removeFirst()
                    self.lock.unlock()
                    if localClosed { continuation.finish(); return }
                    if let item {
                        continuation.yield(item)
                    } else {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                continuation.finish()
            }
        }
    }

    public func bind(prefix: String? = nil, pattern: String? = nil, suffix: String = Suffix.linuxdoSpace.rawValue, allowOverlap: Bool = false) throws -> MailBox {
        let hasPrefix = !(prefix ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPattern = !(pattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasPrefix == hasPattern { throw LinuxDoSpaceError.invalidArgument("exactly one of prefix or pattern must be provided") }
        let normalizedSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        let boxes = bindingsBySuffix.values.flatMap { $0.map(\.mailbox) }
        bindingsBySuffix.removeAll()
        lock.unlock()
        for box in boxes { await box.close() }
        readerTask?.cancel()
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                try await consumeOnce()
            } catch {
                // Keep reconnecting for resilience.
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
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

        let lastData = Date()
        for try await line in bytes.lines {
            if Task.isCancelled { return }
            if Date().timeIntervalSince(lastData) > streamTimeout {
                throw LinuxDoSpaceError.streamFailed("stream stalled")
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            try handleLine(trimmed)
        }
    }

    private func handleLine(_ line: String) throws {
        guard let data = line.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            throw LinuxDoSpaceError.streamFailed("invalid NDJSON event")
        }
        if type == "ready" || type == "heartbeat" { return }
        if type != "mail" { return }
        let recipients = ((json["original_recipients"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        let primary = recipients.first ?? ""
        let message = MailMessage(
            address: primary,
            sender: (json["original_envelope_from"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            recipients: recipients,
            receivedAt: ISO8601DateFormatter().date(from: (json["received_at"] as? String ?? "")) ?? Date(),
            subject: "",
            messageId: nil,
            date: nil,
            fromHeader: "",
            toHeader: "",
            ccHeader: "",
            replyToHeader: "",
            fromAddresses: [],
            toAddresses: [],
            ccAddresses: [],
            replyToAddresses: [],
            text: "",
            html: "",
            headers: [:],
            raw: "",
            rawBytes: Data(base64Encoded: json["raw_message_base64"] as? String ?? "") ?? Data()
        )
        lock.lock()
        fullQueue.append(message)
        lock.unlock()
        var seen = Set<String>()
        for recipient in recipients where seen.insert(recipient).inserted {
            for binding in matchBindings(address: recipient) {
                Task { await binding.mailbox.enqueue(message) }
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
}
