import XCTest
import AppKit
@testable import Houston

final class DropShelfTests: XCTestCase {
    @MainActor func testFilePasteboardRoundTripDeduplicationAndClearPreserveOriginals() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("houston-shelf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Launch notes — مرحبا.md")
        let bytes = Data("Keep the original".utf8)
        try bytes.write(to: file)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([folder as NSURL, file as NSURL]))
        let shelf = DropShelf()
        XCTAssertTrue(shelf.hold(DropShelf.fileURLs(from: pasteboard)))
        XCTAssertEqual(shelf.items.map(\.path), [folder.path, file.path])
        XCTAssertTrue(shelf.hold([file, folder.appendingPathComponent("./" + file.lastPathComponent)]))
        XCTAssertEqual(shelf.items.count, 2, "Repeated drops are accepted without duplicating items")
        XCTAssertFalse(shelf.hold([URL(string: "https://example.com/file.zip")!, folder.appendingPathComponent("missing")]))
        XCTAssertNotNil(shelf.error)
        XCTAssertEqual(shelf.items.count, 2)
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(string: "https://example.com")! as NSURL])
        XCTAssertTrue(DropShelf.fileURLs(from: pasteboard).isEmpty, "Web links are not files")
        shelf.remove(file)
        shelf.clear()
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertNil(shelf.error)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor func testCancelledAndCopiedDragsStayHeldAndMoveOnlyReleasesReference() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("untouched".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let shelf = DropShelf()
        shelf.hold([file])
        for operation: NSDragOperation in [[], .copy] {
            shelf.isDragging = true
            shelf.finishDragging([file], operation: operation)
            XCTAssertFalse(shelf.isDragging)
            XCTAssertEqual(shelf.items, [file])
        }
        shelf.finishDragging([file], operation: .move)
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Only the destination may move the original")
        shelf.hold([file])
        try FileManager.default.removeItem(at: file)
        shelf.reveal(file)
        XCTAssertNotNil(shelf.error, "Stale references explain how to recover")
    }

    @MainActor func testShelfReopensAndDragKeepsPanelAlive() throws {
        _ = NSApplication.shared
        let app = AppDelegate()
        app.panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        app.store.enabled = []
        app.store.openDropShelf()
        app.layout()
        XCTAssertEqual(app.store.tab, .drop)
        XCTAssertEqual(app.panel.frame.height, app.store.expandedHeight)
        XCTAssertLessThanOrEqual(app.store.expandedHeight, 360 + app.store.topInset)
        let outside = NSPoint(x: -10000, y: -10000)
        app.store.dropShelf.isTargeted = true
        app.checkHover(at: outside, now: .now.addingTimeInterval(1))
        XCTAssertTrue(app.store.expanded)
        app.store.dropShelf.isTargeted = false
        app.store.dropShelf.isDragging = true
        app.checkHover(at: outside, now: .now.addingTimeInterval(2))
        XCTAssertTrue(app.store.expanded, "The source must survive until AppKit finishes dragging")
        app.store.dropShelf.isDragging = false
        let start = Date.now
        app.checkHover(at: outside, now: start)
        app.checkHover(at: outside, now: start.addingTimeInterval(0.5))
        XCTAssertFalse(app.store.expanded)
        app.store.dropShelf.hold([FileManager.default.temporaryDirectory])
        app.store.tab = .usage
        app.store.openIsland(defaultTab: .usage)
        XCTAssertEqual(app.store.tab, .drop, "The held-items indicator opens the shelf")
        app.store.dropShelf.clear()
        app.store.expanded = false
        app.store.openIsland(defaultTab: .usage)
        XCTAssertEqual(app.store.tab, .usage)
        app.store.stop()
    }

    @MainActor func testRejectedAndCancelledDropsReleaseTargetingAndAllowAutoClose() {
        _ = NSApplication.shared
        let app = AppDelegate()
        app.panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        app.store.enabled = []
        app.layout()
        defer { app.store.stop() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([FileManager.default.temporaryDirectory as NSURL]))
        let drag = ShelfDraggingInfo(pasteboard: pasteboard)
        let outside = NSPoint(x: -10000, y: -10000)

        for cancelled in [false, true] {
            drag.draggingSourceOperationMask = .copy
            XCTAssertEqual(app.panel.draggingEntered(drag), .copy)
            XCTAssertTrue(app.store.dropShelf.isTargeted)
            XCTAssertTrue(app.store.expanded)
            app.checkHover(at: outside)
            if cancelled {
                (app.panel as any NSDraggingDestination).draggingEnded?(drag)
            } else {
                // Command changes an accepted Finder drag into a move-only operation.
                drag.draggingSourceOperationMask = .move
                XCTAssertEqual(app.panel.draggingUpdated(drag), [])
            }
            XCTAssertFalse(app.store.dropShelf.isTargeted)
            XCTAssertTrue(app.store.dropShelf.items.isEmpty)
            let start = Date.now
            app.checkHover(at: outside, now: start)
            app.checkHover(at: outside, now: start.addingTimeInterval(0.5))
            XCTAssertFalse(app.store.expanded, "Rejected and cancelled drops must allow automatic closing")
        }
    }
}

@MainActor private final class ShelfDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
