# AssetExport — module context

Glue layer between `DuneIICore`'s pure-Swift format decoders and on-disk output. Adds ImageIO / CoreGraphics for PNG writes and simple WAV / JSON writers. Everything in here is reachable only from the `assetgen` CLI — the rendering layer uses `CGImageFactory` inside `DuneIIRendering` instead.

## Layout

- `Extractors.swift` — per-format extractors that walk every PAK entry, decode via `DuneIICore`, and emit PNG / WAV / JSON / raw bytes to the output tree. Also defines `ExtractLogger` (info / detail / warn) and `ExtractContext` (output root + fallback palette + logger).
- `Writers.swift` — `PNGWriter`, `WavWriter`, `JSONWriter`. All three take fully-decoded buffers — callers own palette lookup and transparency choice.

## Conventions

- One public enum per writer; no stored state. Pure write-to-disk functions.
- Every writer is round-trippable by the corresponding decoder in `DuneIICore`. Add a test to `Core/Tests/DuneIICoreTests/AssetExportTests.swift` when you add a writer.
- Extractors skip silently on per-entry errors and log via `ExtractLogger.warn` — a bad entry must not abort the whole extraction run.
- Do not call `AssetExport` from `DuneIIRendering` or `duneii`. The rendering layer has its own image pipeline (`CGImageFactory`) and shouldn't write to disk at runtime.

## Key entry points

- `Extractors.extractAll(archive:context:)` — top-level "walk every PAK entry, dispatch by format" routine, called from `assetgen`.
- `PNGWriter.write(rgba:width:height:to:)` — palette-resolved RGBA → PNG.
- `WavWriter.write(samples:sampleRate:to:)` — PCM16 → WAV.
- `JSONWriter.write(_:to:)` — generic `Encodable` → JSON.

## Running

Exercised end-to-end via `swift run assetgen` — the CLI in the `assetgen` target.
