import AppKit
import Foundation
import Synchronization

/// Per-agent artwork for Spotlight results: the installed desktop app's icon
/// (Codex/ChatGPT or Claude), falling back to Spotion's own app icon. The
/// source icon is resolved through LaunchServices at runtime — no third-party
/// artwork is bundled — and rendered to PNG once per source, cached keyed by
/// the resolved app path so an install/uninstall is picked up by the next
/// donation pass (refresh or reindex) without relaunching Spotion.
///
/// App icons ship pre-composed on their own plate, so the same bitmap is
/// legible on both light and dark Spotlight backgrounds.
final class AgentIconProvider: Sendable {
    static let shared = AgentIconProvider()

    /// Largest size Spotlight renders for a result thumbnail; donated with
    /// every item, so keep it modest.
    private static let pixelSize = 256

    private struct Entry {
        /// Resolved handler app path; "" when falling back to Spotion's icon.
        var sourcePath: String
        var png: Data?
    }

    private let cache = Mutex<[AgentKind: Entry]>([:])

    /// PNG thumbnail for the agent's results. nil only if even the fallback
    /// failed to render — callers then leave the attribute unset.
    func thumbnailPNG(for agent: AgentKind) -> Data? {
        let appURL = NSWorkspace.shared.urlForApplication(toOpen: NativeAppLink.probeURL(for: agent))
        let sourcePath = appURL?.path ?? ""
        return cache.withLock { cache in
            if let entry = cache[agent], entry.sourcePath == sourcePath {
                return entry.png
            }
            let png = Self.renderPNG(appURL: appURL)
            cache[agent] = Entry(sourcePath: sourcePath, png: png)
            return png
        }
    }

    private static func renderPNG(appURL: URL?) -> Data? {
        if let appURL, let png = pngData(NSWorkspace.shared.icon(forFile: appURL.path)) {
            return png
        }
        return spotionIcon().flatMap(pngData)
    }

    /// The named lookup resolves the bundled AppIcon asset; the NSWorkspace
    /// path covers contexts where the named image cache is unavailable.
    private static func spotionIcon() -> NSImage? {
        NSImage(named: NSImage.applicationIconName)
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    /// Draws into an explicit bitmap context: icon images carry many
    /// representations, and this picks/downscales deterministically at exactly
    /// pixelSize regardless of screen scale. Offscreen drawing is
    /// thread-confined (NSGraphicsContext.current is thread-local), so this is
    /// safe from the indexer's background context.
    private static func pngData(_ image: NSImage) -> Data? {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = NSSize(width: pixelSize, height: pixelSize)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
            from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }
}
