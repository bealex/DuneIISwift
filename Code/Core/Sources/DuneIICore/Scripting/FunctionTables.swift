import Foundation

extension Scripting.Functions {
    /// 64-slot unit function table matching OpenDUNE's `g_scriptFunctionsUnit`
    /// in `src/script/script.c:64`. Any slot we haven't ported yet is left
    /// nil — scripts that hit an unported slot halt on that opcode.
    ///
    /// `source` is shared with the structure table so both categories draw
    /// from the same RNG stream (mirrors OpenDUNE's one-global-LCG model).
    public static func unitTable(host: Scripting.Host, source: Scripting.RandomSource) -> [Scripting.VM.Function?] {
        // Default every slot to `noOperation` (return 0, no side-effects)
        // so scripts that hit an unported slot keep running rather than
        // halting permanently. Slots that ARE ported overwrite the
        // default below. Matches OpenDUNE's willingness to warn-and-
        // continue on an unknown function in non-strict builds; without
        // this, UNIT.EMC's `ACTION_GUARD` entry halts on the first
        // unported opcode and the unit never reaches `IdleAction`.
        var table = [Scripting.VM.Function?](
            repeating: Scripting.Functions.noOperation,
            count: 64
        )

        // 0x00 — Script_Unit_GetInfo
        table[0x00] = Scripting.Functions.makeGetInfoUnit(host: host)
        // 0x01 — Script_Unit_SetAction
        table[0x01] = Scripting.Functions.makeSetActionUnit(host: host)
        // 0x02 — Script_General_DisplayText
        table[0x02] = Scripting.Functions.makeDisplayText(host: host)
        // 0x03 — Script_General_GetDistanceToTile
        table[0x03] = Scripting.Functions.makeGetDistanceToTile(host: host)
        // 0x04 — Script_Unit_StartAnimation (not ported; halts)
        // 0x05 — Script_Unit_SetDestination (naive — no pathfinding yet)
        table[0x05] = Scripting.Functions.makeSetDestinationUnit(host: host)
        // 0x06 — Script_General_GetOrientation (encoded-index variant)
        table[0x06] = Scripting.Functions.makeGetOrientation(host: host)
        // 0x07 — Script_Unit_SetOrientation
        table[0x07] = Scripting.Functions.makeSetOrientationUnit(host: host)
        // 0x08 — Script_Unit_Fire
        table[0x08] = Scripting.Functions.makeFireUnit(host: host)
        // 0x09 — Script_Unit_MCVDeploy (not ported; structure creation)
        // 0x0A — Script_Unit_SetActionDefault
        table[0x0A] = Scripting.Functions.makeSetActionDefaultUnit(host: host)
        // 0x0B — Script_Unit_Blink
        table[0x0B] = Scripting.Functions.makeBlinkUnit(host: host)
        // 0x0C — Script_Unit_CalculateRoute
        table[0x0C] = Scripting.Functions.makeCalculateRouteUnit(host: host)
        // 0x0D — Script_General_IsEnemy
        table[0x0D] = Scripting.Functions.makeIsEnemy(host: host)
        // 0x0E — Script_Unit_ExplosionSingle
        table[0x0E] = Scripting.Functions.makeExplosionSingleUnit(host: host)
        // 0x0F — Script_Unit_Die
        table[0x0F] = Scripting.Functions.makeDieUnit(host: host)
        // 0x10 — Script_General_Delay
        table[0x10] = Scripting.Functions.delay
        // 0x11 — Script_General_IsFriendly
        table[0x11] = Scripting.Functions.makeIsFriendly(host: host)
        // 0x12 — Script_Unit_ExplosionMultiple
        table[0x12] = Scripting.Functions.makeExplosionMultipleUnit(source: source, host: host)
        // 0x13 — Script_Unit_SetSprite
        table[0x13] = Scripting.Functions.makeSetSpriteUnit(host: host)
        // 0x14 — Script_Unit_TransportDeliver (not ported; transport logic)
        // 0x15 — NoOp
        table[0x15] = Scripting.Functions.noOperation
        // 0x16 — Script_Unit_MoveToTarget
        table[0x16] = Scripting.Functions.makeMoveToTargetUnit(host: host)
        // 0x17 — Script_General_RandomRange
        table[0x17] = Scripting.Functions.makeRandomRange(source: source)
        // 0x18 — Script_General_FindIdle
        table[0x18] = Scripting.Functions.makeFindIdle(host: host)
        // 0x19 — Script_Unit_SetDestinationDirect
        table[0x19] = Scripting.Functions.makeSetDestinationDirectUnit(host: host)
        // 0x1A — Script_Unit_Stop
        table[0x1A] = Scripting.Functions.makeStopUnit(host: host)
        // 0x1B — Script_Unit_SetSpeed
        table[0x1B] = Scripting.Functions.makeSetSpeedUnit(host: host)
        // 0x1C — Script_Unit_FindBestTarget
        table[0x1C] = Scripting.Functions.makeFindBestTargetUnit(host: host)
        // 0x1D — Script_Unit_GetTargetPriority
        table[0x1D] = Scripting.Functions.makeGetTargetPriorityUnit(host: host)
        // 0x1E — Script_Unit_MoveToStructure (not ported; linking)
        // 0x1F — Script_Unit_IsInTransport
        table[0x1F] = Scripting.Functions.makeIsInTransportUnit(host: host)
        // 0x20 — Script_Unit_GetAmount
        table[0x20] = Scripting.Functions.makeGetAmountUnit(host: host)
        // 0x21 — Script_Unit_RandomSoldier (not ported; unit creation)
        // 0x22 — Script_Unit_Pickup (not ported; transport)
        // 0x23 — Script_Unit_CallUnitByType (not ported)
        // 0x24 — Script_Unit_Unknown2552 (not ported)
        // 0x25 — Script_Unit_FindStructure (not ported)
        // 0x26 — Script_General_VoicePlay
        table[0x26] = Scripting.Functions.makeVoicePlay(host: host)
        // 0x27 — Script_Unit_DisplayDestroyedText (not ported; GUI)
        // 0x28 — Script_Unit_RemoveFog (not ported; fog)
        // 0x29 — Script_General_SearchSpice (not ported; map search)
        // 0x2A — Script_Unit_Harvest (not ported; economy)
        // 0x2B — NoOp
        table[0x2B] = Scripting.Functions.noOperation
        // 0x2C — Script_General_GetLinkedUnitType
        table[0x2C] = Scripting.Functions.makeGetLinkedUnitType(host: host)
        // 0x2D — Script_General_GetIndexType
        table[0x2D] = Scripting.Functions.makeGetIndexType(host: host)
        // 0x2E — Script_General_DecodeIndex
        table[0x2E] = Scripting.Functions.makeDecodeIndex(host: host)
        // 0x2F — Script_Unit_IsValidDestination (not ported)
        // 0x30 — Script_Unit_GetRandomTile (not ported; Tile_MoveByRandom)
        // 0x31 — Script_Unit_IdleAction
        table[0x31] = Scripting.Functions.makeIdleActionUnit(source: source, host: host)
        // 0x32 — Script_General_UnitCount
        table[0x32] = Scripting.Functions.makeUnitCount(host: host)
        // 0x33 — Script_Unit_GoToClosestStructure (not ported)
        // 0x34 / 0x35 — NoOp
        table[0x34] = Scripting.Functions.noOperation
        table[0x35] = Scripting.Functions.noOperation
        // 0x36 — Script_Unit_Sandworm_GetBestTarget
        table[0x36] = Scripting.Functions.makeSandwormGetBestTargetUnit(host: host)
        // 0x37 — Script_Unit_Unknown2BD5 (not ported)
        // 0x38 — Script_General_GetOrientation (same as 0x06)
        table[0x38] = Scripting.Functions.makeGetOrientation(host: host)
        // 0x39 — NoOp
        table[0x39] = Scripting.Functions.noOperation
        // 0x3A — Script_Unit_SetTarget
        table[0x3A] = Scripting.Functions.makeSetTargetUnit(host: host)
        // 0x3B — Script_General_Unknown0288 (not ported; corner case)
        // 0x3C — Script_General_DelayRandom
        table[0x3C] = Scripting.Functions.makeDelayRandom(source: source)
        // 0x3D — Script_Unit_Rotate (not ported; needs orientation-speed state)
        // 0x3E — Script_General_GetDistanceToObject
        table[0x3E] = Scripting.Functions.makeGetDistanceToObject(host: host)
        // 0x3F — NoOp
        table[0x3F] = Scripting.Functions.noOperation

        return table
    }

    /// 64-slot structure function table matching `g_scriptFunctionsStructure`
    /// in `src/script/script.c:33`.
    public static func structureTable(host: Scripting.Host, source: Scripting.RandomSource) -> [Scripting.VM.Function?] {
        // Same NoOp default as `unitTable` — unwired slots degrade to
        // return-0 so BUILD.EMC can run past unported opcodes.
        var table = [Scripting.VM.Function?](
            repeating: Scripting.Functions.noOperation,
            count: 64
        )

        // 0x00 — Script_General_Delay
        table[0x00] = Scripting.Functions.delay
        // 0x01 — NoOp
        table[0x01] = Scripting.Functions.noOperation
        // 0x02 — Script_Structure_Unknown0A81 (not ported; linking edge case)
        // 0x03 — Script_Structure_FindUnitByType (not ported; carryall)
        // 0x04 — Script_Structure_SetState
        table[0x04] = Scripting.Functions.makeSetStateStructure(host: host)
        // 0x05 — Script_General_DisplayText
        table[0x05] = Scripting.Functions.makeDisplayText(host: host)
        // 0x06 — Script_Structure_Unknown11B9 (not ported)
        // 0x07 — Script_Structure_Unknown0C5A (not ported; carryall release)
        // 0x08 — Script_Structure_FindTargetUnit
        table[0x08] = Scripting.Functions.makeFindTargetUnitStructure(host: host)
        // 0x09 — Script_Structure_RotateTurret
        table[0x09] = Scripting.Functions.makeRotateTurretStructure(host: host)
        // 0x0A — Script_Structure_GetDirection
        table[0x0A] = Scripting.Functions.makeGetDirectionStructure(host: host)
        // 0x0B — Script_Structure_Fire
        table[0x0B] = Scripting.Functions.makeFireStructure(host: host)
        // 0x0C — NoOp
        table[0x0C] = Scripting.Functions.noOperation
        // 0x0D — Script_Structure_GetState
        table[0x0D] = Scripting.Functions.makeGetStateStructure(host: host)
        // 0x0E — Script_Structure_VoicePlay (use the generic VoicePlay — ignores
        //        the "play-only-for-local-player" branch which requires
        //        g_playerHouseID)
        table[0x0E] = Scripting.Functions.makeVoicePlay(host: host)
        // 0x0F — Script_Structure_RemoveFogAroundTile (not ported; fog)
        // 0x10-0x14 — NoOp
        table[0x10] = Scripting.Functions.noOperation
        table[0x11] = Scripting.Functions.noOperation
        table[0x12] = Scripting.Functions.noOperation
        table[0x13] = Scripting.Functions.noOperation
        table[0x14] = Scripting.Functions.noOperation
        // 0x15 — Script_Structure_RefineSpice (not ported; economy)
        // 0x16 — Script_Structure_Explode (not ported; explosion pool)
        // 0x17 — Script_Structure_Destroy
        table[0x17] = Scripting.Functions.makeDestroyStructure(host: host)
        // 0x18 — NoOp
        table[0x18] = Scripting.Functions.noOperation

        _ = source  // unused for now; kept in signature for symmetry with unitTable
        return table
    }

    /// 64-slot team function table matching `g_scriptFunctionsTeam`
    /// in `src/script/script.c:134`. Only 15 of the 64 slots are
    /// meaningful in vanilla Dune II; the rest are slot 0x0E
    /// (`Script_General_NoOperation`) or unused tails.
    public static func teamTable(host: Scripting.Host, source: Scripting.RandomSource) -> [Scripting.VM.Function?] {
        // Same NoOp default as `unitTable` — unwired slots degrade to
        // return-0 so TEAM.EMC can run past unported opcodes.
        var table = [Scripting.VM.Function?](
            repeating: Scripting.Functions.noOperation,
            count: 64
        )

        // 0x00 — Script_General_Delay
        table[0x00] = Scripting.Functions.delay
        // 0x01 — Script_Team_DisplayText
        table[0x01] = Scripting.Functions.makeDisplayTextTeam(host: host)
        // 0x02 — Script_Team_GetMembers
        table[0x02] = Scripting.Functions.makeGetMembersTeam(host: host)
        // 0x03 — Script_Team_AddClosestUnit
        table[0x03] = Scripting.Functions.makeAddClosestUnitTeam(host: host)
        // 0x04 — Script_Team_GetAverageDistance (not ported; complex pool walk)
        // 0x05 — Script_Team_Unknown0543 (not ported)
        // 0x06 — Script_Team_FindBestTarget
        table[0x06] = Scripting.Functions.makeFindBestTargetTeam(host: host)
        // 0x07 — Script_Team_Unknown0788 (not ported; Unit_SetAction chain)
        // 0x08 — Script_Team_Load
        table[0x08] = Scripting.Functions.makeLoadTeam(host: host)
        // 0x09 — Script_Team_Load2
        table[0x09] = Scripting.Functions.makeLoad2Team(host: host)
        // 0x0A — Script_General_DelayRandom
        table[0x0A] = Scripting.Functions.makeDelayRandom(source: source)
        // 0x0B — Script_General_DisplayModalMessage (not ported; GUI)
        // 0x0C — Script_Team_GetVariable6
        table[0x0C] = Scripting.Functions.makeGetVariable6Team(host: host)
        // 0x0D — Script_Team_GetTarget
        table[0x0D] = Scripting.Functions.makeGetTargetTeam(host: host)
        // 0x0E — NoOp
        table[0x0E] = Scripting.Functions.noOperation

        return table
    }
}
