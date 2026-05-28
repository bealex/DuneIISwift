# DuneIIExport

Asset writers for verification and tooling: `PngWriter` (8-bit palette-indexed pixels → PNG, via ImageIO/CoreGraphics) and `WavWriter` (unsigned 8-bit PCM → RIFF/WAVE, pure Foundation). Depends on `DuneIIFormats` (for `Palette`).

This is a tooling/writer library used by `assetgen` to export decoded assets to viewable PNG / playable WAV so conversion correctness can be checked by eye/ear. It imports system frameworks (CoreGraphics, ImageIO) but is **not** a presentation leaf — it is offline export, not the runtime renderer (the runtime renderer is `DuneIIRenderer`, which consumes `FrameInfo`).

8-bit WAV PCM is unsigned (0x80 = silence), matching VOC, so samples pass through verbatim. PNG uses `transparentIndex` to render sprite index 0 as transparent.
