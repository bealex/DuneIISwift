// simbench entry point. All logic lives in `SimBench` (a normal, nonisolated type) — top-level code in
// main.swift is `@MainActor`-isolated under Swift 6, which fights the concurrency this benchmark exercises.
SimBench.run()
