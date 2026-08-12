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

enum LaunchTarget: String, Codable, CaseIterable, Sendable {
    case cli
    case nativeApp

    var displayName: String {
        switch self {
        case .cli: "终端 CLI"
        case .nativeApp: "桌面应用"
        }
    }
}

/// What openSession actually launched — lets the intent word its dialog
/// truthfully without re-reading settings.
enum LaunchDestination: Sendable, Equatable {
    case terminal(TerminalApp)
    /// appName is the LaunchServices-resolved handler's display name (the
    /// codex:// handler may present as "ChatGPT").
    case nativeApp(appName: String)
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

    /// Per-agent launch preference (Claude desktop opens sessions by importing
    /// a copy, so a user may want native for one agent and CLI for the other).
    /// Falls back to the legacy single "launchTarget" key, then CLI.
    static func launchTarget(for agent: AgentKind) -> LaunchTarget {
        if let raw = d.string(forKey: "launchTarget.\(agent.rawValue)"),
           let target = LaunchTarget(rawValue: raw) {
            return target
        }
        return LaunchTarget(rawValue: d.string(forKey: "launchTarget") ?? "") ?? .cli
    }

    static func setLaunchTarget(_ target: LaunchTarget, for agent: AgentKind) {
        d.set(target.rawValue, forKey: "launchTarget.\(agent.rawValue)")
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

    /// Privacy-sensitive Spotlight metadata. Missing preference means off.
    static var searchLaterPrompts: Bool {
        get { d.bool(forKey: "searchLaterPrompts") }
        set { d.set(newValue, forKey: "searchLaterPrompts") }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}
