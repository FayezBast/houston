import AppKit
import SwiftUI

/// A session-only shelf of references. Holding or clearing items never changes the files on disk.
@MainActor final class DropShelf: ObservableObject {
    @Published private(set) var items: [URL] = []
    @Published var isTargeted = false
    @Published var isDragging = false
    @Published var error: String?

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @discardableResult func hold(_ urls: [URL]) -> Bool {
        let valid = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        var paths = Set(items.map(\.path))
        for url in valid {
            let normalized = url.standardizedFileURL
            if paths.insert(normalized.path).inserted { items.append(normalized) }
        }
        error = valid.count < urls.count ? "Some items are unavailable. Drop existing files or folders from Finder." : nil
        return !valid.isEmpty
    }

    func remove(_ url: URL) { items.removeAll { $0 == url }; error = nil }
    func clear() { items.removeAll(); error = nil }

    func reveal(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            error = "“\(url.lastPathComponent)” moved or is unavailable. Remove it and drop it in again."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func finishDragging(_ urls: [URL], operation: NSDragOperation) {
        // Finder / the destination owns the transfer. Never delete originals in a source callback.
        // Keep references after copies and cancellation, and release them after an accepted move.
        if operation.contains(.move) { items.removeAll { urls.contains($0) } }
        isDragging = false
    }
}

struct DropShelfView: View {
    @ObservedObject var shelf: DropShelf
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drop shelf").font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
                    Text(shelf.items.isEmpty ? "A little space between here and there." : "Drag an item out when you’re ready.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if !shelf.items.isEmpty {
                    Button("Clear") { shelf.clear() }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                        .help("Clear the shelf. Your files stay where they are.")
                }
            }

            if shelf.items.isEmpty || shelf.isTargeted {
                VStack(spacing: 10) {
                    Image(systemName: shelf.isTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.system(size: 32, weight: .light)).foregroundStyle(.cyan).accessibilityHidden(true)
                    Text(shelf.isTargeted ? "Release to hold" : "Drop files or folders here")
                        .font(.system(size: 14, weight: .semibold))
                    Text("They stay in their original location.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(.cyan.opacity(shelf.isTargeted ? 0.12 : 0.035), in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18).strokeBorder(.cyan.opacity(contrast == .increased || shelf.isTargeted ? 0.85 : 0.35),
                                                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }

            if !shelf.items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(shelf.items, id: \.self) { url in
                        HStack(spacing: 8) {
                            ShelfDragItem(urls: [url], shelf: shelf).frame(height: 54)
                            Button { shelf.reveal(url) } label: { Image(systemName: "magnifyingglass") }
                                .help("Show in Finder").accessibilityLabel("Show \(url.lastPathComponent) in Finder")
                            Button { shelf.remove(url) } label: { Image(systemName: "xmark") }
                                .help("Remove from shelf").accessibilityLabel("Remove \(url.lastPathComponent) from shelf")
                        }
                        .buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 12)
                        if url != shelf.items.last { Divider().padding(.leading, 54) }
                    }
                }.houstonCard()
            }

            if let error = shelf.error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DropShelfFooter: View {
    @ObservedObject var shelf: DropShelf

    var body: some View {
        if shelf.items.count > 1 {
            ShelfDragItem(urls: shelf.items, shelf: shelf).frame(width: 150, height: 18)
                .help("Drag every held item to Finder or another app")
        } else {
            Label("Held for this session", systemImage: "tray").foregroundStyle(.secondary)
        }
    }
}

/// AppKit supplies real file URL pasteboard writers and drag completion, including Finder's move operation.
private struct ShelfDragItem: NSViewRepresentable {
    let urls: [URL]
    let shelf: DropShelf

    func makeNSView(context: Context) -> ShelfDragView { ShelfDragView(urls: urls, shelf: shelf) }
    func updateNSView(_ view: ShelfDragView, context: Context) {
        view.urls = urls
        view.label.rootView = ShelfItemLabel(urls: urls)
    }
}

private struct ShelfItemLabel: View {
    let urls: [URL]

    var body: some View {
        HStack(spacing: 10) {
            if urls.count == 1, let url = urls.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(url.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            } else {
                Image(systemName: "square.on.square").foregroundStyle(.cyan)
                Text("Drag all \(urls.count) items").font(.system(size: 12, weight: .medium))
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).environment(\.colorScheme, .dark)
    }
}

private final class ShelfDragView: NSView, NSDraggingSource {
    var urls: [URL]
    let label: NSHostingView<ShelfItemLabel>
    private let shelf: DropShelf
    private var mouseDownPoint: NSPoint?
    private var draggedURLs: [URL] = []

    init(urls: [URL], shelf: DropShelf) {
        self.urls = urls
        self.shelf = shelf
        label = NSHostingView(rootView: ShelfItemLabel(urls: urls))
        super.init(frame: .zero)
        label.sizingOptions = []
        label.autoresizingMask = [.width, .height]
        addSubview(label)
        toolTip = "Drag to Finder or another app. Hold ⌘ to move, ⌥ to copy."
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }
    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        mouseDownPoint = nil
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            shelf.error = "An item moved or is unavailable. Remove it and drop it in again."
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let items = urls.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        draggedURLs = urls
        shelf.error = nil
        shelf.isDragging = true
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        shelf.finishDragging(draggedURLs, operation: operation)
        draggedURLs = []
    }
}
