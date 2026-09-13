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

## In the island

The notch follows each session the way the Dynamic Island follows a Live Activity, independently of macOS notification settings:

- **Start.** When a prompt is submitted, the island peeks out for about 2.5 seconds: the agent’s mark sits inside a ring of turning dots beside the camera, **Working** appears on the other side, and the agent and project name show underneath. There is no sound.
- **Working.** After the peek settles, the compact strip keeps a small ring of dots turning on the trailing side, with a count when more than one session is live. The turn is a Core Animation transaction, so it costs the app no main-thread time.
- **Needs input.** A permission request or supported question peeks out with more bounce: an orange raised hand waves (on macOS 15 and later; earlier systems bounce it) behind a double knock of light, **Needs input** appears beside it, and the island plays two soft wooden taps. The hand keeps breathing in the compact strip until the agent moves on; answering it retracts the peek quietly.
- **Response ready.** `Stop` peeks out with a green check that pops in behind a bloom of light and a short rising chime. The check then holds in the compact strip for five minutes.
- **Turn failed.** `StopFailure` peeks out with a red triangle that shakes once and a soft falling tone.

The compact strip shows the session that needs the person first: a request or a failed turn outranks work in progress, which outranks a response that already landed, and newer sessions lead within a rank. Ready, interrupted, and ended sessions make no moment. Moments are not shown while the panel is open (the Agents tab shows the state itself) or during Preview, and events older than two minutes when Houston first reads them are not announced.

The chimes are synthesized by Houston, play through the system output at the system volume, and can be turned off in **Tools → Notifications → Island sounds** without affecting the motion. When island sounds are on, the opt-in macOS notifications for agent activity are delivered as silent banners so an event never sounds twice. Reduce Motion replaces every spring, pop, and bloom with a short fade and keeps the working dots and the raised hand still.

## Return to a session

**Open session** attempts to open a Codex task using the installed Codex app’s URL handler. If that handler is unavailable, Houston opens the project and explains the fallback. Claude Code’s **Open project** opens its project directory. Both providers offer **Copy resume command** to return to the recorded session from a terminal.

## Local storage

Houston stores only provider, session ID, project path, status, and event timestamp in `~/Library/Application Support/Houston/agent-sessions.json`, with file permissions restricted to the current user. Prompts, transcripts, tool arguments, tool output, and assistant messages are not persisted. The list retains at most 100 sessions and removes entries older than seven days when new events arrive. Dismissing a session hides it until its next event.

The bridge accepts hook JSON on stdin through `Houston --agent-event claude` or `Houston --agent-event codex`. It produces no permission decision. Hook configuration uses short timeouts and does not change the agent’s approval policies.

Lifecycle schemas and setup behavior are documented in the official [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) and [Codex hooks reference](https://learn.chatgpt.com/docs/hooks).
