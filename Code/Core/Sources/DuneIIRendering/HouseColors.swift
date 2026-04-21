import Foundation
import AppKit
import DuneIICore

/// Canonical on-screen colour per house. These are placeholder render
/// colours used by the P3 marker layer — the real units use per-house
/// palette remap tables baked into their SHP frames (P4+).
public enum HouseColors {
    public static func color(for house: House) -> NSColor {
        switch house {
        case .atreides:   return NSColor(srgbRed: 0.20, green: 0.48, blue: 1.00, alpha: 1.0)
        case .harkonnen:  return NSColor(srgbRed: 0.90, green: 0.12, blue: 0.12, alpha: 1.0)
        case .ordos:      return NSColor(srgbRed: 0.20, green: 0.80, blue: 0.35, alpha: 1.0)
        case .fremen:     return NSColor(srgbRed: 0.98, green: 0.88, blue: 0.40, alpha: 1.0)
        case .sardaukar:  return NSColor(srgbRed: 0.70, green: 0.25, blue: 0.85, alpha: 1.0)
        case .mercenary:  return NSColor(srgbRed: 1.00, green: 0.55, blue: 0.10, alpha: 1.0)
        }
    }
}
