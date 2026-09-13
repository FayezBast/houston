import XCTest
import SwiftUI
import HoustonCore
@testable import Houston

/// Renders the expanded island offscreen. Set HOUSTON_RENDER_DIR to write PNGs for visual review; otherwise it only checks that rendering succeeds.
final class RenderTests: XCTestCase {
    @MainActor func testExpandedTabsRender() async throws {
        let store = Store()
        store.expanded = true
        store.pinned = true
        store.expandedHeight = 560
        let sampler = SystemSampler()
        _ = await sampler.sample()
        try await Task.sleep(for: .milliseconds(400))
        store.system = await sampler.sample()
        store.overview = try GitHubReader.parseOverview(login: "fayez-tamayaz",
            authored: Data(#"{"items":[{"id":1,"number":401,"title":"fix(auth): preserve drafts and serialize refresh across tabs","draft":false,"html_url":"https://github.com/Tamayaz-io/coachxo/pull/401","repository_url":"https://api.github.com/repos/Tamayaz-io/coachxo","updated_at":"2026-09-12T01:00:00Z"},{"id":2,"number":299,"title":"feat(week21): harden Phase 2 release readiness","draft":true,"html_url":"https://github.com/Tamayaz-io/coachxo/pull/299","repository_url":"https://api.github.com/repos/Tamayaz-io/coachxo","updated_at":"2026-08-27T01:00:00Z"}]}"#.utf8),
            reviews: Data("[]".utf8),
            notifications: Data(#"[{"id":"1","reason":"review_requested","updated_at":"2026-09-12T20:00:00Z","subject":{"title":"Please review the deploy pipeline","type":"PullRequest","url":"https://api.github.com/repos/Tamayaz-io/prime/pulls/12"},"repository":{"full_name":"Tamayaz-io/prime","html_url":"https://github.com/Tamayaz-io/prime"}}]"#.utf8),
            repositories: Data(#"[{"full_name":"Tamayaz-io/coachxo"},{"full_name":"Tamayaz-io/prime"},{"full_name":"Tamayaz-io/cedars-altametrics"}]"#.utf8))
        store.repository = "tamayaz/coachxo"
        store.activityError = "GitHub could not find this resource with the current sign-in. Check the repository name and private-repository access."
        store.repositorySuggestion = "Tamayaz-io/coachxo"
        store.claudeDirect = true
        store.errors[.claude] = "No Claude Code sign-in found. Run claude in a terminal and sign in, then retry."
        store.snapshots[.codex] = UsageSnapshot(windows: [UsageWindow(name: "5-hour", used: 24, resetsAt: .now.addingTimeInterval(8040)), UsageWindow(name: "Weekly", used: 36, resetsAt: .now.addingTimeInterval(280800))])

        let directory = ProcessInfo.processInfo.environment["HOUSTON_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        for (tab, configuring) in [(PanelTab.system, nil), (.activity, nil), (.tools, Provider.claude), (.usage, nil)] {
            store.tab = tab
            // ImageRenderer leaves ScrollView contents blank; inspect pages in both appearances and a narrow layout.
            for (name, scheme, width) in [
                ("light", ColorScheme.light, CGFloat(460)),
                ("dark", .dark, 460),
                ("narrow", .light, 336)
            ] {
                let renderer = ImageRenderer(content: IslandView(store: store, configuring: configuring).page.frame(width: width)
                    .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.97))
                    .environment(\.colorScheme, scheme))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage, "\(tab.rawValue) must render")
                XCTAssertEqual(image.width, Int(width * 2), tab.rawValue)
                XCTAssertGreaterThan(image.height, 300, "\(tab.rawValue) must have content")
                if let directory {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let representation = NSBitmapImageRep(cgImage: image)
                    let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
                    try data.write(to: directory.appendingPathComponent("\(tab.rawValue.lowercased())-\(name).png"))
                }
            }
        }
    }
}
