import Foundation

enum SpotlightHistoryWindow: String, Codable, CaseIterable, Sendable {
    case all
    case sevenDays
    case thirtyDays
    case ninetyDays

    var displayName: String {
        switch self {
        case .all: "All history"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        }
    }

    private var duration: TimeInterval? {
        switch self {
        case .all: nil
        case .sevenDays: 7 * 86_400
        case .thirtyDays: 30 * 86_400
        case .ninetyDays: 90 * 86_400
        }
    }

    /// Uses an absolute elapsed-time cutoff rather than calendar arithmetic,
    /// so changing time zones or crossing a daylight-saving boundary does not
    /// move an otherwise unchanged session across the window.
    func contains(lastActivityAt: Date, now: Date) -> Bool {
        guard let duration else { return true }
        return lastActivityAt >= now.addingTimeInterval(-duration)
    }
}
