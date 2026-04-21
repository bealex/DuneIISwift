# Scale 6-bit VGA to 8-bit with bit replication, not `<< 2`

- **Discovered**: 2026-04-19 · `Code/Core/Sources/DuneIICore/Formats/Palette/Palette.swift`
- **Category**: render
- **Applies to**: `Formats.Palette`, every PNG emitted by `AssetExport`.

## The fact

VGA DAC registers are 6 bits wide; palette bytes are `0…63`. The naïve scaling `rgb8 = rgb6 << 2` maps 63 → 252, losing the top three levels. The correct scaling is:

```
rgb8 = (rgb6 << 2) | (rgb6 >> 4)
```

so `63 → 255`, `0 → 0`, and intermediate values distribute evenly across the full 8-bit range. This matches DOSBox's DAC emulation.

## Why it matters

Using `<< 2` produces slightly dim, slightly desaturated output. Screenshots won't match the OpenDUNE reference, and the CPS title cards look subtly off.

## Where it lives in our code

- `Formats.Palette.Color.rgba8` — the scaling.
- `AssetExport.Extractors.extractPalette` and `PalettedImage.render` both apply it.
- `Tests/DuneIICoreTests/PaletteTests.swift::bitReplicationScaling` nails down the `63 → 255` / `0 → 0` boundary.

## Where it lives in the reference

DOSBox `src/hardware/vga_dac.cpp` uses the same replication. OpenDUNE inherits from the SDL palette set.
