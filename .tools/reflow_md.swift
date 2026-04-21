import Foundation

// Markdown reflow: unwrap paragraph-internal line breaks.
//
// Preserves: blank lines, code fences, headings, list items (continuation
// lines fold into the bullet), tables (any line with `|`), horizontal rules,
// reference-style link definitions, and blockquotes (each block folded).

func isHeading(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).hasPrefix("#") }

func isFence(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    return t.hasPrefix("```")
}

func isHR(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard t.count >= 3 else { return false }
    guard let first = t.first, "-_*".contains(first) else { return false }
    return t.allSatisfy { $0 == first }
}

func isReflink(_ s: String) -> Bool {
    // ^\s*\[[^\]]+\]:\s+
    let t = s.drop(while: { $0 == " " || $0 == "\t" })
    guard t.first == "[" else { return false }
    guard let closeBracket = t.firstIndex(of: "]") else { return false }
    let after = t.index(after: closeBracket)
    guard after < t.endIndex, t[after] == ":" else { return false }
    let afterColon = t.index(after: after)
    return afterColon < t.endIndex && (t[afterColon] == " " || t[afterColon] == "\t")
}

func isBlockquote(_ s: String) -> Bool {
    s.drop(while: { $0 == " " || $0 == "\t" }).first == ">"
}

/// Returns (indent, bullet, content) if `s` opens a list item.
func listMatch(_ s: String) -> (String, String, String)? {
    var i = s.startIndex
    var indent = ""
    while i < s.endIndex, s[i] == " " || s[i] == "\t" {
        indent.append(s[i])
        i = s.index(after: i)
    }
    guard i < s.endIndex else { return nil }
    let c = s[i]
    var bullet = ""
    if c == "-" || c == "*" || c == "+" {
        bullet = String(c)
        i = s.index(after: i)
    } else if c.isNumber {
        var digits = ""
        while i < s.endIndex, s[i].isNumber {
            digits.append(s[i])
            i = s.index(after: i)
        }
        guard i < s.endIndex, s[i] == "." else { return nil }
        bullet = digits + "."
        i = s.index(after: i)
    } else {
        return nil
    }
    // Require at least one space after the bullet.
    guard i < s.endIndex, s[i] == " " || s[i] == "\t" else { return nil }
    while i < s.endIndex, s[i] == " " || s[i] == "\t" {
        i = s.index(after: i)
    }
    return (indent, bullet, String(s[i...]))
}

func stripBlockquotePrefix(_ s: String) -> String {
    var t = s[...]
    while t.first == " " || t.first == "\t" { t = t.dropFirst() }
    guard t.first == ">" else { return String(s) }
    t = t.dropFirst()
    if t.first == " " || t.first == "\t" { t = t.dropFirst() }
    return String(t)
}

func isSpecial(_ line: String) -> Bool {
    if line.trimmingCharacters(in: .whitespaces).isEmpty { return true }
    if isHeading(line) { return true }
    if listMatch(line) != nil { return true }
    if line.contains("|") { return true }
    if isHR(line) { return true }
    if isReflink(line) { return true }
    if isBlockquote(line) { return true }
    if isFence(line) { return true }
    return false
}

func reflow(_ text: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var out: [String] = []
    var i = 0
    var inCode = false

    while i < lines.count {
        let line = lines[i]

        if isFence(line) {
            inCode.toggle()
            out.append(line)
            i += 1
            continue
        }
        if inCode {
            out.append(line)
            i += 1
            continue
        }
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append("")
            i += 1
            continue
        }
        if isHeading(line) || isHR(line) || isReflink(line) || line.contains("|") {
            out.append(line)
            i += 1
            continue
        }
        if let (indent, bullet, content) = listMatch(line) {
            var parts = [content.trimmingCharacters(in: .whitespaces)]
            i += 1
            while i < lines.count {
                let nxt = lines[i]
                if nxt.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if listMatch(nxt) != nil { break }
                if isHeading(nxt) || isHR(nxt) || isFence(nxt) { break }
                if nxt.contains("|") || isReflink(nxt) { break }
                parts.append(nxt.trimmingCharacters(in: .whitespaces))
                i += 1
            }
            out.append("\(indent)\(bullet) \(parts.joined(separator: " "))")
            continue
        }
        if isBlockquote(line) {
            var parts = [stripBlockquotePrefix(line).trimmingCharacters(in: .whitespaces)]
            i += 1
            while i < lines.count, isBlockquote(lines[i]) {
                parts.append(stripBlockquotePrefix(lines[i]).trimmingCharacters(in: .whitespaces))
                i += 1
            }
            out.append("> " + parts.joined(separator: " "))
            continue
        }
        // Regular paragraph.
        var parts = [line.trimmingCharacters(in: .whitespaces)]
        i += 1
        while i < lines.count, !isSpecial(lines[i]) {
            parts.append(lines[i].trimmingCharacters(in: .whitespaces))
            i += 1
        }
        out.append(parts.joined(separator: " "))
    }

    // Collapse runs of blank lines to a single blank line.
    var collapsed: [String] = []
    var prevBlank = false
    for line in out {
        let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
        if blank && prevBlank { continue }
        collapsed.append(line)
        prevBlank = blank
    }

    var result = collapsed.joined(separator: "\n")
    if !result.hasSuffix("\n") { result += "\n" }
    return result
}

// MARK: - main

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write(Data("usage: reflow_md.swift FILE [FILE ...]\n".utf8))
    exit(2)
}

var changed = 0
for path in args.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let original: String
    do {
        original = try String(contentsOf: url, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data("read failed: \(path): \(error)\n".utf8))
        continue
    }
    let reflowed = reflow(original)
    if reflowed != original {
        try? reflowed.write(to: url, atomically: true, encoding: .utf8)
        changed += 1
        print("reflowed: \(path)")
    }
}
print("\(changed) file(s) changed of \(args.count - 1)")
