import Foundation
import Testing

@Suite struct NativeAppLinkTests {
    private let uuid = "37820960-9057-4bd4-9c9f-47cfa12b9bf0"

    @Test func codexThreadURL() {
        #expect(
            NativeAppLink.url(agent: .codex, sessionID: uuid)?.absoluteString
                == "codex://threads/\(uuid)"
        )
    }

    @Test func claudeResumeURL() {
        #expect(
            NativeAppLink.url(agent: .claude, sessionID: uuid)?.absoluteString
                == "claude://resume?session=\(uuid)"
        )
    }

    @Test func uppercaseUUIDPassesThroughUnchanged() {
        let upper = uuid.uppercased()
        #expect(
            NativeAppLink.url(agent: .codex, sessionID: upper)?.absoluteString
                == "codex://threads/\(upper)"
        )
    }

    @Test(arguments: [
        "",
        "abc",
        "37820960",
        "37820960-9057-4bd4-9c9f-47cfa12b9bf0x",
        "37820960 9057 4bd4 9c9f 47cfa12b9bf0",
        " 37820960-9057-4bd4-9c9f-47cfa12b9bf0",
        "../../etc/passwd",
        "37820960-9057-4bd4-9c9f-47cfa12b9bf0?x=1",
        "37820960-9057-4bd4-9c9f-47cfa12b9bf0#frag",
        "37820960-9057-4bd4-9c9f-47cfa12b9bf0/extra",
        "37820960_9057_4bd4_9c9f_47cfa12b9bf0",
        "3782096g-9057-4bd4-9c9f-47cfa12b9bf0",
    ])
    func rejectsNonUUIDSessionIDs(_ bad: String) {
        #expect(NativeAppLink.url(agent: .codex, sessionID: bad) == nil)
        #expect(NativeAppLink.url(agent: .claude, sessionID: bad) == nil)
    }

    @Test func probeURLsAreSchemeOnly() {
        #expect(NativeAppLink.probeURL(for: .codex).absoluteString == "codex://")
        #expect(NativeAppLink.probeURL(for: .claude).absoluteString == "claude://")
    }
}

@Suite struct LaunchTargetTests {
    /// Persisted-format guard: these raw values live in UserDefaults.
    @Test func rawValuesAreStable() {
        #expect(LaunchTarget.cli.rawValue == "cli")
        #expect(LaunchTarget.nativeApp.rawValue == "nativeApp")
    }

    /// Documents the `?? .cli` fallback in SpotionSettings.launchTarget.
    @Test func unknownRawValueDecodesToNil() {
        #expect(LaunchTarget(rawValue: "bogus") == nil)
    }
}
