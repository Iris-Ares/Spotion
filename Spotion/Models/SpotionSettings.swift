import Foundation

enum TerminalApp: String, Codable, CaseIterable, Sendable {
    case terminal
    case ghostty

    var displayName: String {
        switch self {
        case .terminal: "Terminal.app"
        case .ghostty: "Ghostty"
        }
    }
}

/// UserDefaults facade. All members are storage-free static computed
/// properties, usable from any thread (UserDefaults itself is thread-safe).
enum SpotionSettings {
    private static var d: UserDefaults { .standard }

    static var enabledAgents: Set<AgentKind> {
        get {
            guard let raw = d.array(forKey: "enabledAgents") as? [String] else {
                return Set(AgentKind.allCases)
            }
            return Set(raw.compactMap(AgentKind.init(rawValue:)))
        }
        set { d.set(newValue.map(\.rawValue).sorted(), forKey: "enabledAgents") }
    }

    static var terminal: TerminalApp {
        get { TerminalApp(rawValue: d.string(forKey: "terminalApp") ?? "") ?? .terminal }
        set { d.set(newValue.rawValue, forKey: "terminalApp") }
    }

    static var codexPathOverride: String? {
        get { nonEmpty(d.string(forKey: "codexPathOverride")) }
        set { d.set(newValue, forKey: "codexPathOverride") }
    }

    static var claudePathOverride: String? {
        get { nonEmpty(d.string(forKey: "claudePathOverride")) }
        set { d.set(newValue, forKey: "claudePathOverride") }
    }

    /// Default working directory for Quick Create when no project is chosen
    static var defaultNewSessionDir: String {
        get { nonEmpty(d.string(forKey: "defaultNewSessionDir")) ?? NSHomeDirectory() }
        set { d.set(newValue, forKey: "defaultNewSessionDir") }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}
