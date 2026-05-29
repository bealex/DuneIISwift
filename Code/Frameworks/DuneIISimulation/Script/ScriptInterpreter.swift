import DuneIIWorld

/// The EMC bytecode interpreter — a faithful port of OpenDUNE's `Script_Run` + the stack ops + the
/// load/reset helpers (`src/script/script.c`). Replaceable like the other primitives (the parity
/// harness wants an instrumented, opcode-tracing variant), so `Simulation` holds an injected instance.
///
/// `run` executes **one** opcode (as `Script_Run` does); the per-tick driver loops it up to
/// `SCRIPT_UNIT_OPCODES_PER_TICK` (50) times. Op-14 (FUNCTION) dispatch is delegated to a closure so
/// the core needs none of the per-category native tables (which read `GameState` + the current object);
/// the closure returns the function's value, or `nil` for an unknown function (→ run returns `false`,
/// matching OpenDUNE, without nulling the PC).
public protocol ScriptInterpreter: Sendable {
    /// `Script_IsLoaded`: a script is active iff its PC isn't the NULL sentinel.
    func isLoaded(_ engine: ScriptEngine) -> Bool

    /// `Script_Load`: reset, then point the PC at the type's entry offset.
    func load(_ engine: inout ScriptEngine, info: ScriptInfo, typeID: Int)

    /// `Script_LoadAsSubroutine`: if loaded and not already a subroutine, push the return location +
    /// return value and jump to the type's entry offset.
    func loadAsSubroutine(_ engine: inout ScriptEngine, info: ScriptInfo, typeID: Int)

    /// `Script_Run`: execute one opcode. Returns `false` on a scripting error or when not loaded.
    func run(_ engine: inout ScriptEngine, info: ScriptInfo,
             callFunction: (Int, inout ScriptEngine) -> UInt16?) -> Bool
}

public struct DefaultScriptInterpreter: ScriptInterpreter {
    public init() {}

    public func isLoaded(_ engine: ScriptEngine) -> Bool {
        engine.scriptPC != ScriptEngine.scriptNull
    }

    public func load(_ engine: inout ScriptEngine, info: ScriptInfo, typeID: Int) {
        engine.reset()
        engine.scriptPC = info.offsets[typeID]
    }

    public func loadAsSubroutine(_ engine: inout ScriptEngine, info: ScriptInfo, typeID: Int) {
        if !isLoaded(engine) { return }
        if engine.isSubroutine != 0 { return }
        engine.isSubroutine = 1
        push(&engine, engine.scriptPC)        // the return location (current PC, an offset from start)
        push(&engine, engine.returnValue)
        engine.scriptPC = info.offsets[typeID]
    }

    // MARK: - Stack (fills from the end; over/underflow sets the NULL-PC error state)

    private func push(_ s: inout ScriptEngine, _ value: UInt16) {
        if s.stackPointer == 0 { s.scriptPC = ScriptEngine.scriptNull; return }
        s.stackPointer -= 1
        s.stack[Int(s.stackPointer)] = value
    }

    private func pop(_ s: inout ScriptEngine) -> UInt16 {
        if s.stackPointer >= 15 { s.scriptPC = ScriptEngine.scriptNull; return 0 }
        let v = s.stack[Int(s.stackPointer)]
        s.stackPointer += 1
        return v
    }

    /// `Script_Stack_Peek` (1-based): only a bounds check here — callers use it before popping. Sets the
    /// error state (NULL PC) if there aren't `position` entries on the stack.
    private func peek(_ s: inout ScriptEngine, _ position: Int) {
        if Int(s.stackPointer) >= 16 - position { s.scriptPC = ScriptEngine.scriptNull }
    }

    // MARK: - One opcode

    public func run(_ s: inout ScriptEngine, info: ScriptInfo,
                    callFunction: (Int, inout ScriptEngine) -> UInt16?) -> Bool {
        if !isLoaded(s) { return false }
        let program = info.program

        // OpenDUNE trusts the program bounds; we guard to fail cleanly on a malformed program.
        guard Int(s.scriptPC) < program.count else { s.scriptPC = ScriptEngine.scriptNull; return false }
        let current = program[Int(s.scriptPC)]
        s.scriptPC &+= 1

        var opcode = Int((current >> 8) & 0x1F)
        var parameter: UInt16 = 0

        if current & 0x8000 != 0 {
            opcode = 0                              // 13-bit GOTO
            parameter = current & 0x7FFF
        } else if current & 0x4000 != 0 {
            parameter = UInt16(bitPattern: Int16(Int8(bitPattern: UInt8(current & 0xFF))))  // sign-extend
        } else if current & 0x2000 != 0 {
            guard Int(s.scriptPC) < program.count else { s.scriptPC = ScriptEngine.scriptNull; return false }
            parameter = program[Int(s.scriptPC)]
            s.scriptPC &+= 1
        }

        let p = Int(parameter)

        switch opcode {
            case 0:  // JUMP
                s.scriptPC = parameter

            case 1:  // SETRETURNVALUE
                s.returnValue = parameter

            case 2:  // PUSH_RETURN_OR_LOCATION
                if parameter == 0 {
                    push(&s, s.returnValue)
                } else if parameter == 1 {
                    push(&s, s.scriptPC &+ 1)         // next location
                    push(&s, UInt16(s.framePointer))
                    s.framePointer = s.stackPointer &+ 2
                } else {
                    s.scriptPC = ScriptEngine.scriptNull; return false
                }

            case 3, 4:  // PUSH / PUSH2
                push(&s, parameter)

            case 5:  // PUSH_VARIABLE
                push(&s, s.variables[p])

            case 6:  // PUSH_LOCAL_VARIABLE
                let idx = Int(s.framePointer) - p - 2
                if idx < 0 || idx >= 15 { s.scriptPC = ScriptEngine.scriptNull; return false }
                push(&s, s.stack[idx])

            case 7:  // PUSH_PARAMETER
                let idx = Int(s.framePointer) + p - 1
                if idx < 0 || idx >= 15 { s.scriptPC = ScriptEngine.scriptNull; return false }
                push(&s, s.stack[idx])

            case 8:  // POP_RETURN_OR_LOCATION
                if parameter == 0 {
                    s.returnValue = pop(&s)
                } else if parameter == 1 {
                    peek(&s, 2); if !isLoaded(s) { return false }
                    s.framePointer = UInt8(truncatingIfNeeded: pop(&s))
                    s.scriptPC = pop(&s)
                } else {
                    s.scriptPC = ScriptEngine.scriptNull; return false
                }

            case 9:  // POP_VARIABLE
                s.variables[p] = pop(&s)

            case 10:  // POP_LOCAL_VARIABLE
                let idx = Int(s.framePointer) - p - 2
                if idx < 0 || idx >= 15 { s.scriptPC = ScriptEngine.scriptNull; return false }
                s.stack[idx] = pop(&s)

            case 11:  // POP_PARAMETER
                let idx = Int(s.framePointer) + p - 1
                if idx < 0 || idx >= 15 { s.scriptPC = ScriptEngine.scriptNull; return false }
                s.stack[idx] = pop(&s)

            case 12:  // STACK_REWIND
                s.stackPointer = s.stackPointer &+ UInt8(truncatingIfNeeded: parameter)

            case 13:  // STACK_FORWARD
                s.stackPointer = s.stackPointer &- UInt8(truncatingIfNeeded: parameter)

            case 14:  // FUNCTION
                guard let value = callFunction(p & 0xFF, &s) else { return false }  // unknown ⇒ false (PC kept)
                s.returnValue = value

            case 15:  // JUMP_NE
                peek(&s, 1); if !isLoaded(s) { return false }
                if pop(&s) != 0 { return true }
                s.scriptPC = parameter & 0x7FFF

            case 16:  // UNARY
                if parameter == 0 { push(&s, pop(&s) == 0 ? 1 : 0) }
                else if parameter == 1 { push(&s, 0 &- pop(&s)) }
                else if parameter == 2 { push(&s, ~pop(&s)) }
                else { s.scriptPC = ScriptEngine.scriptNull; return false }

            case 17:  // BINARY (signed 16-bit, wrapping)
                let right = Int16(bitPattern: pop(&s))
                let left = Int16(bitPattern: pop(&s))
                let result: Int16
                switch parameter {
                    case 0:  result = (left != 0 && right != 0) ? 1 : 0
                    case 1:  result = (left != 0 || right != 0) ? 1 : 0
                    case 2:  result = left == right ? 1 : 0
                    case 3:  result = left != right ? 1 : 0
                    case 4:  result = left <  right ? 1 : 0
                    case 5:  result = left <= right ? 1 : 0
                    case 6:  result = left >  right ? 1 : 0
                    case 7:  result = left >= right ? 1 : 0
                    case 8:  result = left &+ right
                    case 9:  result = left &- right
                    case 10: result = left &* right
                    case 11:
                        if right == 0 { s.scriptPC = ScriptEngine.scriptNull; return false }
                        result = left / right
                    case 12: result = left >> right
                    case 13: result = left << right
                    case 14: result = left & right
                    case 15: result = left | right
                    case 16:
                        if right == 0 { s.scriptPC = ScriptEngine.scriptNull; return false }
                        result = left % right
                    case 17: result = left ^ right
                    default: s.scriptPC = ScriptEngine.scriptNull; return false
                }
                push(&s, UInt16(bitPattern: result))

            case 18:  // RETURN
                peek(&s, 2); if !isLoaded(s) { return false }
                s.returnValue = pop(&s)
                s.scriptPC = pop(&s)
                s.isSubroutine = 0

            default:
                s.scriptPC = ScriptEngine.scriptNull; return false
        }

        return true
    }
}
