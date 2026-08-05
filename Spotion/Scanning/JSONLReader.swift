import Foundation

/// 有界 JSONL 读取：会话文件可达 13MB 且被 live 追加，永不整读。
enum JSONLReader {
    /// 头部最多 `cap` 字节，按行切分；若命中上限则丢弃末尾的不完整行。
    static func headLines(of url: URL, cap: Int) throws -> [Data] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let data = try fh.read(upToCount: cap) ?? Data()
        return split(data, dropLast: data.count == cap)
    }

    /// 尾部最多 `cap` 字节；若非从文件头开始读，丢弃开头的（可能不完整的）第一行。
    static func tailLines(of url: URL, cap: Int) throws -> [Data] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let size = try fh.seekToEnd()
        let offset = size > UInt64(cap) ? size - UInt64(cap) : 0
        try fh.seek(toOffset: offset)
        let data = try fh.readToEnd() ?? Data()
        return split(data, dropFirst: offset > 0)
    }

    private static func split(_ data: Data, dropFirst: Bool = false, dropLast: Bool = false) -> [Data] {
        let newline = UInt8(ascii: "\n")
        var lines: [Data] = []
        var start = data.startIndex
        for i in data.indices {
            if data[i] == newline {
                if i > start { lines.append(data.subdata(in: start..<i)) }
                start = data.index(after: i)
            }
        }
        if start < data.endIndex { lines.append(data.subdata(in: start..<data.endIndex)) }
        if dropFirst, !lines.isEmpty { lines.removeFirst() }
        if dropLast, !lines.isEmpty, data.last != newline { lines.removeLast() }
        return lines
    }
}

enum ISO8601 {
    /// 会话文件里的时间戳形如 "2026-08-05T10:08:52.613Z"，偶有无小数秒的变体。
    static func date(from string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}
