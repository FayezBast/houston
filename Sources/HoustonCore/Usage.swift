import Foundation

public struct UsageWindow: Sendable, Equatable {
    public let name: String
    public let used: Double
    public let resetsAt: Date?
    public var remaining: Double { max(0, min(100, 100 - used)) }

    public init(name: String, used: Double, resetsAt: Date?) {
        self.name = name
        self.used = used
        self.resetsAt = resetsAt
    }

    public func expired(at now: Date = .now) -> Bool { resetsAt.map { $0 <= now } ?? false }

    public func countdown(at now: Date = .now) -> String {
        guard let resetsAt,
              let seconds = Int(exactly: resetsAt.timeIntervalSince(now).rounded(.towardZero)) else { return "Reset time unavailable" }
        guard seconds > 0 else { return "Awaiting updated usage" }
        let minutes = (seconds - 1) / 60 + 1
        if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
}

public struct UsageSnapshot: Sendable {
    public let windows: [UsageWindow]
    public let capturedAt: Date
    public let detail: String?
    public let spend: UsageSpend?
    public let accountID: String?
    public init(windows: [UsageWindow], capturedAt: Date = .now, detail: String? = nil, spend: UsageSpend? = nil, accountID: String? = nil) {
        self.windows = windows
        self.capturedAt = capturedAt
        self.detail = detail
        self.spend = spend
        self.accountID = accountID
    }
    public var isStale: Bool { Date.now.timeIntervalSince(capturedAt) > 600 }

    public func scoped(to accountID: String?) -> UsageSnapshot {
        UsageSnapshot(windows: windows, capturedAt: capturedAt, detail: detail, spend: spend, accountID: accountID)
    }
}

public enum UsageError: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}

public enum UsageReader {
    public static var claudeFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Houston/claude-usage.json")
    }

    public static func parseCodex(_ data: Data, now: Date = .now) throws -> UsageSnapshot {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let result = root["result"] as? [String: Any] ?? root
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        // The base Codex bucket must not be confused with a model-specific allowance.
        let limits = buckets?["codex"] as? [String: Any] ?? result["rateLimits"] as? [String: Any] ?? [:]
        let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
            guard let value = limits[key] as? [String: Any],
                  let used = value["usedPercent"] as? Double, used.isFinite else { return nil }
            let minutes = value["windowDurationMins"] as? Int
            let name: String
            switch minutes {
            case 300: name = "5-hour"
            case 10080: name = "Weekly"
            case .some(let duration) where duration % 60 == 0: name = "\(duration / 60)-hour"
            case .some(let duration): name = "\(duration)-minute"
            case .none: name = key == "primary" ? "Current window" : "Longer window"
            }
            return UsageWindow(name: name, used: used,
                resetsAt: (value["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
        guard !windows.isEmpty else { throw UsageError.unavailable("No subscription usage returned. Sign in with a ChatGPT account in Codex.") }
        return UsageSnapshot(windows: windows, capturedAt: now)
    }

    public static func parseClaude(_ data: Data, capturedAt: Date = .now) throws -> UsageSnapshot {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let limits = root["rate_limits"] as? [String: Any] ?? [:]
        let windows = [("five_hour", "5-hour"), ("seven_day", "Weekly"), ("spend_limit", "Spend limit")].compactMap { key, name -> UsageWindow? in
            guard let value = limits[key] as? [String: Any],
                  let used = (value["used_percentage"] ?? value["utilization"]) as? Double, used.isFinite else { return nil }
            return UsageWindow(name: name, used: used, resetsAt: DeveloperTools.date(value["resets_at"]))
        }
        guard !windows.isEmpty else { throw UsageError.unavailable("Waiting for Claude Code to report subscription usage. Send a message in a Pro or Max session.") }
        return UsageSnapshot(windows: windows, capturedAt: capturedAt)
    }

    public static func readClaude(from claudeFile: URL = claudeFile) throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: claudeFile.path) else {
            throw UsageError.unavailable("No usage received yet. Send a message in the Claude Code terminal; desktop chat does not send status-line updates.")
        }
        let date = try claudeFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        return try parseClaude(Data(contentsOf: claudeFile), capturedAt: date)
    }

    /// Called as a Claude status-line command. Store only quota fields, never prompts or credentials.
    public static func captureClaude(_ data: Data, to destination: URL = claudeFile) throws {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let safe: [String: Any] = ["rate_limits": root["rate_limits"] as? [String: Any] ?? [:]]
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: safe).write(to: destination, options: .atomic)
    }

    public static func codexExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex"]
        let search = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return (candidates + search).first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    public static func readCodex() throws -> UsageSnapshot {
        guard let executable = codexExecutable() else {
            throw UsageError.unavailable("Install the Codex CLI and sign in to connect.")
        }
        let process = Process()
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let authenticationFile = codexHome.appendingPathComponent("auth.json")
        let authenticationBefore = try? Data(contentsOf: authenticationFile)
        var accountBefore: Data?
        var usage: UsageSnapshot?
        let input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "houston", "version": "0.1.0"]]])
        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty {
                if let usage { return usage }
                throw UsageError.unavailable("Codex did not return usage. Check your connection and Codex sign-in, then refresh.")
            }
            buffer.append(chunk)
            guard buffer.count < 2_000_000 else { throw UsageError.unavailable("Unexpected response from Codex.") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                if message["error"] != nil {
                    if id == 2 {
                        try send(["method": "account/rateLimits/read", "id": 3])
                        continue
                    }
                    if id == 4, let usage { return usage }
                    throw UsageError.unavailable("Codex could not read usage. Open Codex, check your sign-in, and refresh.")
                }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["method": "account/read", "id": 2, "params": ["refreshToken": false]])
                } else if id == 2 {
                    accountBefore = line
                    try send(["method": "account/rateLimits/read", "id": 3])
                } else if id == 3 {
                    usage = try parseCodex(line)
                    guard UsageAccountIdentity.codex(authentication: authenticationBefore, accountResponse: accountBefore) != nil else { return usage! }
                    try send(["method": "account/read", "id": 4, "params": ["refreshToken": false]])
                } else if id == 4, let usage {
                    let before = UsageAccountIdentity.codex(authentication: authenticationBefore, accountResponse: accountBefore)
                    let after = UsageAccountIdentity.codex(authentication: try? Data(contentsOf: authenticationFile), accountResponse: line)
                    return usage.scoped(to: before == after ? before : nil)
                }
            }
        }
    }
}
