import Foundation

enum ShellQuoting {
    /// POSIX single-quote wrapping in the 'a'\''b' style — safe for arbitrary
    /// content (spaces, quotes, newlines, CJK).
    static func posixQuoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript string-literal escaping (backslashes and double quotes).
    static func appleScriptQuoted(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
