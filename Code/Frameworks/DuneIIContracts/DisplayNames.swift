/// Human-readable names for the shared seam enums, so the verification UI (inspector, selection panel)
/// can label a selected unit / structure / house without reaching into the simulation's stat tables.
/// Derived by prettifying the case name (camelCase → words), with a few overrides for acronyms.

private func prettify(_ raw: String, overrides: [String: String]) -> String {
    if let override = overrides[raw] { return override }
    var out = ""
    for ch in raw {
        if ch.isUppercase && !out.isEmpty { out.append(" ") }
        out.append(ch)
    }
    return out.prefix(1).uppercased() + out.dropFirst()
}

public extension UnitType {
    var displayName: String {
        prettify(String(describing: self), overrides: [
            "mcv": "MCV", "missileHouse": "House Missile", "missileRocket": "Rocket",
            "missileTurret": "Turret Rocket", "missileDeviator": "Gas Rocket",
            "missileTrooper": "Trooper Rocket", "sonicBlast": "Sonic Blast", "raiderTrike": "Raider Trike",
        ])
    }
}

public extension StructureType {
    var displayName: String {
        prettify(String(describing: self), overrides: [
            "slab1x1": "Concrete", "slab2x2": "Concrete (2×2)", "lightVehicle": "Light Factory",
            "heavyVehicle": "Heavy Factory", "highTech": "Hi-Tech Factory", "houseOfIx": "House of IX",
            "worTrooper": "WOR", "constructionYard": "Construction Yard", "rocketTurret": "Rocket Turret",
        ])
    }
}

public extension HouseID {
    var displayName: String {
        prettify(String(describing: self), overrides: [:])
    }
}
