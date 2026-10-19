import Foundation

/// A small TOML reader for memoir's config files (`pipeline.toml`): tables, arrays of tables, inline
/// tables, arrays, strings ("basic" and 'literal'), integers, floats and booleans — no dates and no
/// multi-line strings.
public enum TOMLValue: Sendable, Equatable {
    case string(String), integer(Int), float(Double), bool(Bool)
    case array([TOMLValue]), table([String: TOMLValue])

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var integer: Int? { if case .integer(let n) = self { n } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var array: [TOMLValue]? { if case .array(let a) = self { a } else { nil } }
    public var table: [String: TOMLValue]? { if case .table(let t) = self { t } else { nil } }
}

public struct TOMLError: Error, CustomStringConvertible, Equatable {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}

public enum TOML {
    /// The document's top-level table.
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var parser = TOMLParser(text)
        return try parser.document()
    }
}

/// Tables under construction: reference types, so a header can reopen one and add to it.
private final class TOMLTable {
    enum Entry { case value(TOMLValue), table(TOMLTable), tables([TOMLTable]) }
    var entries: [String: Entry] = [:]

    var value: TOMLValue {
        .table(entries.mapValues { entry in
            switch entry {
            case .value(let v): v
            case .table(let t): t.value
            case .tables(let ts): .array(ts.map(\.value))
            }
        })
    }
}

private struct TOMLParser {
    private let chars: [Character]
    private var i = 0
    private var line = 1
    private let root = TOMLTable()
    private var current: TOMLTable

    init(_ text: String) {
        chars = Array(text)
        current = root
    }

    mutating func document() throws -> [String: TOMLValue] {
        while true {
            skipBlank(newlines: true)
            guard let c = peek else { break }
            if c == "[" {
                try header()
            } else {
                let (path, value) = try keyValue()
                try set(path, value, in: current)
            }
            skipBlank(newlines: false)
            if let c = peek, !c.isNewline { throw fail("expected the end of the line, found \"\(c)\"") }
        }
        return root.value.table ?? [:]
    }

    // MARK: - Structure

    /// `[a.b]` opens a table, `[[a.b]]` appends a table to an array of tables.
    private mutating func header() throws {
        advance()  // [
        let isArray = peek == "["
        if isArray { advance() }
        skipBlank(newlines: false)
        let path = try key()
        skipBlank(newlines: false)
        guard peek == "]" else { throw fail("expected ] after the table name") }
        advance()
        if isArray {
            guard peek == "]" else { throw fail("expected ]] after the table name") }
            advance()
        }
        var table = root
        for (n, name) in path.enumerated() {
            let last = n == path.count - 1
            switch table.entries[name] {
            case nil:
                let new = TOMLTable()
                table.entries[name] = last && isArray ? .tables([new]) : .table(new)
                table = new
            case .table(let t) where !(last && isArray):
                table = t
            case .tables(let ts):
                if last && isArray {
                    let new = TOMLTable()
                    table.entries[name] = .tables(ts + [new])
                    table = new
                } else if last {
                    throw fail("\(path.joined(separator: ".")) is an array of tables — use [[\(path.joined(separator: "."))]]")
                } else {
                    table = ts[ts.count - 1]  // a sub-table of the latest element: [[step]] then [step.env]
                }
            default:
                throw fail("\(path.joined(separator: ".")) is already defined")
            }
        }
        current = table
    }

    private mutating func keyValue() throws -> ([String], TOMLValue) {
        let path = try key()
        skipBlank(newlines: false)
        guard peek == "=" else { throw fail("expected = after \(path.joined(separator: "."))") }
        advance()
        skipBlank(newlines: false)
        return (path, try value())
    }

    private func set(_ path: [String], _ value: TOMLValue, in table: TOMLTable) throws {
        var table = table
        for name in path.dropLast() {
            switch table.entries[name] {
            case nil:
                let new = TOMLTable()
                table.entries[name] = .table(new)
                table = new
            case .table(let t):
                table = t
            default:
                throw fail("\(name) is not a table")
            }
        }
        let name = path[path.count - 1]
        guard table.entries[name] == nil else { throw fail("\(path.joined(separator: ".")) is defined twice") }
        table.entries[name] = .value(value)
    }

    // MARK: - Keys and values

    private mutating func key() throws -> [String] {
        var parts: [String] = []
        while true {
            skipBlank(newlines: false)
            switch peek {
            case "\"": parts.append(try basicString())
            case "'": parts.append(try literalString())
            default:
                var bare = ""
                while let c = peek, c.isASCII, c.isLetter || c.isNumber || c == "_" || c == "-" {
                    bare.append(c)
                    advance()
                }
                guard !bare.isEmpty else { throw fail("expected a key") }
                parts.append(bare)
            }
            skipBlank(newlines: false)
            guard peek == "." else { return parts }
            advance()
        }
    }

    private mutating func value() throws -> TOMLValue {
        switch peek {
        case "\"": return .string(try basicString())
        case "'": return .string(try literalString())
        case "[": return try array()
        case "{": return try inlineTable()
        case nil: throw fail("expected a value")
        default: return try scalar()
        }
    }

    private mutating func array() throws -> TOMLValue {
        advance()  // [
        var items: [TOMLValue] = []
        while true {
            skipBlank(newlines: true)
            if peek == "]" { advance(); return .array(items) }
            items.append(try value())
            skipBlank(newlines: true)
            switch peek {
            case ",": advance()
            case "]": advance(); return .array(items)
            default: throw fail("expected , or ] in the array")
            }
        }
    }

    private mutating func inlineTable() throws -> TOMLValue {
        advance()  // {
        let table = TOMLTable()
        skipBlank(newlines: true)
        if peek == "}" { advance(); return table.value }
        while true {
            skipBlank(newlines: true)
            let (path, value) = try keyValue()
            try set(path, value, in: table)
            skipBlank(newlines: true)
            switch peek {
            case ",": advance()
            case "}": advance(); return table.value
            default: throw fail("expected , or } in the inline table")
            }
        }
    }

    /// true, false, integers and floats.
    private mutating func scalar() throws -> TOMLValue {
        var word = ""
        while let c = peek, !c.isWhitespace, !",]}#".contains(c) {
            word.append(c)
            advance()
        }
        switch word {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: break
        }
        let digits = word.replacingOccurrences(of: "_", with: "")
        if let n = Int(digits) { return .integer(n) }
        if digits.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let x = Double(digits) { return .float(x) }
        throw fail(word.isEmpty ? "expected a value" : "unsupported value \(word) (strings need quotes)")
    }

    private mutating func basicString() throws -> String {
        advance()  // "
        if peek == "\"", peekNext == "\"" { throw fail("multi-line strings aren't supported") }
        var out = ""
        while let c = peek {
            advance()
            switch c {
            case "\"": return out
            case "\\":
                guard let e = peek else { break }
                advance()
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "u", "U":
                    let count = e == "u" ? 4 : 8
                    var hex = ""
                    for _ in 0 ..< count {
                        guard let h = peek else { break }
                        hex.append(h)
                        advance()
                    }
                    guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                        throw fail("bad \\\(e) escape")
                    }
                    out.unicodeScalars.append(scalar)
                default: throw fail("unknown escape \\\(e)")
                }
            default:
                if c.isNewline { throw fail("unterminated string") }
                out.append(c)
            }
        }
        throw fail("unterminated string")
    }

    private mutating func literalString() throws -> String {
        advance()  // '
        var out = ""
        while let c = peek {
            advance()
            if c == "'" { return out }
            if c.isNewline { break }
            out.append(c)
        }
        throw fail("unterminated string")
    }

    // MARK: - Scanning

    private var peek: Character? { i < chars.count ? chars[i] : nil }
    private var peekNext: Character? { i + 1 < chars.count ? chars[i + 1] : nil }

    private mutating func advance() {
        if chars[i].isNewline { line += 1 }
        i += 1
    }

    /// Skips spaces, tabs and comments — and line breaks too if `newlines`.
    private mutating func skipBlank(newlines: Bool) {
        while let c = peek {
            if c == "#" {
                while let c = peek, !c.isNewline { _ = c; advance() }
            } else if c == " " || c == "\t" || (newlines && c.isNewline) {
                advance()
            } else {
                return
            }
        }
    }

    private func fail(_ message: String) -> TOMLError { TOMLError(line: line, message: message) }
}
