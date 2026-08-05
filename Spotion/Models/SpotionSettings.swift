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

/// UserDefaults 门面。全部为无存储的静态计算属性，任意线程可用（UserDefaults 自身线程安全）。
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

    /// Quick Create 未指定项目时的默认工作目录
    static var defaultNewSessionDir: String {
        get { nonEmpty(d.string(forKey: "defaultNewSessionDir")) ?? NSHomeDirectory() }
        set { d.set(newValue, forKey: "defaultNewSessionDir") }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}
