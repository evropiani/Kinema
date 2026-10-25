import Foundation

/**
 * The small part of Markdown that release notes use, read into blocks the app
 * can lay out: headings, bullet points and paragraphs, with bold, code and
 * links inside them. The "Install" section, which only makes sense on the
 * release page, is left out.
 */
enum ReleaseNotes {
    enum Block: Hashable {
        case heading(level: Int, text: [Span])
        case bullet(level: Int, text: [Span])
        case paragraph([Span])
    }

    struct Span: Hashable {
        var text: String
        var bold = false
        var code = false
        var link: String?

        init(_ text: String, bold: Bool = false, code: Bool = false, link: String? = nil) {
            self.text = text
            self.bold = bold
            self.code = code
            self.link = link
        }
    }

    private static let skippedSections: Set<String> = ["install", "installing", "download"]

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph = ""
        var bullet: (level: Int, text: String)?
        var skipping = false
        var skipLevel = 0

        func flush() {
            if let current = bullet { blocks.append(.bullet(level: current.level, text: inline(current.text))) }
            bullet = nil
            if !paragraph.isEmpty { blocks.append(.paragraph(inline(paragraph))) }
            paragraph = ""
        }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            if let heading = heading(line) {
                flush()
                if skipping && heading.level > skipLevel { continue }
                skipping = skippedSections.contains(plainText(heading.title).lowercased())
                skipLevel = heading.level
                if !skipping { blocks.append(.heading(level: heading.level, text: inline(heading.title))) }
                continue
            }
            if skipping { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if let item = bulletItem(line) {
                flush()
                bullet = item
            } else if bullet != nil {
                // A wrapped line carries on the point above it.
                bullet?.text += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                if !paragraph.isEmpty { paragraph += " " }
                paragraph += line.trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> (level: Int, title: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        while title.hasSuffix("#") { title.removeLast() }
        return (hashes.count, title.trimmingCharacters(in: .whitespaces))
    }

    private static func bulletItem(_ line: String) -> (level: Int, text: String)? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " " else { return nil }
        return (indent >= 2 ? 1 : 0, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    private static func plainText(_ text: String) -> String {
        inline(text).map(\.text).joined()
    }

    /** Bold (`**`/`__`), `code` and [links](url); anything else stays as written. */
    static func inline(_ text: String) -> [Span] {
        var spans: [Span] = []
        var plain = ""
        var bold = false
        let chars = Array(text)
        var i = 0

        func emitPlain() {
            if !plain.isEmpty { spans.append(Span(plain, bold: bold)) }
            plain = ""
        }

        func starts(_ marker: String, at index: Int) -> Bool {
            let m = Array(marker)
            guard index + m.count <= chars.count else { return false }
            return Array(chars[index..<index + m.count]) == m
        }

        func find(_ target: String, from index: Int) -> Int? {
            var k = index
            while k < chars.count {
                if starts(target, at: k) { return k }
                k += 1
            }
            return nil
        }

        while i < chars.count {
            let c = chars[i]
            if starts("**", at: i) || starts("__", at: i) {
                emitPlain()
                bold.toggle()
                i += 2
            } else if c == "`" {
                if let end = find("`", from: i + 1) {
                    emitPlain()
                    spans.append(Span(String(chars[(i + 1)..<end]), bold: bold, code: true))
                    i = end + 1
                } else {
                    plain.append(c)
                    i += 1
                }
            } else if c == "[" {
                if let close = find("](", from: i + 1), let end = find(")", from: close + 2) {
                    emitPlain()
                    spans.append(Span(String(chars[(i + 1)..<close]), bold: bold, link: String(chars[(close + 2)..<end])))
                    i = end + 1
                } else {
                    plain.append(c)
                    i += 1
                }
            } else if c == "\\" && i + 1 < chars.count {
                plain.append(chars[i + 1])
                i += 2
            } else {
                plain.append(c)
                i += 1
            }
        }
        emitPlain()
        return spans.filter { !$0.text.isEmpty }
    }
}
