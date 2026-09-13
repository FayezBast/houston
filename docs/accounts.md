# Houston accounts

In **Tools**, expand Claude, Cursor, or OpenRouter to add a named account such as **Work** or **Personal**. Browser accounts are verified through the chosen session; OpenRouter keys are verified with the key-usage endpoint before being saved. Saved accounts have independent readings, errors, and loading states. Their cards appear side by side. Select the account to display in Houston’s compact view, rename it, or remove it from Houston.

Selection affects Houston only. It does not sign another app in or out, rotate accounts, transfer allowances, or combine balances. Select **Existing connection** to keep using the original provider integration. Existing Keychain items and app credentials remain intact when named accounts are added or removed. Codex, Copilot, Gemini, and Windsurf continue using their existing local sign-ins; they do not currently offer named-account management in Houston.

## Storage and identity

Account metadata lives at `~/Library/Application Support/Houston/accounts.json`. It contains UUIDs, provider names, labels, and explicit selections. Each named account gets its own UUID-addressed item in the `dev.houston.credentials` macOS Keychain service. Tokens, cookies, API keys, and raw authentication files are never persisted in account metadata or usage history. An unreadable or invalid catalog is left unchanged rather than replacing it with an empty account list.

For named accounts, history uses the saved account UUID. Default connections use opaque SHA-256 scopes derived from the credential used for the request, with the Claude organization or Gemini quota project where relevant. These digests distinguish sign-ins without storing their credentials or email addresses in history. A credential rotation can start a separate history series; Houston does not infer that unrelated credentials belong to the same person.

Codex scopes use the workspace ID and token subject from the existing `CODEX_HOME/auth.json` metadata (default `~/.codex/auth.json`). Houston checks that its email matches the current account returned by Codex app-server and that identity is unchanged before and after reading usage. Missing or conflicting metadata leaves the reading visible but excludes it from account history. Keychain-only or externally managed Codex authentication may therefore have no history until a stable identity is available. Houston never changes Codex authentication to obtain history. The account response is checked through the documented [Codex app-server account API](https://learn.chatgpt.com/docs/app-server#auth-endpoints).

Claude terminal-bridge readings and Windsurf caches do not carry a trustworthy account identity, so they remain visible without being merged into account history. API spending remains separate from subscription percentages.

## One-time Keychain setup

Connect the account once. Houston keeps saved credentials in macOS Keychain and reuses an in-memory copy while it runs. Saving a replacement updates that copy; removing the account clears it. A normal refresh or the five-minute timer cannot request a password for Houston’s saved credentials. If access is unavailable, the last reading stays visible with a connection error.

Use **Tools → provider → Check connection**, or **Check connection** in a named account’s card menu, to authorize access explicitly. Choose **Always Allow** to remember the current app identity. That check rereads Keychain even when a credential is cached. Restarting Houston restores credentials silently when the installed identity remains authorized.

A development rebuild changes the default ad-hoc signing identity, so it may need this explicit check again. Use an existing stable signing identity for grants that survive app updates. Claude Code’s separate Keychain item may also lose prior grants when its owner replaces it. Houston follows the cache-first, noninteractive background policy described in [CodexBar’s Keychain guide](https://github.com/steipete/CodexBar/blob/main/docs/keychain-prompts.md).

## Connection changes

Each account refresh is tied to its UUID and request generation. Removing an account, turning a provider off, stopping monitoring, or entering preview invalidates pending updates. A failed refresh retains that account’s last good reading and displays its error. Switching accounts never assigns a pending reading to the newly selected account.

Expired saved connections can be added again after signing in; remove the expired entry when the replacement is working. Replacing credentials in place is not implemented. Browser sessions and OpenRouter keys remain subject to their provider’s expiration and access rules.
