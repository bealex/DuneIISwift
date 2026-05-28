# Top-level globals in an executable are @MainActor-isolated

**Finding:** In a Swift executable's `main.swift`, top-level statements run on the main actor, so a top-level `let x = …` is **@MainActor-isolated**. Free functions declared at top level are **nonisolated** by default and cannot reference those globals — `error: main actor-isolated let 'x' can not be referenced from a nonisolated context`. (assetgen's top-level `let fileManager` / `let grayscale` broke its helper functions.)

**Why it matters:** The natural "define a global, use it from helpers" pattern fails to compile under Swift 6 in **executable** targets specifically (library-target globals don't get the main-actor default).

**Evidence:** `Code/Tools/assetgen/main.swift` — `FileManager.default` is used inline and the grayscale palette is passed as a parameter, rather than held as top-level globals.

**How to apply:** In an executable `main.swift`, don't share state with nonisolated free functions via top-level `let` globals. Use singletons inline (`FileManager.default`), pass state as parameters, or compute it inside the function.
