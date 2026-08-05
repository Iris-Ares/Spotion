import Foundation

struct ScannedFile: Sendable, Hashable {
    var path: String
    var mtime: Date
    var size: Int64
}

protocol SessionScanner: Sendable {
    var agent: AgentKind { get }
    /// 扫描根目录（用于删除 diff 时判断缓存条目归属）
    var rootPath: String { get }
    /// 仅 stat，不读内容。
    /// 返回 nil = 枚举失败（权限抖动等）→ 调用方本轮不得对该根做删除；
    /// 返回 [] = 根目录为空或不存在 → 合法结果，删除照常进行。
    func enumerateFiles() -> [ScannedFile]?
    /// 有界读取解析；不可用返回 nil（记入失败计数，文件不变不重试）
    func parse(_ file: ScannedFile) -> SessionRecord?
}

extension SessionScanner {
    func statted(_ url: URL) -> ScannedFile? {
        guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = rv.contentModificationDate,
              let size = rv.fileSize else { return nil }
        return ScannedFile(path: url.path, mtime: mtime, size: Int64(size))
    }
}
