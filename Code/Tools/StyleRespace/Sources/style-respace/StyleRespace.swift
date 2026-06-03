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
        let literals = CollectionLiteralSpacer().rewrite(tree)
        let guards = GuardNormalizer().rewrite(literals)
        return TernaryNormalizer().rewrite(guards).description
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

// Normalises `guard` layout to the code style: a guard that fits in `lineLength` collapses to one line
// (`guard a, b else { … }`); otherwise it explodes — `guard` alone on its line, one condition per indented
// line, `else` on its own line — keeping swift-format's already-correct `else`/body. swift-format can't do
// this (it breaks by length, not per-condition), and the SwiftLint regex rule can only flag it, not fix it.
private final class GuardNormalizer: SyntaxRewriter {
    private let lineLength = 120

    override func visit(_ node: GuardStmtSyntax) -> StmtSyntax {
        let rewritten = super.visit(node)
        guard let node = rewritten.as(GuardStmtSyntax.self) else { return rewritten }

        // Bail on anything we can't restructure without risk: comments in the condition region (trimming
        // would drop them) or a single condition that is itself multi-line.
        let conditionTexts = node.conditions.map { $0.condition.trimmedDescription }
        guard
            !node.conditions.isEmpty,
            !hasComment(node),
            conditionTexts.allSatisfy({ !$0.contains("\n") })
        else { return StmtSyntax(node) }

        let indent = leadingIndentation(node)
        let bodyText = node.body.trimmedDescription

        if !bodyText.contains("\n") {
            let oneLine = indent + "guard " + conditionTexts.joined(separator: ", ") + " else " + bodyText
            if oneLine.count <= lineLength { return StmtSyntax(relaid(node, indent: indent, multiline: false)) }
        }

        return StmtSyntax(relaid(node, indent: indent, multiline: true))
    }

    // Rebuilds the guard keyword + condition list (and the `else` keyword's leading break) for either layout.
    // The `else` keyword's trailing trivia and the body node are left exactly as swift-format produced them.
    private func relaid(_ node: GuardStmtSyntax, indent: String, multiline: Bool) -> GuardStmtSyntax {
        var node = node
        let elementLeading: Trivia = multiline ? .newline + .spaces(indent.count + 4) : []
        let commaTrailing: Trivia = multiline ? [] : .space

        var elements: [ConditionElementSyntax] = []
        for element in node.conditions {
            var element = element
            element.condition = element.condition.trimmed
            element.leadingTrivia = elementLeading
            if element.trailingComma != nil {
                element.trailingComma = .commaToken(trailingTrivia: commaTrailing)
            }
            elements.append(element)
        }

        node.guardKeyword.trailingTrivia = multiline ? [] : .space
        node.conditions = ConditionElementListSyntax(elements)
        node.elseKeyword.leadingTrivia = multiline ? .newline + .spaces(indent.count) : .space
        return node
    }

    // The horizontal whitespace at the start of the guard's own line (assumes space indentation).
    private func leadingIndentation(_ node: some SyntaxProtocol) -> String {
        var indent = ""
        for piece in node.leadingTrivia.reversed() {
            switch piece {
                case .spaces(let count): indent = String(repeating: " ", count: count) + indent
                case .tabs(let count): indent = String(repeating: "\t", count: count) + indent
                default: return indent
            }
        }
        return indent
    }

    private func hasComment(_ node: GuardStmtSyntax) -> Bool {
        let region = node.conditions.description + node.elseKeyword.leadingTrivia.description
        return region.contains("//") || region.contains("/*")
    }
}

// On a multi-line ternary (`?` / `:` each on their own line), keeps the condition on the line it starts —
// swift-format breaks after the `=`/`return` and drops the condition onto its own line; this pulls it back
// up so the layout reads `let x = cond` / `?` / `:` with the operators indented under it. swift-format
// already indents the `?` and `:`; only the leading break before the condition is removed.
//
// `Parser.parse` leaves operators unfolded, so a ternary is a SequenceExpr whose middle element is an
// UnresolvedTernaryExpr (the `? then :`) — not a folded TernaryExpr. We work on that shape.
private final class TernaryNormalizer: SyntaxRewriter {
    override func visit(_ node: SequenceExprSyntax) -> ExprSyntax {
        let rewritten = super.visit(node)
        guard let node = rewritten.as(SequenceExprSyntax.self) else { return rewritten }

        let elements = Array(node.elements)
        guard
            let ternaryIndex = elements.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }),
            let ternary = elements[ternaryIndex].as(UnresolvedTernaryExprSyntax.self),
            containsNewline(ternary.questionMark.leadingTrivia) || containsNewline(ternary.colon.leadingTrivia)
        else { return ExprSyntax(node) }

        // Pull up the ternary's condition — the element immediately before the `?` — not elements[0], which
        // in an assignment expression (`self.x = cond ? …`) is the left-hand side. Removing its leading break
        // would swallow a statement separator.
        let conditionIndex = ternaryIndex - 1
        guard
            conditionIndex >= 0,
            containsNewline(elements[conditionIndex].leadingTrivia)
        else {
            return ExprSyntax(node)
        }

        // Only safe when the break is a continuation of an RHS: the whole sequence is a `let x = …` /
        // `return …` value (condition is the first element), or an assignment `=` sits right before it.
        let safe =
            conditionIndex == 0
            ? node.parent?.is(InitializerClauseSyntax.self) == true || node.parent?.is(ReturnStmtSyntax.self) == true
            : elements[conditionIndex - 1].is(AssignmentExprSyntax.self)
        guard safe else { return ExprSyntax(node) }

        var newElements = elements
        newElements[conditionIndex].leadingTrivia = .space
        var result = node
        result.elements = ExprListSyntax(newElements)
        return ExprSyntax(result)
    }

    private func containsNewline(_ trivia: Trivia) -> Bool {
        trivia.contains { piece in
            switch piece {
                case .newlines, .carriageReturns, .carriageReturnLineFeeds: return true
                default: return false
            }
        }
    }
}
