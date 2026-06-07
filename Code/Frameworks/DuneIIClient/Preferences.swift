import Foundation

/// Persisted user **options** — the audio, debug, and view toggles/pickers exposed in Settings and the
/// Options popover — stored in `UserDefaults` so they survive app launches. Simulation/game state is never
/// kept here; this is presentation/preference only.
///
/// Keys are namespaced (`duneii.option.*`) so they're easy to find and clear. Reading an unset key returns
/// the caller's default (via `object(forKey:)`, which is `nil` when absent) — so the first launch uses the
/// in-code defaults rather than `false`/`0`. (`musicBackend` predates this and keeps its bare key.)
enum Prefs {
    private static func key(_ name: String) -> String { "duneii.option.\(name)" }

    static func bool(_ name: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key(name)) as? Bool ?? fallback
    }

    static func double(_ name: String, default fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key(name)) as? Double ?? fallback
    }

    static func set(_ name: String, _ value: Bool) { UserDefaults.standard.set(value, forKey: key(name)) }
    static func set(_ name: String, _ value: Double) { UserDefaults.standard.set(value, forKey: key(name)) }
}
