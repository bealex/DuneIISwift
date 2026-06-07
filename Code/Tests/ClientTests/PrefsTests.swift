import Foundation
import Testing

@testable import DuneIIClient

/// `Prefs` is the UserDefaults-backed store for persisted game options. The round-trip + default-fallback
/// behaviour is the testable core of "options survive launches" (the rest is SwiftUI binding wiring, a
/// presentation seam with no automated harness). Keys are namespaced `duneii.option.*`; the tests clean up
/// after themselves so they don't leak into the real defaults.
struct PrefsTests {
    private func clear(_ name: String) { UserDefaults.standard.removeObject(forKey: "duneii.option.\(name)") }

    @Test func unsetKeyReturnsTheSuppliedDefault() {
        clear("probe-unset")
        defer { clear("probe-unset") }

        #expect(Prefs.bool("probe-unset", default: true))
        #expect(!Prefs.bool("probe-unset", default: false))
        #expect(Prefs.double("probe-unset", default: 3.5) == 3.5)
    }

    @Test func boolRoundTrips() {
        defer { clear("probe-bool") }

        Prefs.set("probe-bool", true)
        #expect(Prefs.bool("probe-bool", default: false))
        Prefs.set("probe-bool", false)
        // A stored `false` must win over a `true` default — the value is set, not merely absent.
        #expect(!Prefs.bool("probe-bool", default: true))
    }

    @Test func doubleRoundTrips() {
        defer { clear("probe-double") }

        Prefs.set("probe-double", 2)
        #expect(Prefs.double("probe-double", default: 1) == 2)
        Prefs.set("probe-double", 0.5)
        #expect(Prefs.double("probe-double", default: 1) == 0.5)
    }
}
