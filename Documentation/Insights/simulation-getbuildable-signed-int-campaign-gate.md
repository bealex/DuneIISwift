# `Structure_GetBuildable` campaign gate is signed, not unsigned

**Category:** `simulation`

## The fact

OpenDUNE's campaign gate in `Structure_GetBuildable` (`src/structure.c`) reads:

```c
uint16 availableCampaign = ...;
if (g_campaignID >= availableCampaign - 1 && ...)
```

Both `g_campaignID` and `availableCampaign` are `uint16`. In C, the binary `- 1` promotes them to `int` (signed) before subtracting. So when `availableCampaign == 0` (ROCKET_TURRET), the comparison is `g_campaignID >= -1` — which is *always* true for any non-negative campaign.

ROCKET_TURRET's `availableCampaign = 0` therefore means "available from campaign 0 onward", not "never available" (as a naïve unsigned-wrap port would imply). The thing that actually keeps ROCKET_TURRET locked at player yards is `upgradeLevelRequired = 2`, not the campaign gate.

## Why it matters

A Swift port using `availableCampaign &- 1` (wrapping unsigned subtraction) computes `UInt16(0) &- 1 == 0xFFFF`, and the gate becomes `campaignID >= 0xFFFF` — always false. This silently gates ROCKET_TURRET out of every yard's buildable set, even at upgradeLevel 2, even in the late campaign. Parity tests against OpenDUNE saves would pass for most structures (all with `availableCampaign >= 1`) and fail only for ROCKET_TURRET — a narrow failure mode that's easy to miss without dedicated tests.

## How to apply

- The Swift port uses `Int(availableCampaign) - 1` and compares against `Int(campaignID)`. This reproduces C's signed int promotion exactly.
- The buildable-tests suite pins this: `ROCKET_TURRET campaign gate passes at c=0 (signed -1 threshold), so the prereq gate is what keeps it locked` in `StructureBuildableTests.swift`.

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Simulation/Structures.swift` — the comment on `buildableStructuresFromYard` + the Int-cast in the gate.
- `Code/Core/Tests/DuneIICoreTests/StructureBuildableTests.swift` — `rocketTurretCampaignZeroSignedPromotion`.

## Where it lives in the reference

OpenDUNE `src/structure.c` — `Structure_GetBuildable`, the CONSTRUCTION_YARD case.
