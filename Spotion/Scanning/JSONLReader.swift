import Foundation

/// Bounded JSONL reading: session files reach 13MB and are appended live —
/// never read a whole file.
enum JSONLReader {
    /// At most `cap` bytes from the head, split into lines; if the cap was hit,
    /// the trailing incomplete line is dropped.
    static func headLines(of url: URL, cap: Int) throws -> [Data] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let data = try fh.read(upToCount: cap) ?? Data()
        return split(data, dropLast: data.count == cap)
    }

    /// At most `cap` bytes from the tail; when the window does not start at the
    /// beginning of the file, the first (potentially partial) line is dropped.
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
    /// Timestamps in session files look like "2026-08-05T10:08:52.613Z", with
    /// an occasional variant lacking fractional seconds.
    static func date(from string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}
