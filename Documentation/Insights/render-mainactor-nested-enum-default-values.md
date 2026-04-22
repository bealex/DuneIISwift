# Nested-enum default values can't reach `@MainActor` statics on the enclosing type

- **Discovered**: 2026-04-22 · `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift`
- **Category**: render (Swift concurrency × SpriteKit layout)
- **Applies to**: any `@MainActor` scene / view class that groups layout constants inside a nested `enum`

## The fact

A nested `private enum LayoutName { static let x: CGFloat = Self.OuterType.someStatic + otherStatic }` fails to compile inside a `@MainActor`-isolated class:

```
error: main actor-isolated default value in a nonisolated context
```

The nested enum itself is nonisolated, but its default-value initializer expressions evaluate against the enclosing `@MainActor` statics. Swift 6's strict concurrency flags the crossing.

## Why it matters

`ScenarioScene` uses tight-grouped `private enum InfoPanel { ... }` / `MinimapPanel { ... }` blocks to namespace layout constants. Writing `MinimapPanel.baseY = InfoPanel.height + sidebarPadding` looks natural but won't build — the workaround is to inline the literal (`= 204`) or move the constant to a `static func` that can be main-actor-isolated.

## Where it lives in our code

`Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift:803-811` — the `MinimapPanel` enum inlines `baseY = 204` with a comment pointing at the arithmetic it replaces.

## Where it lives in the reference

Not a port issue — this is a Swift 6 strict-concurrency property. The diagnostic surfaces because the nested-enum body is nonisolated by default, regardless of the enclosing type's isolation.
