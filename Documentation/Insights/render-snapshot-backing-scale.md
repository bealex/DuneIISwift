# SKView.texture(from:) rasterizes at the host backing scale, not the logical size

**Finding:** `SKView.texture(from: scene).cgImage()` returns an image at the host's **backing scale** (2× on a Retina display), so the `CGImage` is larger than the scene's logical `size` (a 1024×1024 logical world rasterizes to a 2048×2048 image). A `CGImage.cropping(to:)` rect is in **pixels**, so cropping with a rect computed in logical points grabs the wrong region at half size.

**Why it matters:** `SpriteKitRenderer.snapshot(_:crop:)` looked correct on the un-cropped path (it returns the whole native image) but every *cropped* capture was wrong — `rendercap --rect` and the first render-golden references captured tiles ~14–22 when asked for 28–44, at 256px instead of 512px. The bug is invisible until you check the pixels against known content.

**Evidence:** `Frameworks/DuneIIRenderer/SpriteKitRenderer.swift` `snapshot(_:crop:)` — scales the crop by `CGFloat(full.width) / side` (measured ratio) before `cropping(to:)`. Verified by `RenderGoldenTests` (the crop must contain the SCENA001 Const Yard at tile (30,25); `gen-render-goldens.sh` records, then a fresh diff capture matches byte-for-byte).

**How to apply:** when cropping a `texture(from:)` capture, never assume the image is the scene's logical size — measure the actual pixel/point ratio (`image.width / logicalSide`) and scale the crop rect to pixels. Corollary: references captured this way are at the host backing scale, so a snapshot golden is a same-host regression guard, not a cross-GPU oracle.
