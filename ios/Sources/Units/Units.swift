import Foundation

/// Measurement system used for display, and for reading bare numbers the user types.
enum UnitSystem: String, Codable, CaseIterable {
    case imperial
    case metric

    /// Name shown in settings.
    var displayName: String {
        switch self {
        case .imperial: return "Imperial (ft, in)"
        case .metric: return "Metric (m, mm)"
        }
    }
}

/// Smallest inch fraction shown in imperial lengths.
enum FractionDenominator: Int, Codable, CaseIterable {
    case eighth = 8
    case sixteenth = 16
}

/// The user's unit display preferences, stored as JSON in UserDefaults under "units".
struct UnitPreferences: Codable, Equatable {
    var system: UnitSystem
    var fraction: FractionDenominator
    /// Show the other system in parentheses after the primary value.
    var showBoth: Bool

    /// Imperial, 1/8", both systems shown.
    static let standard = UnitPreferences(system: .imperial, fraction: .eighth, showBoth: true)

    /// UserDefaults key (same value as `SettingsKey.units`).
    static let defaultsKey = "units"

    enum CodingKeys: String, CodingKey {
        case system, fraction, showBoth
    }

    /// Reads the saved preferences. Missing, corrupt or partial data falls back to
    /// `standard` field by field; a legacy plain "imperial"/"metric" string is honored.
    static func load(from defaults: UserDefaults = .standard) -> UnitPreferences {
        if let data = defaults.data(forKey: defaultsKey) {
            if let prefs = try? JSONDecoder().decode(UnitPreferences.self, from: data) {
                return prefs
            }
            return standard
        }
        if let raw = defaults.string(forKey: defaultsKey), let system = UnitSystem(rawValue: raw) {
            var prefs = standard
            prefs.system = system
            return prefs
        }
        return standard
    }

    /// Writes the preferences as JSON. Encoding failure leaves the old value in place.
    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: UnitPreferences.defaultsKey)
    }
}

extension UnitPreferences {
    /// Tolerant decoding: an unknown or missing field takes its `standard` value
    /// instead of failing the whole object (settings written by older builds).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = UnitPreferences.standard
        let system = try? container.decodeIfPresent(UnitSystem.self, forKey: .system)
        let fraction = try? container.decodeIfPresent(FractionDenominator.self, forKey: .fraction)
        let showBoth = try? container.decodeIfPresent(Bool.self, forKey: .showBoth)
        self.init(system: system ?? fallback.system,
                  fraction: fraction ?? fallback.fraction,
                  showBoth: showBoth ?? fallback.showBoth)
    }
}
