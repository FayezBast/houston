# Projects and developer tools

Projects brings a folder’s branch, local servers, saved commands, agent sessions, deployments, errors, and assigned work into one place. It is Houston’s sixth tab. While Houston is focused, press **⌘6** for Projects or **⌘0** to open the larger Projects window. The expand button in the Projects header opens the same window.

## Add a project

1. Choose **Add a project…** or the **+** button and select an existing folder.
2. Give it a name. Choose Finder or an installed editor under **Open with**. Add an optional website or local preview address beginning with `http://` or `https://`.
3. Save. Use the project picker to switch folders and the section picker or window sidebar to choose a tool.

The Overview shows the Git branch and changed-file count when the folder belongs to a repository. **Folder** or **Editor** opens the saved folder; **Terminal** opens it with Terminal.app; **Website** opens the saved address. Linked agent sessions are matched to the project folder and its descendants. The folder stays in its original location.

Use the project’s **… → Project settings…** menu to edit its folder, commands, and cloud mappings. Removing a project removes its Houston entry, leaving its files on disk. Stop its running Houston commands before removing it. An unreadable project library is preserved and must be repaired before changes can be saved.

## Servers and listening ports

**Servers** lists TCP listeners whose process working directory is the selected project folder or a descendant. Turn on **Show all listening ports on this Mac** to see listeners launched elsewhere or without an available working directory. Filter by port number or process name.

Cards show the port, process, PID, and available CPU and memory readings. **Open address** opens an HTTP address, and **Copy address** copies it. Wildcard listeners use localhost; explicitly bound IPv4 and IPv6 listeners use that address. A listening port does not establish that the service speaks HTTP or is healthy; use the service’s own client for other protocols. This view does not list UDP listeners or processes hidden by macOS access restrictions.

**Stop server** asks the selected process to quit after confirmation. Houston rechecks its listener, ownership, and process-start identity before sending `SIGTERM`, so a reused PID does not target an unrelated process. Only a verified process owned by your account can be stopped. Stopping a process closes all ports it owns; a process that ignores a graceful termination request may remain running.

## Saved commands

Open **Project settings → Commands** and add a name and command, such as `npm run dev`, `swift test`, `pytest`, or `cargo build`. Saving or editing a command does not execute it. Press that command’s **Run** button to start it in the selected project’s folder.

Houston invokes `/bin/zsh -lc` with the app’s environment and zsh’s login startup files. This is a noninteractive shell, with no terminal input; commands that require a password or interactive prompt belong in Terminal. Environment setup placed only in an interactive shell configuration may need to be moved to login configuration or included in the saved command.

The Commands section shows running, passed, failed, or stopped state, elapsed time, and an exit code where available. **View output** shows combined stdout and stderr as it arrives. Output is retained in memory, truncated when it grows too large, and lost when Houston quits. Running a command again replaces its previous result; recent finished results are bounded while active commands remain available.

Closing the notch or Projects window keeps commands running. **Stop** terminates the command’s owned process group, including children that remain in that group. Quitting Houston stops its owned command groups; it does not stop unrelated servers discovered in the Servers view. A command that deliberately detaches into another process group is outside that ownership boundary.

## Docker containers

**Containers** uses the installed Docker CLI and its current context. It shows all containers in that context, including stopped containers; the selected Houston project does not filter this list. A Docker context can point to a local or remote engine.

Cards show the container’s name, image, state, published ports, and available CPU and memory statistics. **Logs** reads the latest 300 log lines with timestamps. **Start**, **Restart**, and **Stop** operate on the selected container; Stop asks for confirmation. The view does not create containers, edit Compose files, or manage images and volumes.

Install the Docker CLI and start or connect its engine before using this section. Houston reports missing tools, unavailable engines, and permission failures. It does not install Docker, change the active context, or require the optional Mac `/var/run/docker.sock` symlink. See the official [Docker context documentation](https://docs.docker.com/engine/manage-resources/contexts/).

## Cloud accounts and project mappings

Open **Connections**, paste a personal token, and choose **Save & verify**. Houston verifies the token before saving it in this Mac’s Keychain. **Check** verifies a saved connection; **Remove** deletes that token and clears its cached cloud readings. Each service currently has one saved token shared by the Houston projects, rather than separate work/personal cloud accounts or an OAuth sign-in flow.

Then open **Project settings → Cloud projects** to map the selected folder:

| Service | Connection and mapping | What Houston shows |
| --- | --- | --- |
| Vercel | An access token with access to the target account/team; enter the project ID or name and an optional team ID. | Latest 10 deployments, state, branch/target, available preview/details links, and the latest 200 build-log events. |
| Sentry | A personal auth token with `event:read`; enter organization and project slugs, plus an optional environment. | Up to 20 unresolved issues from the last 14 days, priority, event/user counts where available, and issue links. |
| Linear | A personal API key with read access to the relevant teams; optionally enter a Linear project ID. | Up to 30 open issues assigned to the token’s user. Leaving the project ID empty shows assigned work across Linear projects. |

The **Work** section also shows up to five recent GitHub review requests using Houston’s existing GitHub connection. When a valid GitHub origin remote is known, those recent requests are filtered to that repository; otherwise the view shows them across your repositories. Older requests may be missing from this summary. **View all review requests on GitHub** opens the full review queue with the same repository filter when available.

Cloud connections are read-only: Houston does not deploy, roll back, resolve Sentry issues, or modify Linear work. A successful token check does not prove that a particular project mapping is accessible; refresh the mapped project to verify that separately. API permission, network, and rate-limit errors are shown alongside any labeled last successful reading. Missing values are left missing.

Create tokens using the official [Vercel token settings](https://vercel.com/account/settings/tokens), [Sentry auth-token settings](https://sentry.io/settings/account/api/auth-tokens/), and [Linear security settings](https://linear.app/settings/account/security). API details: [Vercel](https://vercel.com/docs/rest-api), [Sentry issues](https://docs.sentry.io/api/events/list-an-organizations-issues/), and [Linear](https://linear.app/developers/graphql).

## Refreshes and notifications

Local project readings poll about every 10 seconds while Projects is visible in the notch or its workspace window is open and not minimized. The selected section determines which local readers run: ports in Overview/Servers, Docker in Containers, and Git for the selected project. Refresh buttons also request an immediate check.

Selected-project cloud checks run at most about once per minute during normal polling. Enable **Tools → Notifications → Commands and project activity** to keep checking the selected project’s cloud connections about every 60 seconds in the background. Other saved projects are not continuously polled. The first successful check establishes a quiet baseline; later deployment completions/changes and important newly observed Sentry issues can notify. Polling can miss intermediate states.

Command results can appear in the notch. The project notification setting enables macOS notifications for command results and eligible cloud changes, subject to macOS permission. Clicking a project alert returns to the relevant project or linked service. Preview mode suspends project monitoring and shows no simulated project readings.

## Storage and verification limits

Project names, paths, editor choices, website addresses, command text, and cloud mappings are stored in `~/Library/Application Support/Houston/projects.json`, with access restricted to the current user. Tokens are stored separately in Keychain. Cloud snapshots, fetched logs, and command output are held in memory rather than written into the project library. Agent metadata uses its separate local store; see [Agent sessions](agent-sessions.md).

Automated tests use representative fixtures and isolated local processes. Vercel, Sentry, and Linear account access, Docker behavior against your chosen engine, and Cursor lifecycle delivery still need verification in your environment. No successful live external-account verification is implied by fixture-backed tests.
