import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    public enum TableAlignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, items: [String])
    case quote(String)
    case code(language: String?, content: String)
    case math(String)
    case table(
        headers: [String],
        alignments: [TableAlignment],
        rows: [[String]]
    )
    case rule
}

public enum MarkdownBlockParser {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listOrdered = false
        var quoteLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false
        var mathLines: [String] = []
        var inMath = false
        var consumedLines = Set<Int>()

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(ordered: listOrdered, items: listItems))
            listItems.removeAll()
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(.quote(quoteLines.joined(separator: "\n")))
            quoteLines.removeAll()
        }

        func flushTextBlocks() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        for (lineIndex, line) in lines.enumerated() {
            guard !consumedLines.contains(lineIndex) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inMath {
                if let closing = trimmed.range(of: "$$") {
                    let before = String(trimmed[..<closing.lowerBound])
                    if !before.isEmpty { mathLines.append(before) }
                    blocks.append(.math(
                        mathLines.joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    mathLines.removeAll()
                    inMath = false
                } else {
                    mathLines.append(line)
                }
                continue
            }
            if inCode {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(
                        language: codeLanguage,
                        content: codeLines.joined(separator: "\n")
                    ))
                    codeLines.removeAll()
                    codeLanguage = nil
                    inCode = false
                } else {
                    codeLines.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("$$") {
                flushTextBlocks()
                let remainder = String(trimmed.dropFirst(2))
                if let closing = remainder.range(of: "$$") {
                    blocks.append(.math(
                        String(remainder[..<closing.lowerBound])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                } else {
                    if !remainder.isEmpty { mathLines.append(remainder) }
                    inMath = true
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushTextBlocks()
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                codeLanguage = language.isEmpty ? nil : language
                inCode = true
                continue
            }
            if trimmed.isEmpty {
                flushTextBlocks()
                continue
            }
            if lineIndex + 1 < lines.count,
               let tableHeader = tableRow(from: trimmed),
               let alignments = tableSeparator(
                    from: lines[lineIndex + 1]
                        .trimmingCharacters(in: .whitespaces)
               ),
               tableHeader.count == alignments.count {
                flushTextBlocks()
                var rows: [[String]] = []
                var rowIndex = lineIndex + 2
                while rowIndex < lines.count,
                      let row = tableRow(
                        from: lines[rowIndex]
                            .trimmingCharacters(in: .whitespaces)
                      ),
                      row.count == tableHeader.count {
                    rows.append(row)
                    consumedLines.insert(rowIndex)
                    rowIndex += 1
                }
                consumedLines.insert(lineIndex + 1)
                blocks.append(.table(
                    headers: tableHeader,
                    alignments: alignments,
                    rows: rows
                ))
                continue
            }
            if let heading = heading(from: trimmed) {
                flushTextBlocks()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }
            if trimmed.range(
                of: #"^(---+|\*\*\*+|___+)$"#,
                options: .regularExpression
            ) != nil {
                flushTextBlocks()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quoteLines.append(
                    String(trimmed.dropFirst())
                        .trimmingCharacters(in: .whitespaces)
                )
                continue
            }
            if let item = listItem(from: trimmed) {
                flushParagraph()
                flushQuote()
                if !listItems.isEmpty, listOrdered != item.ordered {
                    flushList()
                }
                listOrdered = item.ordered
                listItems.append(item.text)
                continue
            }
            flushList()
            flushQuote()
            paragraph.append(trimmed)
        }
        if inCode {
            blocks.append(.code(
                language: codeLanguage,
                content: codeLines.joined(separator: "\n")
            ))
        }
        if inMath {
            paragraph.append("$$" + mathLines.joined(separator: "\n"))
        }
        flushTextBlocks()
        return blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count),
              line.dropFirst(hashes.count).first == " "
        else { return nil }
        return (
            hashes.count,
            String(line.dropFirst(hashes.count + 1))
                .trimmingCharacters(in: .whitespaces)
        )
    }

    private static func listItem(from line: String) -> (ordered: Bool, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return (false, String(line.dropFirst(2)))
        }
        guard let range = line.range(
            of: #"^\d+\.\s+"#,
            options: .regularExpression
        ) else { return nil }
        return (true, String(line[range.upperBound...]))
    }

    private static func tableSeparator(
        from line: String
    ) -> [MarkdownBlock.TableAlignment]? {
        guard let cells = tableRow(from: line), !cells.isEmpty else {
            return nil
        }
        var alignments: [MarkdownBlock.TableAlignment] = []
        for cell in cells {
            let compact = cell.replacingOccurrences(of: " ", with: "")
            guard compact.range(
                of: #"^:?-{3,}:?$"#,
                options: .regularExpression
            ) != nil else { return nil }
            if compact.hasPrefix(":") && compact.hasSuffix(":") {
                alignments.append(.center)
            } else if compact.hasSuffix(":") {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func tableRow(from line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if line.hasPrefix("|"), cells.first?.isEmpty == true {
            cells.removeFirst()
        }
        if line.hasSuffix("|"), cells.last?.isEmpty == true {
            cells.removeLast()
        }
        return cells.count >= 2 ? cells : nil
    }
}

public enum InlineMathSegment: Equatable, Sendable {
    case text(String)
    case math(String)
}

public enum InlineMathParser {
    public static func parse(_ source: String) -> [InlineMathSegment] {
        var segments: [InlineMathSegment] = []
        var text = ""
        var math = ""
        var inMath = false
        var escaped = false
        let characters = Array(source)

        func flushText() {
            guard !text.isEmpty else { return }
            segments.append(.text(text))
            text = ""
        }

        for (index, character) in characters.enumerated() {
            if escaped {
                if inMath {
                    math.append(character)
                } else {
                    text.append(character)
                }
                escaped = false
                continue
            }
            if character == "\\" {
                if inMath {
                    math.append(character)
                } else if index + 1 < characters.count,
                          characters[index + 1] == "$" {
                    escaped = true
                } else {
                    text.append(character)
                }
                continue
            }
            if character == "$" {
                if inMath {
                    guard !math.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty else {
                        text.append("$")
                        text.append(math)
                        text.append("$")
                        math = ""
                        inMath = false
                        continue
                    }
                    segments.append(.math(math))
                    math = ""
                    inMath = false
                } else {
                    let nextIsValid = index + 1 < characters.count
                        && !characters[index + 1].isWhitespace
                    guard nextIsValid,
                          hasValidClosingDollar(
                            in: characters,
                            after: index
                          )
                    else {
                        text.append(character)
                        continue
                    }
                    flushText()
                    inMath = true
                }
            } else if inMath {
                math.append(character)
            } else {
                text.append(character)
            }
        }
        if inMath {
            text.append("$")
            text.append(math)
        }
        flushText()
        return segments
    }

    private static func hasValidClosingDollar(
        in characters: [Character],
        after opening: Int
    ) -> Bool {
        var escaped = false
        for index in (opening + 1)..<characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "$" {
                return index > opening + 1
                    && !characters[index - 1].isWhitespace
            }
        }
        return false
    }
}
