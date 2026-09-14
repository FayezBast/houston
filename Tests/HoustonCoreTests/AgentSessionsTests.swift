import XCTest
@testable import HoustonCore

final class AgentSessionsTests: XCTestCase {
    private func event(_ name: String, extras: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["hook_event_name": name, "session_id": "session-1", "cwd": "/Users/dev/My Project"].merging(extras) { _, new in new })
    }

    func testRealLifecycleEventsAndUnsupportedEvents() throws {
        for provider in [AgentProvider.claude, .codex] {
            XCTAssertEqual(try AgentBridge.parse(event("SessionStart"), provider: provider)?.status, .idle)
            XCTAssertEqual(try AgentBridge.parse(event("UserPromptSubmit"), provider: provider)?.status, .running)
            XCTAssertEqual(try AgentBridge.parse(event("PermissionRequest"), provider: provider)?.status, .waiting)
            XCTAssertEqual(try AgentBridge.parse(event("PostToolUse"), provider: provider)?.status, .running)
            XCTAssertEqual(try AgentBridge.parse(event("Stop"), provider: provider)?.status, .completed)
            XCTAssertEqual(try AgentBridge.parse(event("SessionEnd"), provider: provider)?.status, .ended)
            XCTAssertNil(try AgentBridge.parse(event("UnrecognizedFutureHook"), provider: provider))
            XCTAssertNil(try AgentBridge.parse(event("PostToolUse", extras: ["agent_id": "child"]), provider: provider))
        }
        XCTAssertEqual(try AgentBridge.parse(event("StopFailure"), provider: .claude)?.status, .failed)
        XCTAssertNil(try AgentBridge.parse(event("StopFailure"), provider: .codex), "Do not invent failure events Codex does not support")
        XCTAssertEqual(try AgentBridge.parse(event("Interrupt"), provider: .codex)?.status, .interrupted)
        XCTAssertEqual(try AgentBridge.parse(event("PreToolUse", extras: ["tool_name": "AskUserQuestion"]), provider: .claude)?.status, .waiting)
        XCTAssertNil(try AgentBridge.parse(event("Notification", extras: ["notification_type": "auth_success"]), provider: .claude))
        XCTAssertEqual(try AgentBridge.parse(event("Notification", extras: ["notification_type": "permission_prompt"]), provider: .claude)?.status, .waiting)
        XCTAssertThrowsError(try AgentBridge.parse(event("Stop", extras: ["session_id": "../../other"]), provider: .claude))
        XCTAssertThrowsError(try AgentBridge.parse(event("Stop", extras: ["cwd": "https://outside.example"]), provider: .claude))
    }

    func testCaptureStoresOnlyMetadataAndProtectsAgainstOlderEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try AgentBridge.capture(event("Stop", extras: ["prompt": "private prompt", "last_assistant_message": "private answer", "transcript_path": "/private/transcript"]), provider: .claude, directory: directory, now: now)
        try AgentBridge.capture(event("UserPromptSubmit"), provider: .claude, directory: directory, now: now.addingTimeInterval(-1))
        let saved = try AgentBridge.read(directory: directory)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.status, .completed)
        XCTAssertEqual(saved.first?.updatedAt, now)
        let text = try String(contentsOf: directory.appendingPathComponent(AgentBridge.filename), encoding: .utf8)
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("transcript"))
        XCTAssertFalse(text.contains("prompt"))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(AgentBridge.filename).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try AgentBridge.dismiss(saved[0], directory: directory)
        XCTAssertTrue(try AgentBridge.read(directory: directory).isEmpty)
    }

    func testHookMergePreservesPermissionsAndOtherHandlersAndIsIdempotent() throws {
        let original = Data(#"{"permissions":{"defaultMode":"default","deny":["Bash(rm *)"]},"statusLine":{"type":"command","command":"my-status"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-guardrail","timeout":10}]}]}}"#.utf8)
        let executable = URL(fileURLWithPath: "/Applications/Houston's App.app/Contents/MacOS/Houston")
        for provider in [AgentProvider.claude, .codex] {
            let once = try AgentBridge.mergedConfiguration(original, provider: provider, executable: executable)
            let twice = try AgentBridge.mergedConfiguration(once, provider: provider, executable: executable)
            XCTAssertEqual(once, twice)
            XCTAssertTrue(AgentBridge.isConfigured(once, provider: provider))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: once) as? [String: Any])
            XCTAssertEqual((root["permissions"] as? [String: Any])?["defaultMode"] as? String, "default")
            XCTAssertEqual((root["statusLine"] as? [String: Any])?["command"] as? String, "my-status")
            let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
            let groups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
            XCTAssertEqual(groups.count, 2)
            XCTAssertEqual((groups[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String, "my-guardrail")
            let command = try XCTUnwrap((groups[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String)
            XCTAssertTrue(command.contains("Houston'\\''s App"), "The executable is shell-quoted")
            XCTAssertFalse(String(data: once, encoding: .utf8)!.contains("bypass"))
            let removed = try AgentBridge.mergedConfiguration(once, provider: provider, executable: executable, installing: false)
            XCTAssertFalse(AgentBridge.isConfigured(removed, provider: provider))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: removed) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: original) as? NSDictionary)
        }
        for invalid in [#"{"hooks":[]}"#, #"{"hooks":{"Stop":"invalid"}}"#, #"{"hooks":{"Stop":[{"hooks":"invalid"}]}}"#, #"{"disableAllHooks":true}"#] {
            XCTAssertThrowsError(try AgentBridge.mergedConfiguration(Data(invalid.utf8), provider: .claude, executable: executable))
        }
    }

    func testStaleStateAndResumeEscapingAreHonest() {
        let now = Date.now
        let session = AgentSession(sessionID: "session-1", provider: .claude, projectPath: "/Users/dev/project's $(touch secret)", status: .running, updatedAt: now.addingTimeInterval(-1_000))
        XCTAssertTrue(session.isStale(at: now))
        XCTAssertFalse(session.needsAttention)
        XCTAssertEqual(session.status.title, "Running")
        XCTAssertEqual(session.resumeCommand, "cd -- '/Users/dev/project'\\''s $(touch secret)' && claude --resume 'session-1'")
        XCTAssertEqual(AgentBridge.configurationURL(for: .codex, home: URL(fileURLWithPath: "/home/dev"), environment: ["CODEX_HOME": "/custom/codex"]).path, "/custom/codex/hooks.json")
        XCTAssertEqual(AgentBridge.configurationURL(for: .cursor, home: URL(fileURLWithPath: "/home/dev"), environment: ["CODEX_HOME": "/custom/codex"]).path, "/home/dev/.cursor/hooks.json")
        XCTAssertNil(AgentSession(sessionID: "cursor-1", provider: .cursor, projectPath: "/project", status: .idle).resumeCommand)
        XCTAssertEqual(AgentProvider.cursor.name, "Cursor")
        XCTAssertEqual(AgentProvider.cursor.logoName, "cursor")
        XCTAssertEqual(AgentProvider.codex.logoName, "openai")
    }

    func testCurrentActivityAgesIntoHistoryWithoutChangingStatus() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for name in ["SessionStart", "UserPromptSubmit", "PermissionRequest"] {
            let session = try XCTUnwrap(AgentBridge.parse(event(name), provider: .claude, now: now))
            XCTAssertTrue(session.isCurrent(at: now.addingTimeInterval(900)), name)
            XCTAssertFalse(session.isCurrent(at: now.addingTimeInterval(901)), name)
            XCTAssertFalse(session.status.isFinished, "Silence must not be treated as completion")
        }
        for name in ["Stop", "StopFailure"] {
            let session = try XCTUnwrap(AgentBridge.parse(event(name), provider: .claude, now: now))
            XCTAssertTrue(session.isCurrent(at: now.addingTimeInterval(300)), name)
            XCTAssertFalse(session.isCurrent(at: now.addingTimeInterval(301)), name)
            XCTAssertTrue(session.status.isFinished)
        }
        for name in ["Interrupt", "SessionEnd"] {
            let session = try XCTUnwrap(AgentBridge.parse(event(name), provider: .codex, now: now))
            XCTAssertFalse(session.isCurrent(at: now), name)
            XCTAssertTrue(session.status.isFinished)
        }
    }

    // Representative payloads follow https://cursor.com/docs/hooks#common-schema.
    // Cursor's ordinary events have conversation_id and workspace_roots, not session_id/cwd.
    private func cursorEvent(_ name: String, extras: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "hook_event_name": name, "conversation_id": "cursor-session-1", "generation_id": "generation-1",
            "workspace_roots": ["/Users/dev/Cursor Project", "/Users/dev/Other Project"],
            "cursor_version": "2.6", "model": "composer", "user_email": "private@example.com",
            "transcript_path": "/private/transcript"
        ].merging(extras) { _, new in new })
    }

    func testCursorLifecycleUsesNativePayloadAndReportedOutcomes() throws {
        let started = try XCTUnwrap(AgentBridge.parse(cursorEvent("sessionStart", extras: ["session_id": "cursor-session-1", "is_background_agent": false, "composer_mode": "agent"]), provider: .cursor))
        XCTAssertEqual(started.sessionID, "cursor-session-1")
        XCTAssertEqual(started.projectPath, "/Users/dev/Cursor Project")
        XCTAssertEqual(started.status, .idle)
        XCTAssertEqual(try AgentBridge.parse(cursorEvent("beforeSubmitPrompt", extras: ["prompt": "private prompt", "attachments": []]), provider: .cursor)?.status, .running)
        XCTAssertEqual(try AgentBridge.parse(cursorEvent("preToolUse", extras: ["tool_name": "AskQuestion", "tool_input": ["questions": []]]), provider: .cursor)?.status, .waiting)
        XCTAssertEqual(try AgentBridge.parse(cursorEvent("preToolUse", extras: ["tool_name": "Shell"]), provider: .cursor)?.status, .running, "Tool execution does not prove a permission prompt is open")
        XCTAssertEqual(try AgentBridge.parse(cursorEvent("postToolUse", extras: ["tool_name": "AskQuestion"]), provider: .cursor)?.status, .running)
        XCTAssertEqual(try AgentBridge.parse(cursorEvent("postToolUseFailure", extras: ["failure_type": "error", "is_interrupt": false]), provider: .cursor)?.status, .running, "One failed tool is not a failed turn")
        XCTAssertEqual(try AgentBridge.parse(cursorEvent("postToolUseFailure", extras: ["is_interrupt": true]), provider: .cursor)?.status, .interrupted)
        for (value, expected) in [("completed", AgentStatus.completed), ("error", .failed), ("aborted", .interrupted)] {
            XCTAssertEqual(try AgentBridge.parse(cursorEvent("stop", extras: ["status": value, "loop_count": 0]), provider: .cursor)?.status, expected)
        }
        for (reason, expected) in [("completed", AgentStatus.ended), ("window_close", .ended), ("user_close", .ended), ("aborted", .interrupted), ("error", .failed)] {
            XCTAssertEqual(try AgentBridge.parse(cursorEvent("sessionEnd", extras: ["session_id": "cursor-session-1", "reason": reason, "duration_ms": 45000, "final_status": reason]), provider: .cursor)?.status, expected)
        }
    }

    func testCursorRejectsInvalidMetadataAndDoesNotInventEventsOrSuccess() throws {
        let invalidMetadata: [[String: Any]] = [
            ["conversation_id": "../../private"], ["conversation_id": ""], ["conversation_id": NSNull()],
            ["session_id": "mismatched"], ["workspace_roots": []], ["workspace_roots": ["relative"]],
            ["workspace_roots": ["/project\nnext"]], ["workspace_roots": "invalid"]
        ]
        for extras in invalidMetadata {
            XCTAssertThrowsError(try AgentBridge.parse(cursorEvent("beforeSubmitPrompt", extras: extras), provider: .cursor))
        }
        XCTAssertThrowsError(try AgentBridge.parse(Data("{}".utf8), provider: .cursor))
        XCTAssertThrowsError(try AgentBridge.parse(Data("[]".utf8), provider: .cursor))
        XCTAssertNil(try AgentBridge.parse(cursorEvent("stop"), provider: .cursor))
        XCTAssertNil(try AgentBridge.parse(cursorEvent("stop", extras: ["status": "unknown"]), provider: .cursor))
        XCTAssertNil(try AgentBridge.parse(cursorEvent("sessionEnd", extras: ["reason": "unknown"]), provider: .cursor))
        XCTAssertNil(try AgentBridge.parse(cursorEvent("PermissionRequest"), provider: .cursor))
        XCTAssertNil(try AgentBridge.parse(cursorEvent("subagentStop", extras: ["status": "completed"]), provider: .cursor))
        XCTAssertNil(try AgentBridge.parse(cursorEvent("preToolUse", extras: ["agent_id": "child"]), provider: .cursor))
        XCTAssertNil(try AgentBridge.parse(Data(#"{"hook_event_name":"workspaceOpen","workspace_roots":["/project"]}"#.utf8), provider: .cursor))
    }

    func testCursorCaptureDeduplicatesStopsButPreservesNewTurnsAndLoops() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stop = try cursorEvent("stop", extras: ["status": "completed", "loop_count": 0, "text": "private answer"])
        try AgentBridge.capture(stop, provider: .cursor, directory: directory, now: now)
        try AgentBridge.capture(stop, provider: .cursor, directory: directory, now: now.addingTimeInterval(1))
        XCTAssertEqual(try AgentBridge.read(directory: directory).first?.updatedAt, now)
        let later = try cursorEvent("stop", extras: ["generation_id": "generation-2", "status": "completed", "loop_count": 0])
        try AgentBridge.capture(later, provider: .cursor, directory: directory, now: now.addingTimeInterval(2))
        XCTAssertEqual(try AgentBridge.read(directory: directory).first?.updatedAt, now.addingTimeInterval(2))
        let loop = try cursorEvent("stop", extras: ["generation_id": "generation-2", "status": "completed", "loop_count": 1])
        try AgentBridge.capture(loop, provider: .cursor, directory: directory, now: now.addingTimeInterval(3))
        let saved = try AgentBridge.read(directory: directory)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.updatedAt, now.addingTimeInterval(3))
        let stored = try String(contentsOf: directory.appendingPathComponent(AgentBridge.filename), encoding: .utf8)
        XCTAssertFalse(stored.contains("private"))
        XCTAssertFalse(stored.contains("transcript"))
        XCTAssertFalse(stored.contains("model"))
    }

    func testCursorRepeatedStopAfterPromptKeepsNewTurnRunning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stopped = try cursorEvent("stop", extras: ["status": "completed", "loop_count": 0])
        try AgentBridge.capture(stopped, provider: .cursor, directory: directory, now: now)
        try AgentBridge.capture(cursorEvent("beforeSubmitPrompt", extras: ["generation_id": "generation-2"]),
                                provider: .cursor, directory: directory, now: now.addingTimeInterval(1))
        try AgentBridge.capture(cursorEvent("postToolUse", extras: ["generation_id": "generation-2"]),
                                provider: .cursor, directory: directory, now: now.addingTimeInterval(2))
        let running = try AgentBridge.read(directory: directory)

        try AgentBridge.capture(stopped, provider: .cursor, directory: directory, now: now.addingTimeInterval(3))
        XCTAssertEqual(try AgentBridge.read(directory: directory), running,
                       "Repeating the previous stop must not end a newer turn, including after tool events")

        try AgentBridge.capture(cursorEvent("stop", extras: ["generation_id": "generation-2", "status": "completed", "loop_count": 0]),
                                provider: .cursor, directory: directory, now: now.addingTimeInterval(4))
        let completed = try XCTUnwrap(AgentBridge.read(directory: directory).first)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.updatedAt, now.addingTimeInterval(4), "The new turn's own stop is still accepted")
    }

    func testDelayedCursorSessionStartDoesNotEraseRunningOrCompletedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = try cursorEvent("sessionStart", extras: ["session_id": "cursor-session-1"])
        try AgentBridge.capture(cursorEvent("beforeSubmitPrompt"), provider: .cursor, directory: directory, now: now)
        try AgentBridge.capture(start, provider: .cursor, directory: directory, now: now.addingTimeInterval(1))
        XCTAssertEqual(try AgentBridge.read(directory: directory).first?.status, .running)
        XCTAssertEqual(try AgentBridge.read(directory: directory).first?.updatedAt, now)
        try AgentBridge.capture(cursorEvent("stop", extras: ["status": "completed", "loop_count": 0]), provider: .cursor, directory: directory, now: now.addingTimeInterval(2))
        try AgentBridge.capture(start, provider: .cursor, directory: directory, now: now.addingTimeInterval(3))
        XCTAssertEqual(try AgentBridge.read(directory: directory).first?.status, .completed)
        XCTAssertEqual(try AgentBridge.read(directory: directory).first?.updatedAt, now.addingTimeInterval(2))
        try AgentBridge.capture(cursorEvent("beforeSubmitPrompt", extras: ["generation_id": "generation-2"]), provider: .cursor, directory: directory, now: now.addingTimeInterval(4))
        XCTAssertEqual(try AgentBridge.read(directory: directory).first?.status, .running, "The next actual prompt still starts a new turn")
    }

    func testCursorHookConfigurationPreservesUserScriptsAndDisconnectsOnlyHouston() throws {
        let original = Data(#"{"version":1,"custom":{"keep":true},"hooks":{"beforeSubmitPrompt":[{"command":"my-guardrail","timeout":10,"failClosed":true}],"stop":[{"type":"prompt","prompt":"Check work","loop_limit":7}],"workspaceOpen":[{"command":"register-workspace"}]}}"#.utf8)
        let executable = URL(fileURLWithPath: "/Applications/Houston's App.app/Contents/MacOS/Houston")
        let once = try AgentBridge.mergedConfiguration(original, provider: .cursor, executable: executable)
        XCTAssertEqual(once, try AgentBridge.mergedConfiguration(once, provider: .cursor, executable: executable))
        XCTAssertTrue(AgentBridge.isConfigured(once, provider: .cursor))
        XCTAssertFalse(AgentBridge.isConfigured(once, provider: .claude))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: once) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 1)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let prompt = try XCTUnwrap(hooks["beforeSubmitPrompt"] as? [[String: Any]])
        XCTAssertEqual(prompt.count, 2)
        XCTAssertEqual(prompt[0]["command"] as? String, "my-guardrail")
        XCTAssertEqual(prompt[0]["failClosed"] as? Bool, true)
        XCTAssertEqual(prompt[1]["command"] as? String, "'/Applications/Houston'\\''s App.app/Contents/MacOS/Houston' --agent-event cursor # Houston agent status")
        XCTAssertEqual(prompt[1]["timeout"] as? Int, 3)
        XCTAssertNil(prompt[1]["hooks"], "Cursor uses direct command entries, not Claude's nested groups")
        let removed = try AgentBridge.mergedConfiguration(once, provider: .cursor, executable: executable, installing: false)
        XCTAssertFalse(AgentBridge.isConfigured(removed, provider: .cursor))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: removed) as? NSDictionary, try JSONSerialization.jsonObject(with: original) as? NSDictionary)
        XCTAssertTrue(AgentBridge.isConfigured(try AgentBridge.mergedConfiguration(nil, provider: .cursor, executable: executable), provider: .cursor))
        for invalid in [#"{"version":2}"#, #"{"version":"1"}"#, #"{"hooks":[]}"#, #"{"hooks":{"stop":"invalid"}}"#, #"{"disableAllHooks":true}"#] {
            XCTAssertThrowsError(try AgentBridge.mergedConfiguration(Data(invalid.utf8), provider: .cursor, executable: executable))
        }
    }
}
