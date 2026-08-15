import Foundation

@MainActor
protocol PlainTextClipboard: Sendable {
    func replacePlainText(with string: String) throws
}

/// Builds completely before touching the clipboard, so resolution and cwd
/// failures preserve the user's existing clipboard contents.
struct ResumeCommandCopier: Sendable {
    private let commandService: ResumeCommandService

    init(commandService: ResumeCommandService = .shared) {
        self.commandService = commandService
    }

    @MainActor
    @discardableResult
    func copy(_ record: SessionRecord, to clipboard: any PlainTextClipboard) throws -> String {
        let command = try commandService.command(for: record)
        try clipboard.replacePlainText(with: command)
        return command
    }
}
