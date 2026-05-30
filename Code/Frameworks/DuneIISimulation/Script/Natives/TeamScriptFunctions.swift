import DuneIIWorld

/// The `Script_Team_*` op-14 natives that read the running team's state (`g_scriptCurrentTeam`, here
/// `state.teams[slot]`). Plain explicit-param functions — no stack peeking in the logic — each a literal
/// transcription of OpenDUNE `src/script/team.c`. The "brain" natives (recruit / target / order) live in
/// follow-up slices; this struct holds the getters brought up with `GameLoop_Team`.
struct TeamScriptFunctions: Sendable {
    /// `Script_Team_GetMembers` (`team.c:28`): the team's current member count.
    func getMembers(slot: Int, in state: GameState) -> UInt16 { state.teams[slot].members }

    /// `Script_Team_GetVariable6` (`team.c:42`): the team's `minMembers` (OpenDUNE's `variable_06`).
    func getVariable6(slot: Int, in state: GameState) -> UInt16 { state.teams[slot].minMembers }

    /// `Script_Team_GetTarget` (`team.c:56`): the team's encoded target.
    func getTarget(slot: Int, in state: GameState) -> UInt16 { state.teams[slot].target }
}
