import Foundation

/// Common response Markdown blocks. Inline syntax is handled by Foundation.
enum AssistantMarkdown {
    static func inline(_ source: String) -> AttributedString {
        var result = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
        // CommonMark leaves **「quoted Japanese」** adjacent to Japanese prose literal.
        // Style these remaining pairs while retaining Foundation's links and other attributes.
        guard !source.contains("\\*"), let pattern = try? NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#) else { return result }
        let text = String(result.characters)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let start = result.characters.index(result.startIndex, offsetBy: text.distance(from: text.startIndex, to: range.lowerBound))
            let end = result.characters.index(start, offsetBy: text.distance(from: range.lowerBound, to: range.upperBound))
            guard !result[start ..< end].runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) else { continue }
            let innerStart = result.characters.index(start, offsetBy: 2)
            let innerEnd = result.characters.index(end, offsetBy: -2)
            var content = AttributedString(result[innerStart ..< innerEnd])
            for run in Array(content.runs) {
                content[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            }
            result.replaceSubrange(start ..< end, with: content)
        }
        return result
    }

    enum Block: Equatable {
        case heading(Int, String), paragraph(String), item(String, String, Int), quote(String)
        case code(String, String), rule, table([[String]])
    }

    static func blocks(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var output: [Block] = []
        var paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty {
                output.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph.removeAll()
            }
        }
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush(); index += 1; continue
            }
            if let first = line.first, first == "`" || first == "~", line.prefix(while: { $0 == first }).count >= 3 {
                flush()
                let fence = String(line.prefix(while: { $0 == first }))
                let language = String(line.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var content: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.count >= fence.count, candidate.allSatisfy({ $0 == first }) {
                        index += 1; break
                    }
                    content.append(lines[index]); index += 1
                }
                output.append(.code(language, content.joined(separator: "\n")))
                continue
            }
            if index + 1 < lines.count, line.contains("|"), isTableDivider(lines[index + 1]) {
                flush()
                let header = cells(line)
                var rows = [header]
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let values = cells(lines[index])
                    rows.append(Array((values + Array(repeating: "", count: header.count)).prefix(header.count)))
                    index += 1
                }
                output.append(.table(rows)); continue
            }
            if index + 1 < lines.count, listItem(raw) == nil, !line.hasPrefix(">"), !line.hasPrefix("#"), !isRule(line) {
                let underline = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if !underline.isEmpty, underline.allSatisfy({ $0 == "=" }) || (underline.count >= 3 && underline.allSatisfy { $0 == "-" }) {
                    output.append(.heading(underline.first == "=" ? 1 : 2, (paragraph + [line]).joined(separator: "\n")))
                    paragraph.removeAll(); index += 2; continue
                }
            }
            let hashes = line.prefix(while: { $0 == "#" }).count
            if (1 ... 6).contains(hashes), line.dropFirst(hashes).first == " " {
                flush()
                let title = String(line.dropFirst(hashes + 1)).replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
                output.append(.heading(hashes, title))
            } else if isRule(line) {
                flush(); output.append(.rule)
            } else if line.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let value = lines[index].trimmingCharacters(in: .whitespaces).dropFirst()
                    quote.append(String(value.first == " " ? value.dropFirst() : value)); index += 1
                }
                output.append(.quote(quote.joined(separator: "\n"))); continue
            } else if let item = listItem(raw) {
                flush(); output.append(item)
            } else {
                paragraph.append(raw)
            }
            index += 1
        }
        flush()
        return output
    }

    private static func listItem(_ raw: String) -> Block? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let depth = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        if ["- ", "* ", "+ "].contains(where: { line.hasPrefix($0) }) {
            var text = String(line.dropFirst(2))
            var marker = "•"
            if text.hasPrefix("[ ] ") {
                marker = "☐"; text = String(text.dropFirst(4))
            }
            if text.lowercased().hasPrefix("[x] ") {
                marker = "☑"; text = String(text.dropFirst(4))
            }
            return .item(marker, text, depth)
        }
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        let rest = line.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 9, rest.hasPrefix(". ") || rest.hasPrefix(") ") {
            return .item(String(digits) + ".", String(rest.dropFirst(2)), depth)
        }
        return nil
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let values = cells(line)
        return line.contains("|") && !values.isEmpty && values.allSatisfy {
            let value = $0.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }

    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") {
            text.removeFirst()
        }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") {
            text.removeLast()
        }
        var values: [String] = []
        var cell = ""
        var escaped = false
        var code = false
        for char in text {
            if escaped {
                cell.append(char); escaped = false; continue
            }
            if char == "\\" {
                cell.append(char); escaped = true; continue
            }
            if char == "`" {
                code.toggle()
            }
            if char == "|", !code {
                values.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""
            } else {
                cell.append(char)
            }
        }
        values.append(cell.trimmingCharacters(in: .whitespaces))
        return values
    }
}
