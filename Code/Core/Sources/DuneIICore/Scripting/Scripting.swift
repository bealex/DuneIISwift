import Foundation
import Memoirs

/// Stack-based virtual machine for compiled EMC scripts. Mirrors
/// OpenDUNE's `ScriptEngine` / `Script_Run` byte-for-byte; see
/// `Documentation/Algorithms/EmcVM.md`.
public enum Scripting {
    /// Per-instance VM state: one `Engine` exists per unit, structure, or
    /// team in OpenDUNE. Engines are pure value types so they can be
    /// snapshotted into save files and dispatched concurrently with
    /// strict-concurrency-safe code.
    public struct Engine: Sendable, Equatable {
        public var pc: Int
        /// Tick-based suspension counter. Host functions (e.g. `Delay`)
        /// write here; the outer tick scheduler consumes it. `step()`
        /// itself does not consult this field — it's an observable
        /// output, not a gate. See `Documentation/Algorithms/EmcHostFunctions.md`.
        public var delay: UInt16
        public var returnValue: UInt16
        public var framePointer: UInt8
        public var stackPointer: UInt8
        public var variables: [UInt16]
        public var stack: [UInt16]
        public var isSubroutine: Bool
        public var halted: Bool

        /// Canonical empty engine: stack and variables zeroed, SP at the
        /// "empty" sentinel of 15, FP at the "no frame" sentinel of 17.
        public static func reset() -> Engine {
            Engine(
                pc: 0,
                delay: 0,
                returnValue: 0,
                framePointer: 17,
                stackPointer: 15,
                variables: Array(repeating: 0, count: 5),
                stack: Array(repeating: 0, count: 15),
                isSubroutine: false,
                halted: false
            )
        }

        /// Reconstructs an `Engine` from a save-file `ScriptState`.
        /// Mirrors OpenDUNE's `src/saveload/unit.c:86` fix-up where the
        /// on-disk word offset gets re-attached to the script code
        /// base after load. Our `pc` is already a word index into
        /// `program.code`, so the offset maps directly.
        ///
        /// Arrays are padded to the canonical sizes (5 variables, 15
        /// stack entries) if the save gives fewer; that never happens
        /// for a well-formed save but keeps the constructor total.
        public static func fromSave(_ s: Formats.Save.ScriptState) -> Engine {
            var vars = s.variables
            while vars.count < 5 { vars.append(0) }
            var stack = s.stack
            while stack.count < 15 { stack.append(0) }
            return Engine(
                pc: Int(s.scriptOffset),
                delay: s.delay,
                returnValue: s.returnValue,
                framePointer: s.framePointer,
                stackPointer: s.stackPointer,
                variables: Array(vars.prefix(5)),
                stack: Array(stack.prefix(15)),
                isSubroutine: s.isSubroutine != 0,
                halted: false
            )
        }
    }

    /// Result of executing a single opcode.
    public enum RunResult: Equatable, Sendable {
        case ok
        case halted
    }

    /// Pairs an EMC program with the 64-slot host-function table the
    /// `SCRIPT_FUNCTION` opcode dispatches into.
    public struct VM {
        public typealias Function = (inout Engine) -> UInt16

        /// Opcode-level trace closure. Called right after decoding the
        /// opcode + parameter but BEFORE `execute` runs. Used by the
        /// parity harness to diff per-opcode execution against a trace
        /// dumped by OpenDUNE's `Script_Run`. Non-sendable on purpose
        /// — tests + debug only.
        public typealias TraceHook = (_ pc: Int, _ opcode: UInt8, _ parameter: Int, _ engine: Engine) -> Void

        public let program: Formats.Emc.Program
        public var functions: [Function?]
        public var trace: TraceHook?

        public init(program: Formats.Emc.Program, functions: [Function?]) {
            precondition(functions.count == 64, "EMC function table is exactly 64 slots")
            self.program = program
            self.functions = functions
            self.trace = nil
        }

        /// Sets `engine.pc` to `program.entryPoints[typeID]` and zeroes
        /// the rest. Mirrors OpenDUNE `Script_Reset` + `Script_Load`.
        ///
        /// When `program.entryPoints` is empty (e.g. `Formats.Emc.Program.empty`
        /// used by unit tests or before any real `.EMC` is loaded), this
        /// is a no-op — the caller's pre-seeded engine state is
        /// preserved. That lets the scheduler safely call `load` on every
        /// action change without clobbering synthetic test harnesses.
        public func load(engine: inout Engine, typeID: Int) {
            if program.entryPoints.isEmpty { return }
            engine = .reset()
            guard typeID >= 0, typeID < program.entryPoints.count else {
                engine.halted = true
                return
            }
            engine.pc = Int(program.entryPoints[typeID])
            // OpenDUNE `Script_Load` stores the typeID in `variables[0]`
            // so the very first `pushVariable(0)` the action reads it
            // back. Without this, every action script sees `var[0] = 0`
            // and the top-level dispatch at pc=1363 in UNIT.EMC branches
            // into the ACTION_ATTACK path regardless of the requested
            // action — which is why GUARD units never reached IdleAction.
            if typeID >= 0, typeID <= Int(UInt16.max), !engine.variables.isEmpty {
                engine.variables[0] = UInt16(truncatingIfNeeded: typeID)
            }
        }

        @discardableResult
        public func step(_ engine: inout Engine) -> RunResult {
            if engine.halted { return .halted }
            guard engine.pc >= 0, engine.pc < program.code.count else {
                engine.halted = true
                return .halted
            }

            let pcAtEntry = engine.pc
            let current = program.code[engine.pc]
            engine.pc += 1

            var opcode = UInt8((current >> 8) & 0x1F)
            var parameter: Int = 0

            if current & 0x8000 != 0 {
                opcode = 0
                parameter = Int(current & 0x7FFF)
            } else if current & 0x4000 != 0 {
                parameter = Int(Int8(bitPattern: UInt8(current & 0xFF)))
            } else if current & 0x2000 != 0 {
                guard engine.pc < program.code.count else {
                    engine.halted = true
                    return .halted
                }
                parameter = Int(program.code[engine.pc])
                engine.pc += 1
            }

            if let trace = trace {
                trace(pcAtEntry, opcode, parameter, engine)
            }

            return execute(opcode: opcode, parameter: parameter, engine: &engine)
        }

        private func execute(opcode: UInt8, parameter: Int, engine: inout Engine) -> RunResult {
            switch opcode {
            case 0:                              // JUMP
                engine.pc = parameter
                return .ok

            case 1:                              // SETRETURNVALUE
                engine.returnValue = UInt16(truncatingIfNeeded: parameter)
                return .ok

            case 2:                              // PUSH_RETURN_OR_LOCATION
                if parameter == 0 {
                    return push(engine.returnValue, engine: &engine)
                } else if parameter == 1 {
                    let location = UInt16(truncatingIfNeeded: engine.pc + 1)
                    if push(location, engine: &engine) == .halted { return .halted }
                    if push(UInt16(engine.framePointer), engine: &engine) == .halted { return .halted }
                    engine.framePointer = engine.stackPointer &+ 2
                    return .ok
                }
                engine.halted = true
                return .halted

            case 3, 4:                           // PUSH, PUSH2
                return push(UInt16(truncatingIfNeeded: parameter), engine: &engine)

            case 5:                              // PUSH_VARIABLE
                guard parameter >= 0, parameter < engine.variables.count else {
                    engine.halted = true
                    return .halted
                }
                return push(engine.variables[parameter], engine: &engine)

            case 6:                              // PUSH_LOCAL_VARIABLE
                let idx = Int(engine.framePointer) - parameter - 2
                if idx >= 15 || idx < 0 {
                    engine.halted = true
                    return .halted
                }
                return push(engine.stack[idx], engine: &engine)

            case 7:                              // PUSH_PARAMETER
                let idx = Int(engine.framePointer) + parameter - 1
                if idx >= 15 || idx < 0 {
                    engine.halted = true
                    return .halted
                }
                return push(engine.stack[idx], engine: &engine)

            case 8:                              // POP_RETURN_OR_LOCATION
                if parameter == 0 {
                    let v = pop(engine: &engine)
                    if engine.halted { return .halted }
                    engine.returnValue = v
                    return .ok
                } else if parameter == 1 {
                    if !canPeek(engine: engine, position: 2) {
                        engine.halted = true
                        return .halted
                    }
                    let fp = pop(engine: &engine)
                    let loc = pop(engine: &engine)
                    if engine.halted { return .halted }
                    engine.framePointer = UInt8(truncatingIfNeeded: fp)
                    engine.pc = Int(loc)
                    return .ok
                }
                engine.halted = true
                return .halted

            case 9:                              // POP_VARIABLE
                guard parameter >= 0, parameter < engine.variables.count else {
                    engine.halted = true
                    return .halted
                }
                let v = pop(engine: &engine)
                if engine.halted { return .halted }
                engine.variables[parameter] = v
                return .ok

            case 10:                             // POP_LOCAL_VARIABLE
                let idx = Int(engine.framePointer) - parameter - 2
                if idx >= 15 || idx < 0 {
                    engine.halted = true
                    return .halted
                }
                let v = pop(engine: &engine)
                if engine.halted { return .halted }
                engine.stack[idx] = v
                return .ok

            case 11:                             // POP_PARAMETER
                let idx = Int(engine.framePointer) + parameter - 1
                if idx >= 15 || idx < 0 {
                    engine.halted = true
                    return .halted
                }
                let v = pop(engine: &engine)
                if engine.halted { return .halted }
                engine.stack[idx] = v
                return .ok

            case 12:                             // STACK_REWIND
                let newSP = Int(engine.stackPointer) + parameter
                guard newSP >= 0, newSP <= 15 else {
                    engine.halted = true
                    return .halted
                }
                engine.stackPointer = UInt8(newSP)
                return .ok

            case 13:                             // STACK_FORWARD
                let newSP = Int(engine.stackPointer) - parameter
                guard newSP >= 0, newSP <= 15 else {
                    engine.halted = true
                    return .halted
                }
                engine.stackPointer = UInt8(newSP)
                return .ok

            case 14:                             // FUNCTION
                let fnIndex = parameter & 0xFF
                guard fnIndex < functions.count, let fn = functions[fnIndex] else {
                    engine.halted = true
                    return .halted
                }
                Log.verbose(
                    "FUNCTION slot 0x\(String(fnIndex, radix: 16)) (pc=\(engine.pc - 1))",
                    tracer: .label("vm")
                )
                engine.returnValue = fn(&engine)
                return .ok

            case 15:                             // JUMP_NE
                if !canPeek(engine: engine, position: 1) {
                    engine.halted = true
                    return .halted
                }
                let top = pop(engine: &engine)
                if engine.halted { return .halted }
                if top != 0 { return .ok }
                engine.pc = parameter & 0x7FFF
                return .ok

            case 16:                             // UNARY
                let v = pop(engine: &engine)
                if engine.halted { return .halted }
                let result: UInt16
                switch parameter {
                case 0: result = (v == 0) ? 1 : 0
                case 1: result = UInt16(bitPattern: 0 &- Int16(bitPattern: v))
                case 2: result = ~v
                default:
                    engine.halted = true
                    return .halted
                }
                return push(result, engine: &engine)

            case 17:                             // BINARY
                if !canPeek(engine: engine, position: 2) {
                    engine.halted = true
                    return .halted
                }
                let right = Int16(bitPattern: pop(engine: &engine))
                let left = Int16(bitPattern: pop(engine: &engine))
                if engine.halted { return .halted }
                let result: Int
                switch parameter {
                case 0:  result = (left != 0 && right != 0) ? 1 : 0
                case 1:  result = (left != 0 || right != 0) ? 1 : 0
                case 2:  result = (left == right) ? 1 : 0
                case 3:  result = (left != right) ? 1 : 0
                case 4:  result = (left <  right) ? 1 : 0
                case 5:  result = (left <= right) ? 1 : 0
                case 6:  result = (left >  right) ? 1 : 0
                case 7:  result = (left >= right) ? 1 : 0
                case 8:  result = Int(left) &+ Int(right)
                case 9:  result = Int(left) &- Int(right)
                case 10: result = Int(left) &* Int(right)
                case 11:
                    if right == 0 { engine.halted = true; return .halted }
                    result = Int(left) / Int(right)
                case 12: result = Int(left) >> Int(right)
                case 13: result = Int(left) << Int(right)
                case 14: result = Int(left) & Int(right)
                case 15: result = Int(left) | Int(right)
                case 16:
                    if right == 0 { engine.halted = true; return .halted }
                    result = Int(left) % Int(right)
                case 17: result = Int(left) ^ Int(right)
                default:
                    engine.halted = true
                    return .halted
                }
                return push(UInt16(truncatingIfNeeded: result), engine: &engine)

            case 18:                             // RETURN
                if !canPeek(engine: engine, position: 2) {
                    engine.halted = true
                    return .halted
                }
                let rv = pop(engine: &engine)
                let loc = pop(engine: &engine)
                if engine.halted { return .halted }
                engine.returnValue = rv
                engine.pc = Int(loc)
                engine.isSubroutine = false
                return .ok

            default:
                engine.halted = true
                return .halted
            }
        }

        // MARK: Stack primitives

        private func push(_ value: UInt16, engine: inout Engine) -> RunResult {
            if engine.stackPointer == 0 {
                engine.halted = true
                return .halted
            }
            engine.stackPointer &-= 1
            engine.stack[Int(engine.stackPointer)] = value
            return .ok
        }

        private func pop(engine: inout Engine) -> UInt16 {
            if engine.stackPointer >= 15 {
                engine.halted = true
                return 0
            }
            let v = engine.stack[Int(engine.stackPointer)]
            engine.stackPointer &+= 1
            return v
        }

        /// Mirrors OpenDUNE's `Script_Stack_Peek` overflow check
        /// `stackPointer >= 16 - position`: returns false when peek would
        /// read past the bottom of the stack.
        private func canPeek(engine: Engine, position: Int) -> Bool {
            return Int(engine.stackPointer) < 16 - position
        }
    }

    // MARK: Public stack primitives for host-function callbacks

    /// Push a value onto the stack. Mirrors OpenDUNE `Script_Stack_Push`.
    /// Halts the engine on overflow (matches OpenDUNE's `script = NULL`).
    public static func push(engine: inout Engine, _ value: UInt16) {
        if engine.stackPointer == 0 {
            engine.halted = true
            return
        }
        engine.stackPointer &-= 1
        engine.stack[Int(engine.stackPointer)] = value
    }

    /// Pop the top of the stack. Halts on underflow.
    public static func pop(engine: inout Engine) -> UInt16 {
        if engine.stackPointer >= 15 {
            engine.halted = true
            return 0
        }
        let v = engine.stack[Int(engine.stackPointer)]
        engine.stackPointer &+= 1
        return v
    }

    /// Peek at a stack slot without removing it. `position == 1` is the
    /// top of the stack; `position == 2` the next one down; and so on.
    /// Mirrors OpenDUNE `Script_Stack_Peek`. Halts on underflow.
    public static func peek(engine: inout Engine, position: Int) -> UInt16 {
        if Int(engine.stackPointer) >= 16 - position {
            engine.halted = true
            return 0
        }
        return engine.stack[Int(engine.stackPointer) + position - 1]
    }
}
