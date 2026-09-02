import Foundation

@MainActor
protocol PlainTextClipboard: Sendable {
    func replacePlainText(with string: String) throws
}

/// Copies exactly the command TerminalLauncher would run — same resolver,
/// same construction — so the two can never drift. The command is built
/// completely before the clipboard is touched: a missing executable or a
/// missing required directory leaves the user's clipboard as it was.
struct ResumeCommandCopier: Sendable {
    private let launcher: TerminalLauncher

    init(launcher: TerminalLauncher = .shared) {
        self.launcher = launcher
    }

    @MainActor
    @discardableResult
    func copy(_ record: SessionRecord, to clipboard: any PlainTextClipboard) throws -> String {
        let command = try launcher.resumeCommand(for: record)
        try clipboard.replacePlainText(with: command)
        return command
    }
}
