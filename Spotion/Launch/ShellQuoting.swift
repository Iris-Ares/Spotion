import Foundation

enum ShellQuoting {
    /// POSIX 单引号包裹：'a'\''b' 风格，适用于任意内容（空格/引号/换行/中文）。
    static func posixQuoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 字符串字面量转义（反斜杠与双引号）。
    static func appleScriptQuoted(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
