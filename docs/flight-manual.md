# Houston flight manual

[← Back to Houston](../README.md)

Detailed setup, behavior, integration notes, and recorded verification. Run commands from the repository root.

A native macOS notch companion for AI coding usage, this Mac’s vitals, and GitHub activity, designed after the Dynamic Island: one black shape that grows out of the camera housing. Built with Swift, SwiftUI, and AppKit, with SweetCookieKit for browser sign-ins. Requires macOS 14 or newer; the release build includes Apple Silicon and Intel binaries. The app is macOS-only; iPhone, iPad, Windows, and web are not supported.

## Run

```sh
bash scripts/build.sh
open dist/Houston.app
```

Houston starts compact and unpinned. Hover at the island or its edge to open it; leaving closes it after 350 ms. The island opens and closes with a spring, growing out of the camera housing rather than opening a separate window. The panel is enlarged before the island springs open and shrinks only after the collapse has settled, and hover follows the island itself during that motion. Pin explicitly with the pin at the top-left of the open island (⌘P). Text fields stay open while editing; press Escape to dismiss. The panel no longer rebuilds when data refreshes. Mouse events drive hover, with one cancellable 350 ms close timer in the common run-loop mode. There is no repeating pointer timer while idle.

While Houston is focused, ⌘O shows it, ⌘P toggles pinning, ⌘1–5 switches sections (Usage, Mac, GitHub, Tools, Agents), ⌘R refreshes, and ⌘, opens Tools. Opening from the menu bar or keyboard keeps the panel available for keyboard navigation until you enter it with the pointer or dismiss it. Click the menu-bar icon to toggle the panel; right-click it to quit. Opening from the menu bar places Houston on the display under the pointer. On a display without a notch it is a detached pill below the menu bar. Its width and height fit the display’s usable area, including scaled and portrait layouts. The old development `--pinned` argument no longer changes startup behavior.

## Appearance and accessibility

Houston follows Apple’s Dynamic Island guidance: one opaque black shape in every presentation, so the island reads as part of the camera housing rather than a window over it. On a notched display its top corners flare outward into the menu bar and its bottom corners grow from 14 points when compact to 28 points when open; on other displays it is a detached pill. Native controls use the dark appearance throughout, with segmented navigation and the system accent color, and provider colors use their dark variants. A faint key line separates the open island from dark windows beneath it and starts below the camera row. Content sits in inset cards, concentric with the island’s corners, instead of running to its edge. Presentations morph with springs (opening in about 0.55 s with a little bounce, closing in 0.42 s); readings roll with numeric text transitions, meters and rings fill smoothly, and agent moments have their own choreography beside the camera: a starting session settles in inside a ring of turning dots, a request for input waves a raised hand behind a double knock of light and arrives with extra bounce, a finished response pops a green check out of a bloom, and a failed turn shakes its red triangle. The compact strip keeps the ring turning while an agent works and lets the hand breathe while one waits. Reduce Motion replaces all of that with short fades and holds the marks still. Increase Contrast strengthens the key line and card outlines. Scrolling follows the system’s scrollbar preference. Core graphs wrap on machines with many cores.

Usage opens directly to current allowances, with a **History** button and **Current usage** back action. Tools puts provider connections first, followed by compact favorites and notification preferences. Account setup and management expand on demand. History filters, session cards, and notification controls share consistent spacing, readable captions, and native controls across wide and narrow panels.

The compact island follows the compact Live Activity layout: two elements snug against the camera that read as one piece of information. The leading side shows one favorite provider’s logo inside a ring that fills with its remaining allowance; the trailing side shows the remaining percentage in a heavier rounded face, or the agent indicator while sessions are running or need attention. The strip beside the camera is 56 points wide on each side and stays in place when the island opens, so the open panel is visibly the same object, with the pin and collapse controls at its far edges. Favorites rotate every six seconds with a blur-and-scale content transition while the percentage rolls to the new value; Reduce Motion crossfades instead, and a single favorite does not rotate. Choose up to four favorites with the stars in **Tools → Providers**, or from a usage card’s action menu; choices persist. Codex, Claude, Cursor, and Copilot are selected initially, and disabled providers are skipped. Missing or expired allowances show `—` with an empty ring, earlier readings show `~` with a dimmed ring, confirmed unlimited allowances show `∞` with a full ring, and Preview is explicitly labeled. An unbudgeted API key never appears as unlimited credit. Tooltips and VoiceOver include the current provider and reading status. With no favorites, the island shows Houston’s mark and name.

**Tools → Providers** shows a grouped view of all seven integrations, their connection sources, supported allowance types, and current state. Usage cards include reset countdowns and a menu for refreshing one provider, opening its dashboard, and managing its compact favorite. Native menus keep the panel open until they close. The six-second rotation only updates the visible UI; it starts no network requests. With one favorite, the compact view instead redraws at quota expiration and staleness boundaries.

Hover handling follows [AppKit’s local and global mouse event APIs](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html). The island is opaque in every presentation, so Reduce Transparency needs no fallback. The presentation model, shape, and motion follow Apple’s [Live Activities guidance](https://developer.apple.com/design/human-interface-guidelines/live-activities) and the WWDC23 session [Design dynamic Live Activities](https://developer.apple.com/videos/play/wwdc2023/10194/): compact leading and trailing elements that hug the camera and read together, an expanded presentation that keeps their placement, concentric margins, an opaque black background with bold color for identity, a tinted key line, and content-replace transitions.

## Usage and Tools

### Agents, alerts, accounts, and history

- **Agents** shows local Claude Code and Codex sessions using their lifecycle hooks: running, needs input, response ready, failed where reported, interrupted, or ended. Choose **Connect** to install Houston's status hooks while preserving existing hooks and permission settings, then restart your coding tool and review `/hooks`. A response ending does not prove the whole task succeeded. The island follows each session like a Live Activity: it peeks out when a session starts, needs input, finishes, or fails, keeps a turning ring on the right while agents work or a breathing hand while one waits, shows the session that needs you first, and chimes for input requests, finished responses, and failed turns; clicking the strip opens Agents. See [island moments](agent-sessions.md#in-the-island). Codex sessions have direct app links where available; Claude sessions offer their project and an exact resume command. See [agent setup and limitations](agent-sessions.md).
- **Tools → Notifications** configures agent notifications, low-quota warnings (5–50% remaining), quota-reset notifications, and GitHub checks/reviews. Each is opt-in and uses macOS notification permission. **Island sounds**, on by default, plays Houston’s own short chimes for agent moments without notification permission; while it is on, agent notifications arrive as silent banners so nothing sounds twice. The first fresh reading establishes a quiet baseline; later threshold crossings and confirmed resets can notify. Stale, expired, failed, and Preview readings cannot invent quota events. Recent alerts also appear in Tools. Unknown account identities can produce low-quota warnings within the current app session, but never persisted history or reset inferences.
- **Island alerts.** While the panel is closed, every alert Houston sends (low quota, quota resets, GitHub checks and reviews) also peeks out of the island for five seconds, and agent moments peek on their own whether or not agent notifications are on: a tinted symbol beside the camera, a short headline on the other side, and one line of detail below, the way the Dynamic Island presents an update instead of relying on a banner. Hovering or clicking opens the relevant section, opening the panel dismisses the peek, a newer alert replaces it, and Preview never presents alerts. The peek keeps the camera area black and is never wider than the panel; the alert also stays in Recent alerts.
- **GitHub alerts** monitor the 30 most recently updated open PRs authored by the signed-in GitHub account, plus the latest five workflow runs in the watched repository, every five minutes while Houston runs—even with the panel closed. They report new failed/passed checks, changes requested, and approvals, with direct links. New commits and workflow reruns have separate identities; the watched repository uses workflow alerts instead of duplicate PR-check alerts. The first successful check is quiet. Partial/error responses preserve the previous baseline. This is polling, so intermediate states and activity beyond the bounded results may be missed. `--check-github-alerts` diagnoses the PR checks/review reader without sending notifications.
- **Tools → Claude / Cursor / OpenRouter → Accounts** adds labeled Work and Personal accounts, keeps their credentials in separate Keychain items, and displays their allowances side by side. Selection changes Houston's displayed account only. Existing provider connections remain available. Named-account management currently supports those three providers; others retain their local sign-in. See [account storage and identity](accounts.md).
- **Usage → History** shows seven- or thirty-day observations, account/window filters, observed exhausted windows, and a recent-pace estimate when enough fresh samples exist. Up to 90 days (100,000 samples) stay on this Mac. Collection begins with live readings; no history is fabricated. Subscription percentages and reported OpenRouter dollar spending have separate charts. Default sources need a known account identity; credential rotation may split their history. Named accounts use stable Houston account IDs. See [history and forecasts](usage-history.md).

**Tools** lets you enable or hide providers, inspect connection errors, and configure each source. Selections persist. The explicit **Preview** mode uses sample data. Live mode never fills missing data with zero usage.

| Tool | Source | Setup / limitations |
|---|---|---|
| Codex | Existing CLI sign-in; app-server rate limits | Install and sign in to Codex CLI. Live connection verified on the development Mac. |
| Claude Code | Connected Claude browser account, direct Claude Code sign-in, or local status-line bridge | Connect Claude imports an existing browser session or opens normal sign-in. Claude web usage verified live on the development Mac. The bridge reports after a terminal response. |
| Cursor | Cursor dashboard API, using a connected browser session or Cursor.app sign-in | Choose Tools → Cursor → Connect Cursor to reuse an existing browser session or sign in. Live usage verified on the development Mac. Supports returned Free/request quotas and current plan percentages; no assumed allowance sizes. |
| GitHub Copilot | GitHub CLI and Copilot usage endpoint | Uses `gh auth login`; live connection verified. Some plans/credentials do not expose quotas. |
| Gemini | Gemini CLI OAuth, Code Assist project discovery and quota API | Requires an eligible Code Assist account. Consumer/free, AI Pro and Ultra CLI OAuth ended June 18, 2026; Gemini web chat is separate. Refreshes expired tokens using the installed CLI's OAuth configuration. Tested with simulated responses; no eligible account installed here. |
| Windsurf | Read-only SQLite plan cache | Open Windsurf to populate it. Always labeled cached; not live-tested here because Windsurf is not installed. |
| OpenRouter | API key usage endpoint | Save a key under Tools → OpenRouter. Stored in macOS Keychain. Shows key spending and an optional key budget, not account balance. A zero-dollar cap means no allowance; only a null cap is unlimited. Requires a key for live verification. |

Usage refreshes every five minutes or on demand, independently per enabled provider, without blocking hover or the UI. Claude's bridge uses directory-change notifications, including atomic file replacements, instead of a repeating poll. Monitoring stops when Claude is disabled or Preview is active. Preview starts no new live requests; returning to live refreshes immediately. Expired windows wait for fresh data; failed fetches preserve a labeled previous reading. The first returned quota window supplies the headline percentage.

Changing a connection, disabling a provider, entering Preview or stopping Houston invalidates any pending usage result. Old responses cannot overwrite the replacement connection or its loading state. Connection windows validate usage before saving only the provider's session in Keychain. Background reads of Houston’s saved credentials and Claude Code’s Keychain item never open permission dialogs. Connect once, then Houston reuses the authorized credential in memory for automatic refreshes. If permission needs repair, choose **Check connection** under the provider (or the named account’s menu), then **Always Allow** in macOS. Ordinary Refresh stays noninteractive.

**Browser sign-in reuse.** Opening **Connect Claude** or **Connect Cursor** automatically checks existing Safari, Chromium, and Firefox-family browser profiles using [SweetCookieKit](https://github.com/steipete/SweetCookieKit), also used by CodexBar. This initial check never prompts for Keychain access. One distinct session is verified automatically; multiple sessions offer a profile choice. **Use browser sign-in…** lets you select a profile explicitly and permit macOS's browser Safe Storage prompt. Safari may require Full Disk Access for Houston. You can always sign in inside the connection window instead.

Queries are restricted to `claude.ai` or `cursor.com`; only recognized, unexpired session cookies with matching paths are used. Profiles are never combined. Houston leaves browser storage unchanged, saves only a verified session in its own Keychain item, and uses that saved account for later refreshes. Failed or canceled connections preserve the previous credential. If the saved session expires, reconnect to import a fresh one. Imports happen only when connecting, not on the five-minute refresh timer.

On September 13, 2026, granting Houston Full Disk Access for Safari on the development Mac enabled both Claude and Cursor browser-session imports. Both connections displayed live usage in Houston, and their verified credentials were saved in Houston's Keychain items.

For the researched provider strategies and current Gemini limitation, see [integration notes](usage-integrations.md) and [Google's deprecation notice](https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals).

Read the same live sources from the terminal without opening the UI or prompting for Keychain access:

```sh
dist/Houston.app/Contents/MacOS/Houston --check-usage
dist/Houston.app/Contents/MacOS/Houston --check-usage cursor
```

The command prints each returned allowance or an actionable error, and exits nonzero if a selected provider cannot be read. Claude uses its direct connection for this diagnostic; the terminal bridge is covered by the tests.

### Claude connections

Claude Code only runs status-line commands in a terminal session, so the Claude desktop app never feeds the bridge. Houston also offers direct connections under **Tools → Claude**; newer readings win when the bridge and a direct source both report.

**Claude web sign-in.** Choose **Connect Claude** to reuse your browser sign-in, or complete the normal sign-in in the window and choose **Use this account**. If the account has multiple Claude organizations, choose one explicitly. Houston validates usage before saving that organization's ID and the session cookie in Keychain. Refreshes stay pinned to that organization. This is useful when the CLI sign-in is expired or unavailable. **Use Claude Code sign-in** removes Houston's saved web connection and switches back to the CLI source.

**Direct connection (recommended if you use the desktop app).** Turn on **Direct connection**. Houston reads the access token from Claude Code’s own Keychain item (`Claude Code-credentials`, or the `~/.claude/.credentials.json` fallback) and calls Claude’s OAuth usage endpoint every five minutes. When you explicitly connect or check the connection, macOS may ask whether Houston can read that item; choose **Always Allow** to remember the installed app. Houston reuses valid tokens in memory for up to 30 minutes, then rechecks silently. Expired tokens are reread sooner and rejected tokens are discarded. Houston never writes Claude Code’s tokens to disk or rotates its refresh token, and the direct read calls Anthropic only for usage. It needs a Pro or Max sign-in; an expired sign-in shows a message asking you to send a message in `claude` to refresh it. Because the app is ad-hoc signed, a rebuilt binary may trigger the Keychain prompt again.

**Terminal bridge.** **Repair local bridge** configures the existing Houston executable as the status-line command. Unrelated settings are preserved and an existing status line is not overwritten; Houston backs up settings before adding the entry. Keep the app in its final location before connecting because Claude stores its absolute path. The bridge receives Claude Code’s stdin JSON and persists only `rate_limits` (five-hour, seven-day and, behind a gateway, spend-limit windows) to `~/Library/Application Support/Houston/claude-usage.json`. It prints the remaining percentages back into Claude Code’s status line. It needs a Pro/Max terminal session and produces data after the first response. Until then the card shows **Waiting for Claude Code**, and Tools shows whether the bridge is configured and when it last reported.

If you already have a custom status line, the setup action copies Houston’s command so your script can forward the same stdin to it while retaining its own output. Remove only Houston’s `statusLine` setting to disconnect, or restore the backed-up entry.

## Mac

The **Mac** tab samples this machine every two seconds while it is open and stops when it closes. It shows CPU and GPU utilization with a per-core strip (efficiency cores marked E, performance cores P), Activity Monitor style memory use with swap, the hottest CPU, GPU, SSD and battery temperatures with sensor averages, thermal pressure, fan speed with its range, system power draw and charger input, battery level with time remaining, startup-disk use and uptime.

Everything comes from public system interfaces: `host_processor_info`, `host_statistics64`, IOKit’s accelerator statistics and power-source list, and a read-only client for the System Management Controller (SMC) for temperatures, fans and power. SMC keys are enumerated once so temperature groups work across chip generations; readings outside 1–130 °C are discarded. No sudo, helper tool, or third-party code is involved. Missing sensors simply do not appear.

```sh
dist/Houston.app/Contents/MacOS/Houston --check-system
```

prints the same reading in the terminal.

## GitHub

The **GitHub** tab works as soon as the GitHub CLI is signed in (`gh auth login`): it shows the active account, your open pull requests across all repositories, pull requests waiting on your review, and unread notifications, each opening on github.com. Everything is read-only: no merges, comments, workflow dispatches, or marking notifications read. With GitHub notifications disabled, Houston loads GitHub on first opening the tab and refreshes every five minutes while it is visible, or on demand. Reopening within five minutes reuses the current result; hidden GitHub tabs launch no scheduled requests in that mode. Enabling GitHub notifications keeps monitoring active while the panel is closed. Requests already in flight may finish after closing the panel.

To follow one repository’s open pull requests and latest Actions runs, enter `owner/repository` or paste any GitHub link and press **Watch**; **Clear** stops watching. Recently pushed repositories appear as one-click chips, and a mistyped owner (for example `tamayaz/coachxo` instead of `Tamayaz-io/coachxo`) gets a **Did you mean** suggestion drawn from your own repositories. The selection persists.

```sh
dist/Houston.app/Contents/MacOS/Houston --check-github
```

prints the same overview in the terminal.

## Resource use

Houston uses native SwiftUI/AppKit with one linked dependency, SweetCookieKit 0.5.2, for browser-session import. Building requires Swift 6.2 or newer. Release builds remove debug and local symbols; the unstripped binary and dSYM remain in `.build` for debugging.

The compact island keeps SwiftUI idle between changes: springs and the one-shot moment choreography run only while something changes, and the two continuous indicators, the working ring and the waiting hand, are Core Animation transactions that the render server plays on its own. Measured on screen on September 13, 2026 with the opt-in `HOUSTON_MEASURE=1` test, the still, turning, and breathing indicators each cost 0.1–0.2% of one core in the hosting process, while the same mark spun by a SwiftUI repeat-forever animation cost about a full core, and a repeating symbol effect was earlier measured at about a fifth of a core; neither is used. The compositor still redraws the strip while an indicator moves, and that cost belongs to WindowServer, not Houston. Chimes are synthesized once on first use and cached; no audio engine runs otherwise. The compact panel runs no two-second polling timer. Enabled usage providers retain the five-minute refresh; Claude bridge updates arrive through filesystem notifications. GitHub starts its five overview requests, plus two requests for a watched repository, when needed by its visible tab, an explicit action, or enabled GitHub notifications. Notifications also add one bounded GraphQL request per refresh for PR checks and reviews. Agent events use directory notifications, with a one-minute recovery check. Named accounts refresh independently; history writes are batched off the main actor. Mac sensors sample every two seconds only while the Mac tab is visible; they always show real readings, independently of usage Preview. Closing a tab does not abort an already-running request.

Measure the running release with `bash scripts/measure.sh` (or pass a Houston PID). It reports disk size, resident memory in KiB, and 30 seconds of CPU and macOS memory-footprint samples. Ignore the first CPU row. Measure once with the panel closed and again with the Mac tab open; the results describe Houston itself, excluding the short-lived Codex/GitHub CLI children during refresh. Memory varies with macOS caching and compression, so fresh and long-running processes are not directly comparable.

Spot measurements on the development M4 Mac (16 GB), September 13, 2026, before the 0.4 agent/account/history features. Resource use for 0.4 has not been remeasured:

| State | Resident memory (RSS) | macOS footprint (`top MEM`) | CPU samples, excluding first row |
|---|---:|---:|---:|
| Fresh compact app, 30 seconds | ~80 MiB at sample start | 18–19 MiB | Mostly 0.0%, brief peaks to 2.3% |
| Live Mac tab, 10 seconds | ~102 MiB at sample end | ~36 MiB | 1.2–2.1% of one core |

These are spot measurements, not fixed budgets or proof of reduced RAM use. The prior long-running build was already near 0% CPU at rest. The concrete savings are a smaller release and fewer scheduled filesystem checks, CLI launches, and network requests. Framework/UI caches can remain resident after closing the panel.

## Verify

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift test --disable-sandbox --cache-path "$PWD/.build/cache"
```

Run AppKit tests with access to the macOS display; a headless or display-restricted sandbox cannot construct the real panel. The regression suite renders each section at 460 points in light and dark appearance and at 336 points in light appearance. Compact renders cover seven reading states across notched, external, and narrow layouts, including pixel checks that the camera area stays black. It also covers favorite persistence, display geometry for offset and negative-origin screens, editing and pointer reentry, immediate edge hover, 350 ms close behavior, closing from Tools, explicit pinning, keeping one hosting view alive, logo loading, provider parsing, missing/unlimited values, Claude bridge data minimization and spend-limit windows, direct Claude usage and token parsing, GitHub path/link validation, repository link normalization and owner suggestions, notification link mapping, CPU tick math, SMC value decoding, temperature grouping, and a live sampler sanity check.

Agent moments verification (September 13, 2026): all 132 tests passed with macOS display access, and the opt-in on-screen CPU measurement passed separately. Fixed renders cover the compact indicator while working, waiting, finished, and failed and the peek for every moment, with the same camera checks; the lifecycle tests cover the start, answer, finish, and failure moments, opt-in notification mirroring without a second peek or chime, sounds off, Preview, the open panel, stale events, session ranking, chime shape, and WAV playability.

Island redesign verification (September 13, 2026): all 122 tests passed with macOS display access. Fixed-date renders cover the compact strip, the alert peek, and the open island on notched and external geometry, with pixel checks that nothing crosses the camera in any presentation, plus the presentation order, peek lifecycle, and hover on a peek.

Version 0.4 verification: all 109 tests passed with macOS display access. Native snapshots cover the new screens in light, dark, and narrow layouts. The GitHub alert reader returned live checks/reviews, and Codex returned live usage with a verified history identity. Real agent hooks and notification permission remain explicit setup steps; no user hook configuration or additional account credentials were changed by the tests.

## Distribution

The build script produces a universal `arm64` + `x86_64` executable. Runtime checks are performed on the development Apple Silicon Mac; Intel sensor availability and other macOS releases still need hardware testing.

`dist/Houston.app` is ad-hoc signed by default for local development and not notarized for public distribution. For durable Keychain grants across updates, build with an existing stable signing identity: `HOUSTON_SIGNING_IDENTITY="Developer ID Application: …" bash scripts/build.sh`. Ad-hoc rebuilds change the app’s trusted identity and can require an explicit **Check connection** again; they never authorize background prompts. The Keychain accessibility class alone does not fix changed signing identity. Claude Code may also replace its own item when refreshing credentials. Launch at login and automatic updates are not included. Local notifications require macOS permission; agent tracking requires connecting the local hooks. The extra provider connections require their respective local sign-ins or keys; support does not imply a connected account.

See [third-party notices](../THIRD_PARTY_NOTICES.md) for logo licensing and integration sources.
