# VOC (Creative Voice File)

Sound effects. Reference: OpenDUNE's DSP block parse (`src/audio/dsp_sdl.c:131`) + the standard VOC block structure. Port: `Code/Frameworks/DuneIIFormats/Formats/Voc/Voc.swift`. Tests: `Code/Tests/FormatsTests/VocTests.swift`.

## Layout

A 26-byte header whose uint16 at offset 20 points to the first data block. Blocks are `[type u8][24-bit LE length][body]`; type `0x00` terminates. Type `0x01` (sound data) body = `[frequency divisor u8][codec u8][unsigned 8-bit mono PCM…]`; type `0x02` is raw PCM continuation. Sample rate = `1_000_000 / (256 - frequencyDivisor)`. (OpenDUNE only reads the first 0x01 block; we walk all blocks and concatenate PCM, which is harmless for Dune II's single-block effects.) Audio is otherwise postponed to Phase 7.
