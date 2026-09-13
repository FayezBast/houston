# AI usage integration research

Checked 2026-09-13 against provider documentation and the current source of [CodexBar](https://github.com/steipete/CodexBar), a working open-source usage dashboard. There is no shared subscription-usage API: dashboards combine CLI services, OAuth APIs, web sessions, and explicit API keys. A reader can be implemented and tested without having an account, but a live verification requires that provider's sign-in and allowance.

| Provider | How CodexBar gets usage | Houston path / interpretation |
| --- | --- | --- |
| Codex | Native OAuth usage endpoint or the Codex app-server RPC. [Source](https://github.com/steipete/CodexBar/blob/main/docs/codex.md) | Use the already-working `account/rateLimits/read` RPC, preserving the provider's actual window lengths and reset timestamps. |
| Claude | Claude Code OAuth, Claude web-session usage, or CLI output. [Source](https://github.com/steipete/CodexBar/blob/main/docs/claude.md) | Direct CLI sign-in and normal web sign-in both read usage without a terminal response. Web login saves only the session cookie and an explicitly selected organization UUID. Keep the status-line bridge available and discard superseded requests. |
| Copilot | GitHub OAuth/device login and `GET /copilot_internal/user`. [Source](https://github.com/steipete/CodexBar/blob/main/docs/copilot.md) | Houston reuses the existing `gh` login. Unlimited and zero-entitlement placeholders are not percentage meters. |
| Cursor | Local Cursor.app token or an authenticated Cursor web session; `GET /api/usage-summary`, with `/api/auth/me` and `/api/usage?user=ID` for legacy request quotas. [Source](https://github.com/steipete/CodexBar/blob/main/docs/cursor.md) | Implemented a real reader. Explicit web login supplies only Cursor session cookies; the locally signed-in Cursor app is another available source. Free/legacy request quotas take precedence when `maxRequestUsage` is returned. |
| Gemini | Gemini CLI OAuth credentials, `loadCodeAssist` project discovery, then `retrieveUserQuota`. [Source](https://github.com/steipete/CodexBar/blob/main/docs/gemini.md) | Include the project, interpret `remainingFraction` as a fraction, and keep the most restrictive bucket for each model. Google's [request type](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/types.ts) requires `project`. See the consumer-account limitation below. |
| Windsurf | An authenticated web session calls `GetPlanStatus`; a local `state.vscdb` plan cache is a fallback. [Source](https://github.com/steipete/CodexBar/blob/main/docs/windsurf.md) | The cache can only update while Windsurf runs. It must carry a cache-age warning and must not pretend to be a live API result. The user does not have a Windsurf account, so no live account verification is possible. |
| OpenRouter | An explicit API key reads the key cap and optionally the account credits balance. [Source](https://github.com/steipete/CodexBar/blob/main/docs/openrouter.md) | A key budget is separate from account balance. `limit: null` means uncapped; zero is an actual zero cap. Prefer server `limit_remaining` to cumulative usage. [Provider API documentation](https://openrouter.ai/docs/api_reference/limits) |

## Cursor implementation details

The [Cursor probe source](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift) defines `individualUsage.plan.totalPercentUsed`, `autoPercentUsed`, and `apiPercentUsed` in percentage units, including fractional values such as `0.36` meaning 0.36%. Monetary counters are cents, and `billingCycleEnd` provides the monthly reset. Enterprise accounts may expose `individualUsage.overall` or `teamUsage.pooled`. Legacy request plans report `gpt-4.maxRequestUsage` and `numRequestsTotal`/`numRequests` separately.

Houston uses these response shapes without guessing allowance sizes from plan names. Missing data fails visibly; an explicit unlimited response can succeed without a fake bar. The reader uses an ephemeral URLSession with redirects disabled and no ambient cookie jar. Errors omit server bodies and credentials. A supplied/saved account is not silently replaced when its network authentication fails.

For local sign-in, [CodexBar's Cursor app-auth source](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Cursor/CursorAppAuth.swift) reads only `cursorAuth/accessToken` from Cursor's state database, extracts its JWT subject and expiry, and supplies the existing token in Cursor's `WorkosCursorSessionToken` format. Houston reads that same single key read-only, rejects expired/invalid tokens, and leaves renewal to Cursor. Normal in-app login or a browser-session import can instead obtain the actual session cookie.

## Browser-session import

Houston now uses the same [SweetCookieKit](https://github.com/steipete/SweetCookieKit) library as [CodexBar](https://github.com/steipete/CodexBar/blob/main/Package.swift), pinned to 0.5.2. Opening Connect checks browser profiles without Keychain interaction. Distinct sessions remain separate, identical session headers are deduplicated, and multiple candidates require a profile choice. An explicit profile import may request the browser's Safe Storage key through macOS; Safari access can require Full Disk Access. The normal sign-in window remains available if importing is unavailable.

Each query targets exactly `claude.ai` or `cursor.com`. The existing provider adapters filter cookie names, paths, expiry, and conflicting values, validate usage, and save only the session (plus the chosen Claude organization UUID) in Houston's Keychain. There is no browser scanning on the refresh timer, no browser mutation, and no automatic fallback to another account after a saved session fails. Connection-window cancellation invalidates pending work before credentials can be saved.

Verification covers request URLs/authentication, free-plan fallback, current percentage units, enterprise caps, cents, resets, nonfinite and missing quota, expired tokens, UTF-8/UTF-16 database values, cookie filtering, and HTTP failures. These fixture tests verify the integration behavior; a live account check remains necessary after sign-in.

## Gemini consumer-account limitation

Google states that consumer Gemini CLI/Code Assist access for individual, Google AI Pro, and Google AI Ultra accounts ended on **June 18, 2026**, including Login with Google. Standard and Enterprise subscriptions remain supported. Google directs affected consumers to Antigravity. This is a provider product change, so reconnecting the same consumer account cannot repair it. Houston must surface that condition when reported instead of promising that repeated sign-in will restore quota. [Google's deprecation notice, updated September 2, 2026](https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals)

## Verification on this Mac

All 64 tests pass with macOS display access, including mocked provider requests, Cursor Free response handling, Gemini project/token refresh, Claude web organization selection, and request cancellation after connection changes. The universal build includes both Apple Silicon and Intel code; runtime verification was on Apple Silicon.

Codex and Copilot returned live allowances and Houston's manual refresh displayed those readings. On September 13, 2026, Houston was granted Full Disk Access for Safari on the development Mac. Importing the existing Claude and Cursor browser sessions then succeeded: Houston displayed live Claude five-hour and weekly usage and Cursor included-plan usage. Both verified account credentials were saved in Houston's Keychain items.

OpenRouter requires a saved key before live quota results can be verified. The existing Claude Code credential could not supply a usable OAuth token; the verified Claude connection uses the browser session instead. Windsurf has no local account/cache here. The user's Gemini Free account is excluded by Google's product change, rather than a fixable quota parser failure.
