import Foundation
import SwiftParser
import SwiftSyntax

// Re-inserts the project's interior spaces on single-line collection *literals* (`[.foo]` → `[ .foo ]`),
// the one place swift-format's output diverges from the code style. Because it works on the parsed syntax
// tree, it touches only ArrayExpr / DictionaryExpr literal nodes — array TYPES (`[Int]`), subscripts
// (`arr[0]`), strings, and comments are different nodes and are left untouched.
@main
struct StyleRespace {
    static func main() throws {
        var paths = Array(CommandLine.arguments.dropFirst())
        let check = paths.contains("--check")
        paths.removeAll { $0.hasPrefix("--") }

        // No paths (or `-`): act as a stdin → stdout filter, so it can be piped after swift-format.
        if paths.isEmpty || paths == [ "-" ] {
            let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            FileHandle.standardOutput.write(Data(respaced(input).utf8))
            return
        }

        var changed = 0
        for path in paths {
            let url: URL = .init(fileURLWithPath: path)
            guard let original = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let result = respaced(original)
            guard result != original else { continue }

            changed += 1
            if check {
                print("✗ \(path)")
            } else {
                try result.write(to: url, atomically: true, encoding: .utf8)
            }
        }

        if check, changed > 0 { exit(1) }
    }

    private static func respaced(_ source: String) -> String {
        let tree = Parser.parse(source: source)
        return CollectionLiteralSpacer().rewrite(tree).description
    }
}

private final class CollectionLiteralSpacer: SyntaxRewriter {
    override func visit(_ node: ArrayExprSyntax) -> ExprSyntax {
        guard let visited = super.visit(node).as(ArrayExprSyntax.self) else { return super.visit(node) }

        guard
            !visited.elements.isEmpty,
            isSingleLine(visited.leftSquare, visited.elements, visited.rightSquare)
        else { return ExprSyntax(visited) }

        var result = visited
        (result.leftSquare, result.rightSquare) = spacedBrackets(
            left: visited.leftSquare,
            firstLeading: visited.elements.first?.leadingTrivia ?? [],
            lastTrailing: visited.elements.last?.trailingTrivia ?? [],
            right: visited.rightSquare
        )
        return ExprSyntax(result)
    }

    override func visit(_ node: DictionaryExprSyntax) -> ExprSyntax {
        guard let visited = super.visit(node).as(DictionaryExprSyntax.self) else { return super.visit(node) }

        guard
            case .elements(let elements) = visited.content,
            !elements.isEmpty,
            isSingleLine(visited.leftSquare, elements, visited.rightSquare)
        else { return ExprSyntax(visited) }

        var result = visited
        (result.leftSquare, result.rightSquare) = spacedBrackets(
            left: visited.leftSquare,
            firstLeading: elements.first?.leadingTrivia ?? [],
            lastTrailing: elements.last?.trailingTrivia ?? [],
            right: visited.rightSquare
        )
        return ExprSyntax(result)
    }

    // Only single-line literals get interior spaces; multi-line literals keep their own layout.
    private func isSingleLine(_ open: TokenSyntax, _ elements: some SyntaxProtocol, _ close: TokenSyntax) -> Bool {
        let interior = open.trailingTrivia.description + elements.description + close.leadingTrivia.description
        return !interior.contains("\n")
    }

    // Adds one interior space on each side, but only when that side has no whitespace yet. The gap after `[`
    // can live in the bracket's trailing trivia or the first element's leading trivia; the gap before `]` in
    // the last element's trailing trivia or the bracket's leading trivia — so both ends are checked. This
    // keeps the tool idempotent and never doubles an existing space.
    private func spacedBrackets(
        left: TokenSyntax,
        firstLeading: Trivia,
        lastTrailing: Trivia,
        right: TokenSyntax
    ) -> (TokenSyntax, TokenSyntax) {
        var left = left
        var right = right
        if !hasSpace(left.trailingTrivia), !hasSpace(firstLeading) {
            left.trailingTrivia = .space + left.trailingTrivia
        }
        if !hasSpace(lastTrailing), !hasSpace(right.leadingTrivia) {
            right.leadingTrivia = right.leadingTrivia + .space
        }
        return (left, right)
    }

    private func hasSpace(_ trivia: Trivia) -> Bool {
        trivia.contains { piece in
            switch piece {
                case .spaces, .tabs: return true
                default: return false
            }
        }
    }
}
