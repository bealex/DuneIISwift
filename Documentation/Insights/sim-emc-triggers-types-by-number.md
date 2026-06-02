# EMC scripts trigger explosion/unit types by raw NUMBER — grepping the C enum name finds nothing

**Finding:** the `.EMC` bytecode references explosion (and unit) types as **numeric literals**, not the OpenDUNE C enum names. So `EXPLOSION_ORNITHOPTER_CRASH = 16` is *triggered* by `Unit_ExplosionSingle(16)` inside the ornithopter's UNIT.EMC death branch — and `grep EXPLOSION_ORNITHOPTER_CRASH src/*.c` finds **only** the enum + the table row, never the trigger, making it look like dead code. It is not.

**Why it matters:** I nearly concluded "the crashed-ornithopter wreck is dead code in 1.07, don't implement it" — the opposite of the truth. The wreck *is* part of 1.07; it just wasn't showing because the explosion's `EXPLOSION_SET_ANIMATION` command (→ `g_table_animation_map`, the "Flying-Machine Crash" icon group) was an unported SEAM. Reasoning from a C-name grep alone gives a false negative for anything an EMC script drives.

**Second trap:** disassemble the *right* unit. `UnitType.ornithopter = 1`, not 11 — `Scripts/emc.sh unit 11` shows a different unit's script. Confirm the type's `rawValue` (DuneIIContracts/UnitType.swift) before reading its EMC.

**Evidence:** ornithopter death `Scripts/emc.sh unit 1` (`Push2 16; Function 14 Unit_ExplosionSingle`); our `UnitImpact.explosionSingle` → `mapMakeExplosion(type: 16)`; the crash explosion's `SET_ANIMATION 0` wired in `GameState+Explosion.swift` → `animationStart(kind: .map, iconGroup: 3)`; `g_table_animation_map[0]` in `Model/Animation.swift`. Tests: `TrackAndCrashTests.ornithopterCrash` (wreck overlay appears) + `.sandTracks`. OpenDUNE `src/table/explosion.c:322` (`s_explosion16`), `src/explosion.c:175` (`Explosion_Func_SetAnimation`), `src/table/animation.c` (`g_table_animation_map`).

**How to apply:** to check whether an OpenDUNE feature is reachable, don't just grep the C enum name — disassemble the EMC script that would drive it (`Scripts/emc.sh`) and look for the numeric literal as a native's argument. An "unreferenced" enum/table entry is often live through a script.
