import Foundation
import AppKit
import SpriteKit
import DuneIICore

/// First scene after bootstrap: displays `MENTATA.CPS` at native 320×200
/// and forwards "tap to continue" to the scene coordinator.
@MainActor
public final class MainMenuScene: SKScene {
    public static let nativeSize = CGSize(width: 320, height: 200)

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
        do {
            let cg = try assets.loadCps(named: "MENTATA.CPS")
            let texture = SKTexture(cgImage: cg)
            texture.filteringMode = .nearest
            let sprite = SKSpriteNode(texture: texture)
            sprite.anchorPoint = .zero
            sprite.position = .zero
            sprite.size = Self.nativeSize
            addChild(sprite)
        } catch {
            showFallback(message: "MENTATA.CPS: \(error)")
        }
    }

    public override func mouseDown(with event: NSEvent) {
        coordinator?.advance(from: self)
    }

    private func showFallback(message: String) {
        let label = SKLabelNode(text: message)
        label.fontColor = .red
        label.fontSize = 10
        label.position = CGPoint(x: Self.nativeSize.width / 2, y: Self.nativeSize.height / 2)
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        addChild(label)
    }
}
