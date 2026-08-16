import Foundation
import Testing

@Suite(.serialized) struct SpotlightHistoryWindowTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func allHistoryIncludesAnyActivityDate() {
        #expect(SpotlightHistoryWindow.all.contains(lastActivityAt: .distantPast, now: now))
        #expect(SpotlightHistoryWindow.all.contains(lastActivityAt: .distantFuture, now: now))
    }

    @Test func boundedWindowsIncludeExactCutoffAndFutureTimestamps() {
        let cases: [(SpotlightHistoryWindow, TimeInterval)] = [
            (.sevenDays, 7 * 86_400),
            (.thirtyDays, 30 * 86_400),
            (.ninetyDays, 90 * 86_400),
        ]

        for (window, duration) in cases {
            #expect(window.contains(lastActivityAt: now.addingTimeInterval(-duration), now: now))
            #expect(!window.contains(lastActivityAt: now.addingTimeInterval(-duration - 0.001), now: now))
            #expect(window.contains(lastActivityAt: now.addingTimeInterval(86_400), now: now))
        }
    }

    @Test func cutoffUsesElapsedTimeAcrossDaylightSavingBoundaries() throws {
        let formatter = ISO8601DateFormatter()
        let afterSpringForward = try #require(formatter.date(from: "2026-03-15T12:00:00-04:00"))
        let exactSevenDays = afterSpringForward.addingTimeInterval(-7 * 86_400)

        #expect(SpotlightHistoryWindow.sevenDays.contains(
            lastActivityAt: exactSevenDays,
            now: afterSpringForward
        ))
        #expect(!SpotlightHistoryWindow.sevenDays.contains(
            lastActivityAt: exactSevenDays.addingTimeInterval(-1),
            now: afterSpringForward
        ))
    }

    @Test func missingAndUnknownPreferencesPreserveAllHistoryDefault() {
        let defaults = UserDefaults.standard
        let key = "spotlightHistoryWindow"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        #expect(SpotionSettings.spotlightHistoryWindow == .all)
        defaults.set("future-unknown-value", forKey: key)
        #expect(SpotionSettings.spotlightHistoryWindow == .all)
        SpotionSettings.spotlightHistoryWindow = .thirtyDays
        #expect(defaults.string(forKey: key) == SpotlightHistoryWindow.thirtyDays.rawValue)
    }
}
