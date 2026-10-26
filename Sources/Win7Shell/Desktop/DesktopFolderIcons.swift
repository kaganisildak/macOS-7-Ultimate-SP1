import AppKit
import Win7Core
import Win7Theme

/// The Windows 7 folder art (Win7Theme's W7CreateFolderIconImage) for desktop folders, cached by kind
/// and icon size, each image holding 1x and 2x bitmaps.
@MainActor
enum DesktopFolderIcons {
    private static var cache: [String: NSImage] = [:]

    static func kind(_ art: DesktopFolderArt) -> W7FolderIconKind {
        switch art {
        case .plain: .plain
        case .documents: .documents
        case .pictures: .pictures
        case .music: .music
        case .videos: .videos
        case .downloads: .downloads
        case .desktop: .desktop
        case .user: .user
        }
    }

    static func image(_ art: DesktopFolderArt, side: CGFloat) -> NSImage? {
        let key = "\(art.rawValue)|\(side)"
        if let hit = cache[key] { return hit }
        let image = NSImage(size: NSSize(width: side, height: side))
        for scale: CGFloat in [1, 2] {
            guard let cg = W7CreateFolderIconImage(kind(art), side, scale) else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = image.size
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        cache[key] = image
        return image
    }
}
