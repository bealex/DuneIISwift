# Toggling a cell between the static layer and an overlay node jitters at zoom

**Finding:** the renderer draws a terrain cell two different ways — as part of the one map-sized static background texture, or (when it animates) as its own 16×16 overlay `SKSpriteNode` on top. The two paths do **not** rasterize to identical device pixels under a fractional camera at zoom (nearest-neighbour sampling rounds the big texture's interior differently from a small node centred on the cell). So a cell that flips back and forth between the two paths — e.g. an animating structure whose cycle returns to the baseline appearance, where the old code *removed* the overlay node — visibly jumps by a pixel frame-to-frame (the construction-yard corner at 2× zoom).

**Why it matters:** it reads as a "non-stable position calculation" bug, but both positions are individually correct integers — the instability is purely the two sampling paths disagreeing sub-pixel. Chasing it as a coordinate-math error is a dead end.

**Evidence:** `Code/Frameworks/DuneIIRenderer/SpriteKitRenderer.swift` — `updateDynamicTerrain` now **latches**: once a cell has ever been dynamic it keeps its overlay node (re-textured to the current tile) instead of handing the cell back to the static background. Costs a few extra persistent nodes; buys temporal stability.

**How to apply:** never let a visible cell oscillate between the static-background render and a per-cell overlay-node render. Latch it to one path. More generally, when one thing can be drawn by two pipelines, keep it on a single pipeline for its whole visible life rather than switching per frame. Related: [[render-incremental-appearance-key]], [[render-snapshot-backing-scale]].
