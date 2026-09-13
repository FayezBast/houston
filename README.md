# Houston

A native macOS notch companion for AI coding usage, this Mac’s vitals, and GitHub activity. Swift + SwiftUI + AppKit, no third-party code dependencies. Requires macOS 14 or newer; the release build includes Apple Silicon and Intel binaries. The app is macOS-only; iPhone, iPad, Windows, and web are not supported.

## Run

```sh
bash scripts/build.sh
open dist/Houston.app
```

Houston starts compact and unpinned. Hover at the island or its edge to open it; leaving closes it after 350 ms. Pin explicitly with **Keep open → Pinned**. Text fields stay open while editing; press Escape to dismiss. The panel no longer rebuilds when data refreshes. Mouse events drive hover, with one cancellable 350 ms close timer in the common run-loop mode. There is no repeating pointer timer while idle.

While Houston is focused, ⌘O shows it, ⌘P toggles pinning, ⌘1–4 switches sections, ⌘R refreshes, and ⌘, opens Tools. Opening from the menu bar or keyboard keeps the panel available for keyboard navigation until you enter it with the pointer or dismiss it. Click the menu-bar icon to toggle the panel; right-click it to quit. Opening from the menu bar places Houston on the display under the pointer. On a display without a notch it sits below the menu bar with rounded top corners. Its width and height fit the display’s usable area, including scaled and portrait layouts. The old development `--pinned` argument no longer changes startup behavior.

## Appearance and accessibility

The expanded panel follows macOS light/dark appearance, with native material, segmented navigation, system accent color, and larger text and controls. The compact island stays black to blend into the notch. Provider colors adapt to each appearance. Reduce Transparency uses an opaque background, and Increase Contrast strengthens card outlines. Scrolling follows the system’s scrollbar preference. Core graphs wrap on machines with many cores.

Hover handling follows [AppKit’s local and global mouse event APIs](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html); the opaque fallback honors [Reduce Transparency](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency).

## Usage and Tools

**Tools** lets you enable or hide providers, inspect connection errors, and configure each source. Selections persist. The explicit **Preview** mode uses sample data. Live mode never fills missing data with zero usage.

| Tool | Source | Setup / limitations |
|---|---|---|
| Codex | Existing CLI sign-in; app-server rate limits | Install and sign in to Codex CLI. Live connection verified on the development Mac. |
| Claude Code | Direct read with Claude Code’s sign-in, or local status-line bridge | Direct: turn on in Tools and allow the Keychain prompt; works from the desktop app. Bridge: send a message in a Claude Code terminal. |
| Cursor | Usage dashboard shortcut | Automatic usage is not implemented. |
| GitHub Copilot | GitHub CLI and Copilot usage endpoint | Uses `gh auth login`; live connection verified. Some plans/credentials do not expose quotas. |
| Gemini | Existing Gemini CLI Google OAuth sign-in | Requires a quota-eligible account. No automatic token refresh; reopen Gemini CLI if the sign-in expires. Not live-tested here because Gemini is not installed. |
| Windsurf | Read-only SQLite plan cache | Open Windsurf to populate it. Always labeled cached; not live-tested here because Windsurf is not installed. |
| OpenRouter | API key usage endpoint | Save a key under Tools → OpenRouter. Stored in macOS Keychain. Shows key spending and an optional key budget, not account balance. Not live-tested without a key. |

Usage refreshes every five minutes or on demand, independently per enabled provider, without blocking hover or the UI. Claude's bridge uses directory-change notifications, including atomic file replacements, instead of a repeating poll. Monitoring stops when Claude is disabled or Preview is active. Preview starts no new live requests; returning to live refreshes immediately. Expired windows wait for fresh data; failed fetches preserve a labeled previous reading. The first returned quota window supplies the headline percentage.

### Claude: two ways to connect

Claude Code only runs status-line commands in a terminal session, so the Claude desktop app never feeds the bridge. Houston therefore offers two connections under **Tools → Claude**; newer readings win when both report.

**Direct connection (recommended if you use the desktop app).** Turn on **Direct connection**. Houston reads the access token from Claude Code’s own Keychain item (`Claude Code-credentials`, or the `~/.claude/.credentials.json` fallback) and calls Claude’s OAuth usage endpoint every five minutes. macOS asks once whether Houston may read that item; choose **Allow** or **Always Allow**. The token is used for that one request, is never written anywhere by Houston, and the direct read never calls Anthropic for anything but usage. It needs a Pro or Max sign-in; an expired sign-in shows a message asking you to send a message in `claude` to refresh it. Because the app is ad-hoc signed, a rebuilt binary may trigger the Keychain prompt again.

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

The **GitHub** tab works as soon as the GitHub CLI is signed in (`gh auth login`): it shows the active account, your open pull requests across all repositories, pull requests waiting on your review, and unread notifications, each opening on github.com. Everything is read-only: no merges, comments, workflow dispatches, or marking notifications read. Houston loads GitHub on first opening the tab and refreshes every five minutes while it is visible, or on demand. Reopening within five minutes reuses the current result; hidden GitHub tabs launch no scheduled requests. Requests already in flight may finish after closing the panel.

To follow one repository’s open pull requests and latest Actions runs, enter `owner/repository` or paste any GitHub link and press **Watch**; **Clear** stops watching. Recently pushed repositories appear as one-click chips, and a mistyped owner (for example `tamayaz/coachxo` instead of `Tamayaz-io/coachxo`) gets a **Did you mean** suggestion drawn from your own repositories. The selection persists.

```sh
dist/Houston.app/Contents/MacOS/Houston --check-github
```

prints the same overview in the terminal.

## Resource use

Houston uses native SwiftUI/AppKit and has no third-party runtime dependencies. The universal release is about 1.7 MiB on disk after removing debug and local symbols (previously 4.1 MiB); the unstripped binary and dSYM remain in `.build` for debugging.

The compact panel runs no two-second polling timer. Enabled usage providers retain the five-minute refresh; Claude updates arrive through filesystem notifications. GitHub starts its five overview requests, plus two requests for a watched repository, only when needed by its visible tab or an explicit action. Mac sensors sample every two seconds only while the Mac tab is visible; they always show real readings, independently of usage Preview. Closing a tab does not abort an already-running request.

Measure the running release with `bash scripts/measure.sh` (or pass a Houston PID). It reports disk size, resident memory in KiB, and 30 seconds of CPU and macOS memory-footprint samples. Ignore the first CPU row. Measure once with the panel closed and again with the Mac tab open; the results describe Houston itself, excluding the short-lived Codex/GitHub CLI children during refresh. Memory varies with macOS caching and compression, so fresh and long-running processes are not directly comparable.

Spot measurements on the development M4 Mac (16 GB), September 13, 2026, using the optimized release:

| State | Resident memory (RSS) | macOS footprint (`top MEM`) | CPU samples, excluding first row |
|---|---:|---:|---:|
| Fresh compact app, 30 seconds | ~80 MiB at sample start | 18–19 MiB | Mostly 0.0%, brief peaks to 2.3% |
| Live Mac tab, 10 seconds | ~102 MiB at sample end | ~36 MiB | 1.2–2.1% of one core |

These are spot measurements, not fixed budgets or proof of reduced RAM use. The prior long-running build was already near 0% CPU at rest. The concrete savings are a smaller release and fewer scheduled filesystem checks, CLI launches, and network requests. Framework/UI caches can remain resident after closing the panel.

## Verify

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift test --disable-sandbox --cache-path "$PWD/.build/cache"
```

Run AppKit tests with access to the macOS display; a headless or display-restricted sandbox cannot construct the real panel. The regression suite renders each section at 460 points in light and dark appearance and at 336 points in light appearance. It also covers display geometry for notched, external, small, and negative-origin screens, editing and pointer reentry, immediate edge hover, 350 ms close behavior, closing from Tools, explicit pinning, keeping one hosting view alive, logo loading, provider parsing, missing/unlimited values, Claude bridge data minimization and spend-limit windows, direct Claude usage and token parsing, GitHub path/link validation, repository link normalization and owner suggestions, notification link mapping, CPU tick math, SMC value decoding, temperature grouping, and a live sampler sanity check.

## Distribution

The build script produces a universal `arm64` + `x86_64` executable. Runtime checks are performed on the development Apple Silicon Mac; Intel sensor availability and other macOS releases still need hardware testing.

`dist/Houston.app` is ad-hoc signed for local development and not notarized for public distribution. Launch at login, agent-completion tracking, and push notifications are not included. The extra provider connections require their respective local sign-ins or keys; support does not imply a connected account.

See [third-party notices](THIRD_PARTY_NOTICES.md) for logo licensing and integration sources.
