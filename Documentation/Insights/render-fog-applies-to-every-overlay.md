# Fog of war must be re-applied in *every* presentation layer, not just the terrain

**Finding:** the `showFog` / `isUnveiled` mask is not a single render step — it has to be applied independently in **every** layer that draws world content. There is no shared "is this hidden?" gate the layers inherit; each one tests fog itself. Adding a new visual that draws units/structures/effects means adding the fog check to it, or it leaks information (or, worse, distorts) under fog.

**Why it matters:** fog correctness fragmented across the codebase and bit us twice in one session (2026-06-01). The layers that each carry their own fog handling:
- **Main terrain + sprites** — `FrameComposer.terrainBuffer(showFog:)` blacks veiled cells; `FrameComposer.sprites(showFog:)` / `isHiddenByFog` drops units/effects on veiled tiles (the `viewport.c` per-entity `!isUnveiled` mask).
- **Minimap base** — `Minimap.baseImage(showFog:)` must black out `!isUnveiled` cells itself.
- **Minimap blips** — `MinimapView` must skip dots via `FrameComposer.isHiddenByFog`.
- **Sandworm shimmer** — `ShimmerEffect` had to gain a `veiled` predicate so the blur neither shows over fog nor drags the dithered fog *edge* into the worm's silhouette (it samples terrain displaced to the right, so a worm at a fog boundary pulls veil pixels in).

**How to apply:** when you add any host overlay or effect that draws world content (a new HUD layer, an effect, a minimap element), thread `showFog` through it and apply the same per-tile `isUnveiled` test (`FrameComposer.isHiddenByFog` for entity positions; black/skip for terrain cells). Gate it on the same `model.showFog` toggle so all layers agree. Keep the fog-off path byte-identical (pass `nil`/`false`) so render goldens — which run fog-off — stay green; verify the fog-on behaviour with a targeted unit test (e.g. `ShimmerEffectTests.fogSuppression`). Related: `world-fog-veil-overlay-off-by-one`, `render-tile-overlay-transparency`.
