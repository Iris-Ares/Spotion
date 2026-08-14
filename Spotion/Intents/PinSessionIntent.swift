import AppIntents

struct PinSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin Spotion Session"
    static let description = IntentDescription(
        "Pin a local agent session in Spotion and give it higher Spotlight donation priority.",
        categoryName: "Sessions"
    )

    @Parameter(title: "Session")
    var session: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Pin \(\.$session)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AppCoordinator.shared.pinSession(id: session.id)
        return .result(dialog: "Pinned \(session.title) in Spotion.")
    }
}

struct UnpinSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Unpin Spotion Session"
    static let description = IntentDescription(
        "Remove a local Spotion pin and restore normal Spotlight donation priority.",
        categoryName: "Sessions"
    )

    @Parameter(title: "Session")
    var session: SessionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Unpin \(\.$session)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AppCoordinator.shared.unpinSession(id: session.id)
        return .result(dialog: "Unpinned \(session.title) in Spotion.")
    }
}
