import Foundation
import Darwin

public enum AgentProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, codex, cursor
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
    public var logoName: String { self == .codex ? "openai" : rawValue }
}

public enum AgentStatus: String, Codable, Sendable {
    case running, waiting, completed, failed, idle, interrupted, ended

    public var title: String {
        switch self {
        case .running: "Running"
        case .waiting: "Needs input"
        case .completed: "Response ready"
        case .failed: "Turn failed"
        case .idle: "Ready"
        case .interrupted: "Interrupted"
        case .ended: "Session ended"
        }
    }

    public var needsAttention: Bool { self == .waiting || self == .failed || self == .completed }
}

public struct AgentSession: Codable, Equatable, Sendable, Identifiable {
    public let sessionID: String
    public let provider: AgentProvider
    public let projectPath: String
    public let status: AgentStatus
    public let updatedAt: Date
    /// Cursor's generation and loop identify repeated delivery of the same stop event.
    public let eventID: String?
    public var id: String { provider.rawValue + ":" + sessionID }
    public var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }
    public var needsAttention: Bool { status.needsAttention }

    public init(sessionID: String, provider: AgentProvider, projectPath: String, status: AgentStatus, updatedAt: Date = .now, eventID: String? = nil) {
        self.sessionID = sessionID
        self.provider = provider
        self.projectPath = projectPath
        self.status = status
        self.updatedAt = updatedAt
        self.eventID = eventID
    }

    /// The last received event is evidence, not a heartbeat or proof that a process is alive.
    public func isStale(at now: Date = .now) -> Bool {
        (status == .running || status == .waiting || status == .idle) && now.timeIntervalSince(updatedAt) > 900
    }

    public var resumeCommand: String? {
        guard provider != .cursor else { return nil }
        return "cd -- " + AgentBridge.shellQuote(projectPath) + " && " + provider.rawValue
            + (provider == .claude ? " --resume " : " resume ") + AgentBridge.shellQuote(sessionID)
    }
}

public enum AgentBridge {
    public static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Houston") }
    public static let filename = "agent-sessions.json"
    private static let marker = " # Houston agent status"
    private static let cursorEvents = ["sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "stop", "sessionEnd"]

    /// Reads lifecycle metadata only. Prompt, transcript, tool input and output are never persisted.
    /// Sources: https://code.claude.com/docs/en/hooks, https://learn.chatgpt.com/docs/hooks,
    /// and https://cursor.com/docs/hooks (Cursor has a different payload and configuration).
    public static func parse(_ data: Data, provider: AgentProvider, now: Date = .now) throws -> AgentSession? {
        guard data.count <= 4 * 1_024 * 1_024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.unavailable("Invalid agent event.")
        }
        if provider == .cursor { return try parseCursor(root, now: now) }
        guard let sessionID = root["session_id"] as? String, !sessionID.isEmpty, sessionID.count <= 200,
              sessionID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0) }),
              let path = root["cwd"] as? String, path.hasPrefix("/"), path.count <= 4_096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let event = root["hook_event_name"] as? String else {
            throw UsageError.unavailable("Invalid agent event.")
        }
        // Child tool events must not overwrite the parent session's state.
        if let child = root["agent_id"] as? String, !child.isEmpty { return nil }
        let status: AgentStatus
        switch event {
        case "SessionStart": status = .idle
        case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "ElicitationResult": status = .running
        case "PreToolUse":
            status = ["AskUserQuestion", "request_user_input"].contains(root["tool_name"] as? String ?? "") ? .waiting : .running
        case "PermissionRequest", "Elicitation": status = .waiting
        case "Notification":
            guard ["permission_prompt", "idle_prompt", "elicitation_dialog", "elicitation_url_dialog"].contains(root["notification_type"] as? String ?? "") else { return nil }
            status = .waiting
        case "Stop": status = .completed
        case "StopFailure" where provider == .claude: status = .failed
        case "Interrupt" where provider == .codex: status = .interrupted
        case "SessionEnd": status = .ended
        default: return nil
        }
        return AgentSession(sessionID: sessionID, provider: provider, projectPath: path, status: status, updatedAt: now)
    }

    private static func parseCursor(_ root: [String: Any], now: Date) throws -> AgentSession? {
        guard let event = root["hook_event_name"] as? String else { throw UsageError.unavailable("Invalid Cursor event.") }
        // Workspace and subagent hooks do not describe the main conversation's state.
        guard cursorEvents.contains(event) else { return nil }
        if let child = root["agent_id"] as? String, !child.isEmpty { return nil }
        let sessionID = root["conversation_id"] as? String ?? root["session_id"] as? String
        let path = (root["workspace_roots"] as? [String])?.first
        let identifierCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        guard let sessionID, !sessionID.isEmpty, sessionID.count <= 200,
              sessionID.unicodeScalars.allSatisfy({ identifierCharacters.contains($0) }),
              let path, path.hasPrefix("/"), path.count <= 4_096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw UsageError.unavailable("Invalid Cursor session or workspace.")
        }
        if let explicitID = root["session_id"] as? String, explicitID != sessionID {
            throw UsageError.unavailable("Cursor session identifiers do not match.")
        }
        let status: AgentStatus
        switch event {
        case "sessionStart": status = .idle
        case "beforeSubmitPrompt", "postToolUse": status = .running
        case "preToolUse":
            // Only an explicitly reported question tool establishes that input is needed.
            status = root["tool_name"] as? String == "AskQuestion" ? .waiting : .running
        case "postToolUseFailure": status = root["is_interrupt"] as? Bool == true ? .interrupted : .running
        case "stop":
            switch root["status"] as? String {
            case "completed": status = .completed
            case "error": status = .failed
            case "aborted": status = .interrupted
            default: return nil
            }
        case "sessionEnd":
            switch root["reason"] as? String {
            case "error": status = .failed
            case "aborted": status = .interrupted
            case "completed", "window_close", "user_close": status = .ended
            default: return nil
            }
        default: return nil
        }
        var eventID: String?
        if event == "stop", let generation = root["generation_id"] as? String, !generation.isEmpty,
           generation.count <= 200, generation.unicodeScalars.allSatisfy({ identifierCharacters.contains($0) }) {
            let loop = root["loop_count"] as? Int ?? 0
            guard loop >= 0 else { throw UsageError.unavailable("Invalid Cursor loop count.") }
            eventID = generation + ":stop:\(loop):" + status.rawValue
        }
        return AgentSession(sessionID: sessionID, provider: .cursor, projectPath: path, status: status, updatedAt: now, eventID: eventID)
    }

    public static func read(directory: URL = directory) throws -> [AgentSession] {
        let file = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        guard data.count <= 1_024 * 1_024 else { throw UsageError.unavailable("Agent status file is too large.") }
        return try JSONDecoder().decode([AgentSession].self, from: data)
    }

    public static func capture(_ data: Data, provider: AgentProvider, directory: URL = directory, now: Date = .now) throws {
        guard let session = try parse(data, provider: provider, now: now) else { return }
        try withLock(directory: directory) {
            var sessions = try read(directory: directory)
            if let previous = sessions.first(where: { $0.id == session.id }) {
                if previous.updatedAt > session.updatedAt { return }
                // Cursor creates a conversation asynchronously; its delayed sessionStart must
                // not erase a prompt or outcome that reached the bridge first.
                if session.provider == .cursor, session.status == .idle, previous.status != .idle { return }
                if let eventID = session.eventID, previous.eventID == eventID { return }
            }
            sessions.removeAll { $0.id == session.id || now.timeIntervalSince($0.updatedAt) > 7 * 86_400 }
            sessions.append(session)
            // ponytail: a bounded local list covers the notch; use a database only for session history.
            sessions = Array(sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(100))
            try save(sessions, directory: directory)
        }
    }

    public static func dismiss(_ session: AgentSession, directory: URL = directory) throws {
        try withLock(directory: directory) {
            try save(read(directory: directory).filter { $0.id != session.id }, directory: directory)
        }
    }

    private static func save(_ sessions: [AgentSession], directory: URL) throws {
        let file = directory.appendingPathComponent(filename)
        try JSONEncoder().encode(sessions).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func withLock(directory: URL, operation: () throws -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(directory.appendingPathComponent("agent-sessions.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UsageError.unavailable("Cannot open the agent status lock.") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw UsageError.unavailable("Cannot lock agent status.") }
        defer { flock(descriptor, LOCK_UN) }
        try operation()
    }

    public static func configurationURL(for provider: AgentProvider, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if provider == .cursor { return home.appendingPathComponent(".cursor/hooks.json") }
        let variable = provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        let configured = environment[variable].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        return (configured ?? home.appendingPathComponent(provider == .claude ? ".claude" : ".codex"))
            .appendingPathComponent(provider == .claude ? "settings.json" : "hooks.json")
    }

    /// Merge only Houston's marked handlers, preserving other hooks, permissions and configuration.
    public static func mergedConfiguration(_ data: Data?, provider: AgentProvider, executable: URL, installing: Bool = true) throws -> Data {
        var root: [String: Any] = [:]
        if let data {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UsageError.unavailable("Agent configuration must be a JSON object. Existing settings were preserved.")
            }
            root = object
        }
        if installing, root["disableAllHooks"] as? Bool == true {
            throw UsageError.unavailable("Hooks are disabled in this configuration. Enable them in your agent before connecting Houston.")
        }
        var hooks: [String: Any] = [:]
        if let existing = root["hooks"] {
            guard let object = existing as? [String: Any] else { throw UsageError.unavailable("Unrecognized hooks configuration. Existing settings were preserved.") }
            hooks = object
        }
        if provider == .cursor {
            if let version = root["version"], version as? Int != 1 {
                throw UsageError.unavailable("Unsupported Cursor hooks version. Existing settings were preserved.")
            }
            for event in Set(hooks.keys).union(cursorEvents) {
                guard hooks[event] == nil || hooks[event] is [[String: Any]] else {
                    throw UsageError.unavailable("Unrecognized \(event) hooks. Existing settings were preserved.")
                }
                var handlers = (hooks[event] as? [[String: Any]] ?? []).filter {
                    !(($0["command"] as? String)?.hasSuffix(" --agent-event cursor" + marker) ?? false)
                }
                if installing, cursorEvents.contains(event) {
                    handlers.append(["command": shellQuote(executable.path) + " --agent-event cursor" + marker, "timeout": 3])
                }
                if !handlers.isEmpty { hooks[event] = handlers } else { hooks.removeValue(forKey: event) }
            }
            if installing { root["version"] = 1 }
            root["hooks"] = hooks
            return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        }
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd"]
            + (provider == .claude ? ["StopFailure", "PostToolUseFailure", "Notification", "Elicitation", "ElicitationResult"] : ["Interrupt"])
        for event in Set(hooks.keys).union(events) {
            guard hooks[event] == nil || hooks[event] is [[String: Any]] else {
                throw UsageError.unavailable("Unrecognized \(event) hooks. Existing settings were preserved.")
            }
            var groups: [[String: Any]] = []
            for var group in hooks[event] as? [[String: Any]] ?? [] {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    throw UsageError.unavailable("Unrecognized \(event) hook handlers. Existing settings were preserved.")
                }
                let remaining = handlers.filter { !(($0["command"] as? String)?.hasSuffix(marker) ?? false) }
                if !remaining.isEmpty || handlers.isEmpty { group["hooks"] = remaining; groups.append(group) }
            }
            if installing, events.contains(event) {
                var group: [String: Any] = ["hooks": [["type": "command", "command": shellQuote(executable.path) + " --agent-event " + provider.rawValue + marker, "timeout": 3]]]
                if event == "Notification" { group["matcher"] = "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog" }
                groups.append(group)
            }
            if !groups.isEmpty { hooks[event] = groups } else { hooks.removeValue(forKey: event) }
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func isConfigured(_ data: Data?, provider: AgentProvider) -> Bool {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["disableAllHooks"] as? Bool != true, let hooks = root["hooks"] as? [String: Any] else { return false }
        if provider == .cursor {
            guard root["version"] as? Int == 1 else { return false }
            return (hooks["beforeSubmitPrompt"] as? [[String: Any]] ?? []).contains {
                ($0["command"] as? String)?.hasSuffix(" --agent-event cursor" + marker) ?? false
            }
        }
        return (hooks["UserPromptSubmit"] as? [[String: Any]] ?? []).contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { handler in
                (handler["command"] as? String)?.hasSuffix(" --agent-event " + provider.rawValue + marker) ?? false
            }
        }
    }

    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
