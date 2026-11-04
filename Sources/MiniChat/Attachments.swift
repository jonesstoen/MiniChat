import AppKit
import UniformTypeIdentifiers

/// A file attached in the quick bar.
struct QuickAttachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let isImage: Bool

    var name: String { url.lastPathComponent }
}

/// Keeps copies of attached files in a temporary folder, so the originals
/// can be moved or deleted while the chat is being sent.
enum AttachmentStore {
    static let maxCount = 10

    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MiniChatAttachments", isDirectory: true)
    }

    /// A new, empty folder.
    static func newFolder() -> URL {
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A new, empty location for a file with the given name.
    static func newURL(name: String) -> URL {
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    static func copy(_ url: URL) -> URL? {
        let destination = newURL(name: url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    static func save(_ image: NSImage, name: String = "Image.png") -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = newURL(name: name)
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func thumbnail(for attachment: QuickAttachment) -> NSImage {
        if attachment.isImage, let image = NSImage(contentsOf: attachment.url) { return image }
        return NSWorkspace.shared.icon(forFile: attachment.url.path)
    }

    // MARK: Clipboard

    /// A copy of everything on the clipboard, so it can be put back afterwards.
    static func snapshotPasteboard() -> [[(NSPasteboard.PasteboardType, Data)]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    static func restorePasteboard(_ snapshot: [[(NSPasteboard.PasteboardType, Data)]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// Puts the files on the clipboard the way Finder does. A single image also
    /// goes on as image data, which every chat page understands.
    static func writeToPasteboard(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if urls.count == 1, isImage(urls[0]), let image = NSImage(contentsOf: urls[0]) {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.writeObjects(urls as [NSURL])
        }
    }
}
