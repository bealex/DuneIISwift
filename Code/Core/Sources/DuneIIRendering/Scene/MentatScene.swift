import Foundation
import AppKit
import SpriteKit
import DuneIICore

/// Pre-scenario Mentat briefing screen (slice 1 — shell only). Shows
/// the player-house Mentat backdrop (MENTATA / MENTATH / MENTATO /
/// MENTATM / MENTATS / MENTATF `.CPS`) with the scenario's
/// `BriefPicture` WSA animating in the sub-screen region. Click
/// anywhere to advance to the scenario.
///
/// Slice 2 will port `GUI_Mentat_Animation` (mouth sprite cycle, eye
/// blink, shoulder / house-object animation). Slice 3 adds voice
/// playback and briefing text from the string table.
///
/// See `Documentation/Algorithms/MentatBriefing.md`.
@MainActor
public final class MentatScene: SKScene {
    public static let nativeSize = MainMenuScene.nativeSize

    public weak var coordinator: SceneCoordinator?
    public let scenarioName: String
    private let assets: AssetLoader
    private let playerHouseID: UInt8
    private let briefingWsaName: String?

    /// Briefing-picture animation frame index + timer. OpenDUNE loops
    /// the sub-screen WSA at roughly 10 fps (`GUI_Mentat_Loop`'s
    /// `frame++` every ~7 timer ticks at 60 Hz); we hit the same cadence
    /// with SpriteKit by waiting `framesPerBrief` render frames between
    /// sprite-texture swaps.
    private static let framesPerBrief = 6    // 60 Hz / 6 ≈ 10 fps
    private var briefSprite: SKSpriteNode?
    private var briefFrames: [SKTexture] = []
    private var briefFrameIndex: Int = 0
    private var briefFrameCounter: Int = 0

    public init(
        assets: AssetLoader,
        playerHouseID: UInt8 = Simulation.House.atreides,
        scenarioName: String = "",
        briefingWsaName: String? = nil
    ) {
        self.assets = assets
        self.playerHouseID = playerHouseID
        self.scenarioName = scenarioName
        self.briefingWsaName = briefingWsaName
        super.init(size: Self.nativeSize)
        scaleMode = .aspectFit
        backgroundColor = .black
        anchorPoint = .zero
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func didMove(to view: SKView) {
        removeAllChildren()
        installBackdrop()
        installBriefingAnimation()
        installCaption()
    }

    public override func update(_ currentTime: TimeInterval) {
        advanceBriefingFrame()
    }

    public override func mouseDown(with event: NSEvent) {
        coordinator?.advance(from: self)
    }

    // MARK: - Backdrop

    private func installBackdrop() {
        // Preferred CPS for the player's house; fall back through the
        // rest so a stripped install still renders a mentat face.
        let primary = Self.cpsName(forHouse: playerHouseID)
        var tried: [String] = [primary]
        for candidate in Self.allHouseCpsFallbacks where !tried.contains(candidate) {
            tried.append(candidate)
        }
        for name in tried {
            guard let image = try? assets.loadCps(named: name) else { continue }
            let texture = SKTexture(cgImage: image)
            texture.filteringMode = .nearest
            let sprite = SKSpriteNode(texture: texture)
            sprite.anchorPoint = .zero
            sprite.position = .zero
            sprite.size = Self.nativeSize
            addChild(sprite)
            return
        }
    }

    // MARK: - Briefing-picture sub-screen

    private func installBriefingAnimation() {
        guard let name = briefingWsaName else { return }
        guard let wsa = try? assets.loadWsa(named: name), !wsa.frames.isEmpty else {
            Log.info(
                "mentat brief WSA missing: \(name)",
                tracer: .label("mentat")
            )
            return
        }
        briefFrames = wsa.frames.map {
            let t = SKTexture(cgImage: $0)
            t.filteringMode = .nearest
            return t
        }
        let sprite = SKSpriteNode(texture: briefFrames[0])
        // Position: centred on the mentat's sub-screen area. Precise
        // per-house coordinates land in slice 2 via
        // `s_mentatSpritePositions`; slice 1 uses the middle of the
        // native frame so it's visible above the mentat's "desk".
        sprite.size = CGSize(width: CGFloat(wsa.width), height: CGFloat(wsa.height))
        sprite.position = CGPoint(
            x: Self.nativeSize.width / 2,
            y: Self.nativeSize.height * 0.62
        )
        sprite.zPosition = 1
        addChild(sprite)
        briefSprite = sprite
    }

    private func advanceBriefingFrame() {
        guard !briefFrames.isEmpty, let sprite = briefSprite else { return }
        briefFrameCounter += 1
        if briefFrameCounter < Self.framesPerBrief { return }
        briefFrameCounter = 0
        briefFrameIndex = (briefFrameIndex + 1) % briefFrames.count
        sprite.texture = briefFrames[briefFrameIndex]
    }

    // MARK: - Caption

    private func installCaption() {
        let caption = SKLabelNode(text: "Mentat briefing — click to continue")
        caption.fontColor = .white
        caption.fontSize = 10
        caption.position = CGPoint(x: Self.nativeSize.width / 2, y: 12)
        caption.horizontalAlignmentMode = .center
        caption.zPosition = 2
        addChild(caption)
    }

    // MARK: - House / scenario helpers (pure; tested in MentatSceneTests)

    /// `MENTAT{letter}.CPS` for a house ID. Port of OpenDUNE
    /// `g_table_houseInfo[houseID].name[0]` at `src/gui/mentat.c:494`.
    public static func cpsName(forHouse houseID: UInt8) -> String {
        switch houseID {
        case Simulation.House.harkonnen: return "MENTATH.CPS"
        case Simulation.House.atreides:  return "MENTATA.CPS"
        case Simulation.House.ordos:     return "MENTATO.CPS"
        case Simulation.House.fremen:    return "MENTATF.CPS"
        case Simulation.House.sardaukar: return "MENTATS.CPS"
        case Simulation.House.mercenary: return "MENTATM.CPS"
        default:                         return "MENTATA.CPS"
        }
    }

    /// Fallback CPS list — the install may ship only the three campaign
    /// houses (A / H / O) plus mercenary (M); slice 1 walks this list
    /// so a missing asset doesn't blank the scene.
    private static let allHouseCpsFallbacks: [String] = [
        "MENTATA.CPS", "MENTATH.CPS", "MENTATO.CPS", "MENTATM.CPS",
    ]

    /// Infers the player's house from a scenario filename. `SCENA###` =
    /// Atreides, `SCENH###` = Harkonnen, `SCENO###` = Ordos; anything
    /// else falls back to Atreides. Case-insensitive; trailing `.INI`
    /// optional.
    public static func playerHouse(forScenarioName name: String) -> UInt8 {
        let upper = name.uppercased()
        // Strip any directory + .INI extension; match on the 5th char.
        guard let slashless = upper.components(separatedBy: "/").last else {
            return Simulation.House.atreides
        }
        let stem = slashless.hasSuffix(".INI")
            ? String(slashless.dropLast(4))
            : slashless
        guard stem.count >= 5 else { return Simulation.House.atreides }
        let houseChar = stem[stem.index(stem.startIndex, offsetBy: 4)]
        switch houseChar {
        case "H": return Simulation.House.harkonnen
        case "A": return Simulation.House.atreides
        case "O": return Simulation.House.ordos
        default:  return Simulation.House.atreides
        }
    }
}
