import Foundation
import Testing

@Suite struct JSONLReaderTests {
    private func tempFile(_ content: String) throws -> URL {
        try TestSupport.write(content, to: try TestSupport.makeTempDir().appendingPathComponent("f.jsonl"))
    }

    @Test func headSplitsCompleteLines() throws {
        let url = try tempFile("{\"a\":1}\n{\"b\":2}\n")
        let lines = try JSONLReader.headLines(of: url, cap: 1024)
        #expect(lines.count == 2)
        #expect(String(decoding: lines[0], as: UTF8.self) == "{\"a\":1}")
    }

    @Test func headDropsPartialLineAtCap() throws {
        let line1 = "{\"a\":1}"
        let line2 = "{\"bbbbbbbbbbbbbbbb\":2}"
        let url = try tempFile(line1 + "\n" + line2 + "\n")
        // cap 落在 line2 中间 → line2 被丢弃
        let lines = try JSONLReader.headLines(of: url, cap: line1.utf8.count + 5)
        #expect(lines.count == 1)
    }

    @Test func headKeepsFinalLineWithoutTrailingNewline() throws {
        let url = try tempFile("{\"a\":1}\n{\"b\":2}")
        let lines = try JSONLReader.headLines(of: url, cap: 1024)
        #expect(lines.count == 2)
    }

    @Test func tailDropsLeadingPartialLine() throws {
        let content = "{\"first\":1}\n{\"second\":2}\n{\"third\":3}\n"
        let url = try tempFile(content)
        // 窗口从 first 行中间开始 → first 的残段被丢弃
        let lines = try JSONLReader.tailLines(of: url, cap: content.utf8.count - 3)
        #expect(lines.count == 2)
        #expect(String(decoding: lines[0], as: UTF8.self) == "{\"second\":2}")
    }

    @Test func tailOfSmallFileKeepsAllLines() throws {
        let url = try tempFile("{\"a\":1}\n{\"b\":2}\n")
        let lines = try JSONLReader.tailLines(of: url, cap: 64 * 1024)
        #expect(lines.count == 2)
    }
}
