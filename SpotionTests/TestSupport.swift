import Foundation

enum TestSupport {
    static func makeTempDir() throws -> URL {
        // resolvingSymlinksInPath：/var/folders → /private/var/folders，
        // 与 FileManager 枚举返回的真实路径一致，路径断言不受符号链接干扰
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
