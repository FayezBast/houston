import XCTest
@testable import HoustonCore

final class AgentSessionsTests: XCTestCase {
    private func event(_ name: String, extras: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["hook_event_name": name, "session_id": "session-1", "cwd": "/Users/dev/My Project"].merging(extras) { _, new in new })
    }

    func testRealLifecycleEventsAndUnsupportedEvents() throws {
        for provider in AgentProvider.allCases {
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
        for provider in AgentProvider.allCases {
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
    }
}
