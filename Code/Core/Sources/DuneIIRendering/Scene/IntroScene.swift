import Foundation
import AppKit
import SpriteKit
import DuneIICore

/// Plays `INTRO.WSA` (Westwood logo + Virgin logo + title crawl in the
/// retail release) as a swap-texture animation. A user click skips to
/// the main menu.
///
/// Frame rate: WSA files don't carry an explicit fps — vanilla Dune II
/// runs them at `70/5 = 14 fps` via the game's 70 Hz timer. We use
/// 15 fps as a close approximation; the visual difference is within
/// one-frame jitter on any modern display.
@MainActor
public final class IntroScene: SKScene {
    public static let defaultFPS: Double = 15
    public weak var coordinator: SceneCoordinator?

    private let assets: AssetLoader
    private let wsaName: String
    private var textures: [SKTexture] = []
    private var sprite: SKSpriteNode?
    private var currentFrame: Int = 0
    private var accumulated: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0
    private let framePeriod: TimeInterval

    public init(assets: AssetLoader, wsaName: String = "INTRO.WSA", fps: Double = IntroScene.defaultFPS) {
        self.assets = assets
        self.wsaName = wsaName
        self.framePeriod = 1.0 / fps
        super.init(size: CGSize(width: 320, height: 200))
        scaleMode = .aspectFit
        backgroundColor = .black
        anchorPoint = .zero
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func didMove(to view: SKView) {
        removeAllChildren()
        do {
            let wsa = try assets.loadWsa(named: wsaName)
            guard !wsa.frames.isEmpty else {
                skipToMenu()
                return
            }
            textures = wsa.frames.map {
                let t = SKTexture(cgImage: $0)
                t.filteringMode = .nearest
                return t
            }
            let native = CGSize(width: wsa.width, height: wsa.height)
            size = native
            let s = SKSpriteNode(texture: textures[0])
            s.anchorPoint = .zero
            s.size = native
            addChild(s)
            sprite = s
        } catch {
            skipToMenu()
        }
    }

    public override func update(_ currentTime: TimeInterval) {
        guard !textures.isEmpty else { return }
        if lastUpdate == 0 {
            lastUpdate = currentTime
            return
        }
        accumulated += currentTime - lastUpdate
        lastUpdate = currentTime
        while accumulated >= framePeriod {
            accumulated -= framePeriod
            currentFrame += 1
            if currentFrame >= textures.count {
                skipToMenu()
                return
            }
            sprite?.texture = textures[currentFrame]
        }
    }

    public override func mouseDown(with event: NSEvent) {
        skipToMenu()
    }

    private func skipToMenu() {
        coordinator?.route(to: .mainMenu)
    }
}
