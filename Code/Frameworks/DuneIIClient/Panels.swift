import DuneIIInput
import DuneIISimulation
import DuneIIWorld
import SwiftUI

/// The debug toggle/label rows **without** a `Form`/`List` wrapper, so a caller can drop them into its own
/// container (e.g. the Options screen embeds them in its single Form instead of nesting a second one).
struct DebugToggleRows: View {
    @Bindable
    var model: GameModel

    var body: some View {
        Group {
            Toggle("Fog of war", isOn: $model.showFog)
            Toggle("AI fog of war", isOn: $model.aiFogOfWar)
            if model.aiFogOfWar {
                Text(
                    "The AI only attacks after you make contact (its units/your scouts sighting each other). Applies immediately, even mid-game."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Full sight while moving", isOn: $model.fullSightMovementReveal)
            if !model.fullSightMovementReveal {
                Text(
                    "Off = OpenDUNE-faithful: a moving unit clears only a 1-tile trail; the full sight disc lags behind."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Follow unit limit", isOn: $model.enforceUnitLimit)
            if !model.enforceUnitLimit {
                Text("Unit cap (scenario MaxUnit) ignored — build past it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Play indefinitely", isOn: $model.playIndefinitely)
            if model.playIndefinitely {
                Text("Victory/defeat is disabled — the game never ends. Turning it on clears any current outcome.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Minimap (force on)", isOn: $model.forceMinimap)
            if !model.forceMinimap {
                Text("Off: the minimap obeys radar (needs an outpost + power). On: always shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Show all economies", isOn: $model.showAllEconomies)
            Toggle("Health bars (units + buildings)", isOn: $model.showHealthOverlay)
            LabeledContent("Player house", value: model.playerHouse.displayName)
            LabeledContent("Scenario", value: model.scenarioTitle)
            LabeledContent("Campaign level", value: "\(model.campaignLevel)")
        }
    }
}

extension PanelAction {
    /// The button caption — the original action name (`ActionInfo`) with its keyboard shortcut appended.
    var label: String {
        if let s = type.shortcut { return "\(ActionInfo[type].name) (\(s))" }
        return ActionInfo[type].name
    }
}

extension ActionType {
    /// The keyboard shortcut letter for this action (matches `GameScene.keyDown`), or `nil` for the non-player
    /// actions that never appear in a unit's `actionsPlayer` menu (Ambush/Hunt/Die — AI-only). `r` = Return
    /// (per the harvester); Retreat is `e`, Guard `g`, Deploy `d`, Sabotage `b`, Destruct `x`, Stop `s`. Every
    /// action surfaced for a selected unit therefore carries a shortcut.
    var shortcut: String? {
        switch self {
            case .attack: "A";
            case .move: "M";
            case .harvest: "H";
            case .return: "R"
            case .retreat: "E";
            case .guard_, .areaGuard: "G";
            case .deploy: "D"
            case .sabotage: "B";
            case .destruct: "X";
            case .stop: "S"
            default: nil
        }
    }

    /// The matching armed-order kind for a targeted action, else `nil` (an immediate `.unit` action).
    var orderKind: OrderKind? {
        switch self {
            case .attack: .attack;
            case .move: .move;
            case .harvest: .harvest;
            case .retreat: .retreat
            default: nil
        }
    }

    /// SF Symbol for the action-panel button.
    var systemImage: String {
        switch self {
            case .attack: "target";
            case .move: "arrow.up.right";
            case .harvest: "leaf"
            case .retreat: "arrow.uturn.left";
            case .guard_, .areaGuard: "shield"
            case .return: "arrow.down.left.circle";
            case .stop: "stop.fill"
            case .deploy: "shippingbox";
            case .destruct: "burst";
            case .sabotage: "bolt.trianglebadge.exclamationmark"
            case .ambush: "eye.slash";
            case .hunt: "scope";
            case .die: "xmark"
        }
    }
}

/// Presentation labels for the unit orders (the keyboard shortcuts are `m`/`a`/`h`/`r`, plus `s` for stop).
extension OrderKind {
    var label: String {
        switch self { case .move: "Move";  case .attack: "Attack";  case .harvest: "Harvest";  case .retreat: "Retreat"
        }
    }
    var verb: String {
        switch self { case .move: "move";  case .attack: "attack";  case .harvest: "harvest";  case .retreat: "retreat"
        }
    }
    var shortcut: String {
        switch self { case .move: "M";  case .attack: "A";  case .harvest: "H";  case .retreat: "R"
        }
    }
    var systemImage: String {
        switch self { case .move: "arrow.up.right";  case .attack: "target";  case .harvest: "leaf";  case .retreat:
            "arrow.uturn.left"
        }
    }
}
