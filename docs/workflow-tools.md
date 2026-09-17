# Everyday workflow tools

Houston now includes a command palette, guided setup, connection health checks, persistent command history, and login/update preferences.

## Command palette

Press **Control–Option–Space** from any app, or choose **Command Palette…** from Houston’s menu (**⌘K** while Houston is focused). Search page names, saved projects, saved commands, and known agent sessions. All search words must match the action title or description. Use arrow keys and Return, or click a result. Selecting a **Run** action executes that saved command immediately and opens its project’s Commands view. Running commands are omitted from the palette until they finish. Agent results reveal the selected session in Houston, including sessions in History, with its available open and resume controls.

Disable the global shortcut in **Tools → Houston preferences**. It uses macOS hot-key registration and needs no Accessibility or Input Monitoring permission. If another app owns the shortcut, Houston reports the conflict and its menu action remains available.

## Guided setup and connection health

Guided setup opens on first launch and can be reopened from Tools or the menu. Progress is saved; **Later** dismisses automatic first-launch presentation without claiming that connections are verified. The three steps let you choose providers, connect agent hooks, and configure preferences. Tool detection finds known app bundle IDs or executables in Houston’s standard lookup locations. It is not proof of sign-in and can miss tools installed elsewhere.

Provider setup reuses the existing connection controls. Return to Guided Setup from Tools to continue. For agents, use **Start event verification**, then submit a prompt in your agent after reviewing/trusting its hooks. A provider is marked received only after Houston observes an actual session event timestamped after verification started. No synthetic event is presented as proof of an external connection.

Connection health shows enabled providers’ current states, original refresh errors, last reading times, and account-management links. Agent checks inspect all required hooks against the running Houston executable, detecting moved installations, missing handlers, and disabled hooks. **Connect / repair hooks** uses the existing preserving merge and backup behavior; it does not change trust or enable globally disabled hooks. GitHub and project cloud readings show their available errors and project-mapping guidance. **Refresh checks** checks every saved project regardless of the selected workspace page. Per-provider connection checks verify both the saved account and the project mapping. A saved configuration is distinct from a verified event or successful API reading.

## Command history

The latest 100 attempts across projects are retained in `~/Library/Application Support/Houston/command-history.json`, readable only by the current user. Each attempt has its own identity, command text, project folder, timestamps, result, exit code when recorded, and bounded combined output. Command cards show the latest matching attempt. Active historical reruns retain Stop and live-output controls even after the saved command was edited or deleted; these controls display the command actually running. Historical **Rerun** executes the displayed historical command, even if the saved command has since been edited; it is unavailable if the project folder changed or that command is already running.

Search Run History by name, command, or output. **Output** opens that attempt’s fixed log; its line filter narrows the displayed output and Copy copies the full log. **Clear…** removes the selected project’s finished history and logs while keeping active commands.

Running output is checkpointed at most once every two seconds. Quitting stops owned command groups. A run without a recorded final result restores as **Interrupted**, with no invented exit code or completion time, and never restarts automatically. A crash can lose output after the last checkpoint. Output beyond the existing per-run bound is truncated. Commands and their output can contain secrets: use Clear when appropriate. An unreadable history archive is preserved and further persistence pauses with a visible error.

## Launch at login and updates

Launch at login uses Apple’s [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice). Run the built `.app` from its permanent location before enabling it. If macOS requires approval, Houston links to Login Items settings and refreshes status when it becomes active again.

Automatic updates use [Sparkle](https://sparkle-project.org/documentation/). Release builds must embed an HTTPS appcast URL and the publisher’s Ed25519 public key. Source builds without those values explicitly show updates as unavailable. Automatic checking and installation start off; users can enable each in Tools, or manually choose Check for Updates. Sparkle verifies signed archives and handles download, replacement, and relaunch.

### Preparing a distributable release

1. Obtain a Developer ID Application signing identity and store notarization credentials using `xcrun notarytool store-credentials` under a named Keychain profile.
2. Resolve packages and run `.build/artifacts/sparkle/Sparkle/bin/generate_keys` once. Keep its private key in Keychain; only the public key belongs in build configuration. Never commit private keys.
3. Set `HOUSTON_SIGNING_IDENTITY`, `HOUSTON_NOTARY_PROFILE`, `HOUSTON_UPDATE_FEED_URL`, `HOUSTON_UPDATE_PUBLIC_KEY`, `HOUSTON_VERSION`, `HOUSTON_BUILD`, and `HOUSTON_DOWNLOAD_URL_PREFIX`. The feed is the HTTPS appcast URL; the download prefix is the HTTPS directory where archives will be hosted. Increase the numeric build number for every update.
4. Run `bash scripts/release.sh`. It builds the universal app, signs nested Sparkle helpers inside-out, notarizes and staples the app, then generates a signed archive and appcast in `dist/updates`. Sparkle’s key must be available in the login Keychain. Existing version/build archives are not overwritten.
5. Review the generated feed and upload the archives and feed to the configured HTTPS locations. The script does **not** publish anything. Keep earlier archives in `dist/updates` when generating later feeds.
6. Test an actual upgrade from an older signed/notarized build, including relaunch, login registration, and Keychain access. Local tests and an ad-hoc build do not establish end-to-end release delivery.

For a local build, `bash scripts/build.sh` still works without release credentials. It embeds Sparkle but leaves updates unavailable. Set only the feed/public-key variables to test feed configuration locally; never use an invented key or URL for a public release. Build embedding and signing follow Sparkle’s [setup](https://sparkle-project.org/documentation/) and [helper-signing guidance](https://sparkle-project.org/documentation/sandboxing/).
