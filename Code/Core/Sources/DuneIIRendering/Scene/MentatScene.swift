import Foundation
import AppKit
import SpriteKit
import DuneIICore

/// Stand-in for the full mentat briefing. Displays the base mentat screen
/// (`MENTATA.CPS` = Atreides by default) tinted slightly so the user can
/// see "we're on a different scene now" during manual verification.
/// House-specific assets (BENE.CPS, MENTATO.CPS, etc.) land when we wire
/// a proper house-selection flow.
@MainActor
public final class MentatScene: SKScene {
    public static let nativeSize = MainMenuScene.nativeSize

    public weak var coordinator: SceneCoordinator?
    private let assets: AssetLoader

    public init(assets: AssetLoader) {
        self.assets = assets
        super.init(size: Self.nativeSize)
        scaleMode = .aspectFit
        backgroundColor = .black
        anchorPoint = .zero
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func didMove(to view: SKView) {
        removeAllChildren()
        // House-specific backdrop — pick the one we can actually load.
        for name in ["MENTATA.CPS", "MENTATO.CPS", "MENTATH.CPS", "MENTATM.CPS"] {
            guard let image = try? assets.loadCps(named: name) else { continue }
            let texture = SKTexture(cgImage: image)
            texture.filteringMode = .nearest
            let sprite = SKSpriteNode(texture: texture)
            sprite.anchorPoint = .zero
            sprite.position = .zero
            sprite.size = Self.nativeSize
            sprite.colorBlendFactor = 0.15
            sprite.color = .blue
            addChild(sprite)
            break
        }
        let caption = SKLabelNode(text: "Mentat briefing — click to return")
        caption.fontColor = .white
        caption.fontSize = 10
        caption.position = CGPoint(x: Self.nativeSize.width / 2, y: 12)
        caption.horizontalAlignmentMode = .center
        addChild(caption)
    }

    public override func mouseDown(with event: NSEvent) {
        coordinator?.advance(from: self)
    }
}
