import XCTest
import SwiftUI
import HoustonCore
@testable import Houston

final class ProjectWorkspaceTests: XCTestCase {
    @MainActor private func offlineCloud() -> CloudStore {
        CloudStore(api: CloudAPI { _ in XCTFail("Offline project tests must not connect"); return Data() }, readSecret: { _, _ in nil })
    }

    @MainActor func testProjectValidationPreservesFoldersAndProtectsRunningCommands() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("houston-project-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = CommandRunner()
        let store = ProjectStore(file: directory.appendingPathComponent("projects.json"), runner: runner, cloud: offlineCloud(),
                                 gitReader: { _ in GitProjectStatus(branch: "main", changedFiles: 0) }, portReader: { [] })
        defer { store.stop() }
        let command = ProjectCommand(name: "Server", command: "/bin/sleep 20")
        var project = HoustonProject(name: "  Houston  ", path: directory.path, commands: [command])
        XCTAssertTrue(store.save(project))
        XCTAssertEqual(store.selected?.name, "Houston")
        XCTAssertEqual(try ProjectLibrary.load(from: directory.appendingPathComponent("projects.json")).count, 1)
        var duplicate = project; duplicate.id = UUID(); duplicate.commands = []
        XCTAssertFalse(store.save(duplicate))
        runner.run(project: project, command: command)
        XCTAssertTrue(runner.runs.first?.isRunning == true)
        project.commands = []
        XCTAssertFalse(store.save(project), "A running command must retain its Stop control")
        store.remove(project)
        XCTAssertEqual(store.projects.count, 1)
        runner.shutdown()
        for _ in 0..<30 where runner.runs.first?.isRunning == true { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.save(project))
        store.remove(project)
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "Removing a project never removes its folder")
    }

    @MainActor func testCorruptLibraryCannotBeReplacedAndFolderMatchingIsExact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("projects.json"), original = Data("broken-library".utf8)
        try original.write(to: file)
        let store = ProjectStore(file: file, cloud: offlineCloud())
        XCTAssertFalse(store.save(HoustonProject(name: "Project", path: directory.path)))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(ProjectStore.belongs("/tmp/work/app/server", to: "/tmp/work/app"))
        XCTAssertFalse(ProjectStore.belongs("/tmp/work/app-copy", to: "/tmp/work/app"))
        XCTAssertFalse(ProjectStore.belongs(nil, to: "/tmp/work/app"))
        XCTAssertNil(ProjectStore.webURL("javascript:alert(1)"))
        XCTAssertNil(ProjectStore.webURL("https://user:pass@example.com"))
        XCTAssertEqual(ProjectStore.webURL("http://localhost:3000")?.port, 3000)
    }

    func testProjectAlertsCarryProjectIdentityAndFailureMeaning() {
        let id = UUID()
        for (title, symbol) in [("Command failed", "xmark.circle.fill"), ("Website deployment error", "xmark.circle.fill"),
                                ("Website needs attention", "exclamationmark.bubble.fill"), ("Command passed", "checkmark.circle.fill")] {
            let peek = IslandPeek(HoustonAlert(title: title, body: "Website", url: nil, sessionID: nil, projectID: id))
            XCTAssertEqual(peek.projectID, id)
            XCTAssertEqual(peek.tab, .projects)
            XCTAssertEqual(peek.symbol, symbol)
        }
    }

    @MainActor func testProjectSectionsRenderWithNativeControlsAndFixtureReadings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("houston-workspace-render-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = HoustonProject(name: "Houston website", path: directory.path, editorBundleID: "com.microsoft.VSCode", webURL: "http://localhost:3000",
                                     commands: [ProjectCommand(name: "Development server", command: "npm run dev"), ProjectCommand(name: "Tests", command: "npm test")],
                                     vercelProjectID: "prj_website", sentryOrganization: "houston", sentryProject: "website", sentryEnvironment: "production")
        try ProjectLibrary.save([project], to: directory.appendingPathComponent("projects.json"))
        let cloud = CloudStore(api: CloudAPI { request in
            let text: String
            switch request.url?.host {
            case "api.vercel.com": text = #"{"deployments":[{"uid":"dpl_1","name":"houston-website","state":"READY","url":"houston-preview.vercel.app","meta":{"githubCommitRef":"feature/project-hub"},"created":1790000000000},{"uid":"dpl_2","name":"houston-website","state":"ERROR","url":null,"meta":{"githubCommitRef":"fix/auth-session"}}]}"#
            case "sentry.io": text = #"[{"id":"42","shortId":"WEB-42","title":"TypeError: Failed to fetch account details","status":"unresolved","priority":"high","count":"127","userCount":18,"permalink":"https://houston.sentry.io/issues/42/"}]"#
            case "api.linear.app": text = #"{"data":{"viewer":{"assignedIssues":{"nodes":[{"id":"issue-1","identifier":"HOU-128","title":"Refine project switching and keyboard navigation","url":"https://linear.app/houston/issue/HOU-128","priorityLabel":"High","state":{"name":"In Progress","type":"started"}}]}}}}"#
            default: XCTFail("Unexpected fixture request"); text = "{}"
            }
            return Data(text.utf8)
        }, readSecret: { _, _ in Data("fixture-only".utf8) }, saveSecret: { _, _ in }, removeSecret: { _ in })
        let projects = ProjectStore(file: directory.appendingPathComponent("projects.json"), cloud: cloud,
            gitReader: { _ in GitProjectStatus(branch: "feature/project-hub", changedFiles: 3, remote: "https://github.com/FayezBast/houston.git") },
            portReader: { [LocalPort(pid: 4200, process: "node", port: 3000, address: "127.0.0.1", projectPath: directory.path, cpuPercent: 1.4, memoryMB: 86)] },
            containerReader: { [DockerContainer(id: "a1b2c3", name: "houston-postgres", image: "postgres:17", state: "running", status: "Up 2 hours (healthy)", ports: "127.0.0.1:5432 → 5432/tcp", cpuPercent: 0.2, memory: "64 MiB / 4 GiB")] })
        let suite = "houston-project-render-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); projects.stop() }
        let store = Store(bridgeFile: directory.appendingPathComponent("usage.json"), alerts: AlertCenter(defaults: defaults), projects: projects) { _, _, _, _ in
            XCTFail("Rendering must never read live provider usage"); return UsageSnapshot(windows: [])
        }
        // The selected project's request is older than this global first page.
        let reviews = try JSONSerialization.data(withJSONObject: ["total_count": 6, "items": (1...5).map { number -> [String: Any] in
            ["id": number, "number": number, "title": "Review another project",
             "html_url": "https://github.com/fixture/other/pull/\(number)",
             "repository_url": "https://api.github.com/repos/fixture/other"]
        }])
        let empty = Data("[]".utf8)
        store.overview = try GitHubReader.parseOverview(login: "fixture", authored: empty, reviews: reviews, notifications: empty, repositories: empty)
        store.enabled = []; store.expanded = true; store.tab = .projects
        projects.refresh()
        for _ in 0..<100 where projects.git[project.id] == nil || projects.ports.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await cloud.refresh(project: project)
        XCTAssertEqual(projects.projectPorts.count, 1)
        XCTAssertEqual(cloud.snapshot(for: project).deployments.count, 2)
        XCTAssertEqual(cloud.snapshot(for: project).errors.count, 1)
        for width in [CGFloat(336), 460] {
            for section in ProjectSection.allCases {
                projects.section = section
                if section == .containers {
                    for _ in 0..<100 where projects.containers.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
                }
                for scheme in [ColorScheme.dark, .light] {
                    try await render(ProjectsView(store: store), name: "projects-\(section.rawValue.lowercased())-\(Int(width))-\(scheme == .dark ? "dark" : "light")", width: width, scheme: scheme)
                }
            }
            projects.section = .overview; store.expandedWidth = width; store.expandedHeight = 610
            try await render(IslandView(store: store), name: "projects-island-\(Int(width))", width: width, scheme: .dark, padding: 0)
        }
        projects.section = .work
        store.overviewError = "GitHub is unavailable. Try refreshing when the connection returns."
        try await render(ProjectsView(store: store), name: "projects-work-refresh-error", width: 336, scheme: .dark)
        store.overviewError = nil
        projects.section = .overview
        try await render(ProjectWorkspaceView(store: store).frame(height: 700), name: "projects-workspace", width: 980, scheme: .dark, padding: 0)
        try await render(ProjectEditor(project: project, projects: projects, done: {}), name: "projects-editor", width: 530, scheme: .dark, padding: 0)
    }

    @MainActor private func render<V: View>(_ view: V, name: String, width: CGFloat, scheme: ColorScheme, padding: CGFloat = 20) async throws {
        let hosting = NSHostingView(rootView: view.padding(padding).frame(width: width).environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color(white: 0.08) : Color(white: 0.97)))
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = NSSize(width: width, height: max(60, hosting.fittingSize.height))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.setContentSize(size); window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        XCTAssertGreaterThan(representation.pixelsHigh, 50)
        XCTAssertEqual(representation.pixelsWide, Int(width * window.backingScaleFactor))
        if let path = ProcessInfo.processInfo.environment["HOUSTON_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}
