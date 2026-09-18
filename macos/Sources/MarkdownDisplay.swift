import Foundation
import UniformTypeIdentifiers

enum MarkdownDisplay {
    static func readableText(_ markdown: String) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        var inFence = false
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                if !inFence { lines.append("") }
                continue
            }
            if inFence {
                lines.append(line)
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                lines.append("————————")
                continue
            }
            var body = line
            if let heading = headingText(trimmed) {
                if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
                lines.append(heading)
                lines.append("")
                continue
            }
            if let quote = trimmed.first, quote == ">" {
                body = "　" + trimmed.drop(while: { $0 == ">" || $0 == " " })
            } else if let list = listText(trimmed) {
                body = list
            }
            lines.append(inline(body))
        }
        return lines
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func headingText(_ line: String) -> String? {
        guard line.first == "#" else { return nil }
        var count = 0
        for character in line {
            if character == "#" { count += 1 } else { break }
        }
        guard (1...6).contains(count), line.count > count else { return nil }
        let rest = line.dropFirst(count).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return inline(rest)
    }

    private static func listText(_ line: String) -> String? {
        let unordered = line.range(of: #"^[-*+]\s+"#, options: .regularExpression)
        if unordered != nil {
            return "• " + inline(String(line.drop(while: { $0 == "-" || $0 == "*" || $0 == "+" || $0 == " " })))
        }
        if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            return "• " + inline(String(line[match.upperBound...]))
        }
        return nil
    }

    private static func inline(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]+\)"#, "$1"),
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
            ("`([^`]+)`", "$1"),
            (#"\*\*([^*]+)\*\*"#, "$1"),
            (#"__([^_]+)__"#, "$1"),
            (#"(?<!\*)\*([^*]+)\*(?!\*)"#, "$1"),
            (#"(?<!_)_([^_]+)_(?!_)"#, "$1")
        ]
        for (pattern, template) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
            }
        }
        return result
    }
}

enum BookFile {
    static let extensions: Set<String> = ["txt", "md", "markdown", "pdf"]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func kind(for url: URL) -> BookKind {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "md", "markdown": return .markdown
        default: return .text
        }
    }

    static var contentTypes: [UTType] {
        [
            .plainText,
            .pdf,
            UTType(filenameExtension: "txt") ?? .plainText,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText
        ]
    }
}