import DuneIIContracts

/// The `sim → render` consumer seam. A renderer is handed one `FrameInfo` per drawn frame and turns it
/// into pixels; it never reads simulation internals. Kept tiny so panels/renderers stay mockable leaves
/// and can be driven from a recorded `FrameInfo`.
public protocol Renderer {
    mutating func render(_ frame: FrameInfo)
}

/// The no-op renderer for the headless / test / oracle path. Draws nothing, but records the last frame
/// it was handed so a headless test can assert the simulation drove a frame through the seam.
public struct NullRenderer: Renderer {
    public private(set) var lastFrame: FrameInfo?
    public init() {}
    public mutating func render(_ frame: FrameInfo) { lastFrame = frame }
}
