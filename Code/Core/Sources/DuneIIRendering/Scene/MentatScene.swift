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

    // Slice 2 — mentat face animation.
    private var animator = MentatAnimator()
    private var eyeTextures: [SKTexture] = []
    private var mouthTextures: [SKTexture] = []
    private var otherTextures: [SKTexture] = []
    private var shoulderTexture: SKTexture?
    private var eyeSprite: SKSpriteNode?
    private var mouthSprite: SKSpriteNode?
    private var otherSprite: SKSpriteNode?
    private var shoulderSprite: SKSpriteNode?
    /// GUI tick counter — 1 per render frame to match OpenDUNE's
    /// `g_timerGUI` (60 Hz).
    private var animationTick: UInt32 = 0
    /// Per-session `BorlandLCG` seed — mirrors OpenDUNE's
    /// `Tools_RandomLCG_Range` caller semantics. Kept stable across
    /// ticks so the cadence looks natural; re-seeded per scene open
    /// off the scenario name so different missions produce visibly
    /// different idle patterns.
    private var animationRNG: RNG.BorlandLCG = RNG.BorlandLCG(seed: 1)

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
        installMentatAnimation()
        installBriefingAnimation()
        installCaption()
    }

    public override func update(_ currentTime: TimeInterval) {
        advanceBriefingFrame()
        advanceMentatAnimation()
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

    // MARK: - Mentat face animation (slice 2)

    /// Per-house sprite offsets from the `MENSHP{H,A,O,M}.SHP` atlas.
    /// Port of `s_mentatSpritePositions` at `src/gui/mentat.c:40..47`:
    /// `{eyeX, eyeY, mouthX, mouthY, otherX, otherY, shoulderX, shoulderY}`.
    /// Native 320×200 Dune II coords; we flip Y when positioning into
    /// the scene since SpriteKit's origin is bottom-left.
    private static let spritePositions: [UInt8: (eye: (Int, Int), mouth: (Int, Int), other: (Int, Int), shoulder: (Int, Int))] = [
        Simulation.House.harkonnen: (eye: (0x20, 0x58), mouth: (0x20, 0x68), other: (0x00, 0x00), shoulder: (0x80, 0x68)),
        Simulation.House.atreides:  (eye: (0x28, 0x50), mouth: (0x28, 0x60), other: (0x48, 0x98), shoulder: (0x80, 0x80)),
        Simulation.House.ordos:     (eye: (0x10, 0x50), mouth: (0x10, 0x60), other: (0x58, 0x90), shoulder: (0x80, 0x80)),
        Simulation.House.mercenary: (eye: (0x40, 0x50), mouth: (0x38, 0x60), other: (0x00, 0x00), shoulder: (0x00, 0x00)),
    ]

    /// `MENSHP{letter}.SHP` — the 15-frame atlas OpenDUNE loads at
    /// `src/sprites.c:495..500`. Frames 0..4 = eyes, 5..9 = mouth,
    /// 10 = shoulder, 11..14 = other (book / ring).
    private static func menshpName(forHouse houseID: UInt8) -> String {
        switch houseID {
        case Simulation.House.harkonnen: return "MENSHPH.SHP"
        case Simulation.House.atreides:  return "MENSHPA.SHP"
        case Simulation.House.ordos:     return "MENSHPO.SHP"
        default:                         return "MENSHPM.SHP"   // Mercenary / Fremen / Sardaukar share this
        }
    }

    private func installMentatAnimation() {
        let shpName = Self.menshpName(forHouse: playerHouseID)
        guard let frames = try? assets.loadShp(named: shpName), frames.count >= 15 else {
            Log.info(
                "mentat face SHP missing or short: \(shpName)",
                tracer: .label("mentat")
            )
            return
        }
        let textures: [SKTexture] = frames.map {
            let t = SKTexture(cgImage: $0)
            t.filteringMode = .nearest
            return t
        }
        eyeTextures    = Array(textures[0..<5])
        mouthTextures  = Array(textures[5..<10])
        shoulderTexture = textures[10]
        otherTextures  = Array(textures[11..<15])

        // Seed the RNG off the scenario name so different missions
        // produce visibly different blink / mouth cadence — but
        // deterministic within a session (helpful for manual debug).
        let seed = UInt16(truncatingIfNeeded: scenarioName.hashValue)
        animationRNG = RNG.BorlandLCG(seed: seed == 0 ? 1 : seed)

        // The "other" frame count reflects how many distinct house-
        // object sprites this mentat has. Harkonnen = 0 (no object);
        // Atreides book + Ordos ring = 2 frames in practice even though
        // OpenDUNE carries 4 slots per house in the SHP.
        animator = MentatAnimator(
            otherFrameCount: (playerHouseID == Simulation.House.atreides ||
                              playerHouseID == Simulation.House.ordos) ? 2 : 0
        )

        guard let positions = Self.spritePositions[playerHouseID] else { return }

        // Shoulder first (drawn behind eyes / mouth in OpenDUNE's
        // `GUI_DrawSprite(SCREEN_1, shoulder, …)` pass at mentat.c:545).
        shoulderSprite = makeOverlay(
            texture: shoulderTexture, atDunePoint: positions.shoulder, zPos: 1
        )
        eyeSprite = makeOverlay(
            texture: eyeTextures.first, atDunePoint: positions.eye, zPos: 2
        )
        mouthSprite = makeOverlay(
            texture: mouthTextures.first, atDunePoint: positions.mouth, zPos: 2
        )
        if positions.other != (0, 0), !otherTextures.isEmpty {
            otherSprite = makeOverlay(
                texture: otherTextures.first, atDunePoint: positions.other, zPos: 2
            )
        }
    }

    /// Builds an SKSpriteNode positioned at Dune II's native (320×200)
    /// top-left coordinate `(x, y)`. Inverts Y for SpriteKit's
    /// bottom-left origin so the sprite draws at the expected pixel.
    private func makeOverlay(
        texture: SKTexture?, atDunePoint p: (Int, Int), zPos: CGFloat
    ) -> SKSpriteNode? {
        guard let tex = texture else { return nil }
        let size = tex.size()
        let sprite = SKSpriteNode(texture: tex)
        sprite.anchorPoint = CGPoint(x: 0, y: 1)    // top-left anchor
        sprite.size = size
        sprite.position = CGPoint(
            x: CGFloat(p.0),
            y: Self.nativeSize.height - CGFloat(p.1)
        )
        sprite.zPosition = zPos
        addChild(sprite)
        return sprite
    }

    private func advanceMentatAnimation() {
        guard !eyeTextures.isEmpty else { return }
        animationTick &+= 1
        var rng = animationRNG
        animator.tick(
            now: animationTick,
            // Slice 2 has no voice yet, so we pick `.speaking` to give
            // the mentat a lifelike mouth while waiting for the click.
            // Slice 3 will gate this on actual voice playback.
            speakingMode: .speaking,
            playerHouseID: playerHouseID,
            rng: { lo, hi in rng.range(lo, hi) }
        )
        animationRNG = rng

        if let eye = eyeSprite, animator.eyesFrame < eyeTextures.count {
            eye.texture = eyeTextures[animator.eyesFrame]
        }
        if let mouth = mouthSprite, animator.mouthFrame < mouthTextures.count {
            mouth.texture = mouthTextures[animator.mouthFrame]
        }
        if let other = otherSprite, !otherTextures.isEmpty {
            let idx = abs(animator.otherFrame) % otherTextures.count
            other.texture = otherTextures[idx]
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
