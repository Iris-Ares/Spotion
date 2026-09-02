import AppKit

@MainActor
struct SystemPlainTextClipboard: PlainTextClipboard {
    static let shared = SystemPlainTextClipboard()

    struct WriteError: LocalizedError {
        var errorDescription: String? { "无法将恢复命令写入剪贴板" }
    }

    func replacePlainText(with string: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(string, forType: .string) else {
            throw WriteError()
        }
    }
}
