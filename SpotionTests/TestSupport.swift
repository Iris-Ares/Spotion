import Foundation

enum TestSupport {
    static func makeTempDir() throws -> URL {
        // resolvingSymlinksInPath: /var/folders → /private/var/folders, matching
        // the canonical paths FileManager enumeration returns, so path
        // assertions are immune to symlink spelling differences
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpotionTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func write(_ content: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }
}
