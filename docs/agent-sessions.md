# Agent session status

Houston receives local lifecycle events from Claude Code and Codex. The Agents tab shows the latest event for each session, and the notch highlights sessions that need attention.

## Connect an agent

1. Put Houston in its intended installation location before connecting. Hook commands contain the absolute path to the Houston executable.
2. Open Houston’s Agents tab and choose **Connect** beside Claude Code or Codex.
3. Restart or resume the agent. Open `/hooks` to inspect Houston’s commands. In Codex, review and trust the new hooks before they can run.
4. Submit a prompt. The session should appear in Houston as running, followed by its next supported lifecycle event.

Claude Code configuration is merged into `~/.claude/settings.json`; Codex configuration is merged into `~/.codex/hooks.json`. Houston respects absolute `CLAUDE_CONFIG_DIR` and `CODEX_HOME` environment variables when they are present in Houston’s process environment. Existing permissions and other hooks are preserved. Houston saves the first existing configuration as a sibling `.houston-backup` file before writing changes. It does not approve tools or bypass hook trust.

Use the connection’s menu to update hooks after moving Houston, or to disconnect. Disconnect removes only Houston’s marked commands. Restart the agent afterward.

## Status meanings and limits

- **Ready:** a session started or resumed; this does not mean work is running.
- **Running:** a prompt or supported tool lifecycle event was received.
- **Needs input:** a permission request or supported question/notification event was received.
- **Response ready:** the agent emitted `Stop`. The current response has ended; this does not prove the entire task is complete. Other stop hooks may continue the conversation, and background work may remain.
- **Turn failed:** Claude Code emitted `StopFailure` for a turn-ending API error. A failed individual tool call is not treated as a failed turn.
- **Interrupted:** Codex emitted `Interrupt`.
- **Session ended:** the agent emitted `SessionEnd`; this does not imply success.

Status is based on received events, not process detection. An active-looking session with no event for 15 minutes is labeled as last known status. There is no inferred completion when a process disappears. Unexpected exits, disabled hooks, managed restrictions, unsupported agent versions, and missing lifecycle events can leave an old status until a new event arrives.

Codex hooks currently do not report every question or API failure. Claude Code’s supported question and permission hooks provide broader waiting coverage. Cloud sessions on another machine cannot write to this Mac’s bridge. Child events carrying an `agent_id` are ignored so that a subagent does not overwrite its parent’s state.

## Return to a session

**Open session** attempts to open a Codex task using the installed Codex app’s URL handler. If that handler is unavailable, Houston opens the project and explains the fallback. Claude Code’s **Open project** opens its project directory. Both providers offer **Copy resume command** to return to the recorded session from a terminal.

## Local storage

Houston stores only provider, session ID, project path, status, and event timestamp in `~/Library/Application Support/Houston/agent-sessions.json`, with file permissions restricted to the current user. Prompts, transcripts, tool arguments, tool output, and assistant messages are not persisted. The list retains at most 100 sessions and removes entries older than seven days when new events arrive. Dismissing a session hides it until its next event.

The bridge accepts hook JSON on stdin through `Houston --agent-event claude` or `Houston --agent-event codex`. It produces no permission decision. Hook configuration uses short timeouts and does not change the agent’s approval policies.

Lifecycle schemas and setup behavior are documented in the official [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) and [Codex hooks reference](https://learn.chatgpt.com/docs/hooks).
