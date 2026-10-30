import Foundation

/// A problem in the config file, with the line to look at when there is one.
public struct ConfigError: Error, Equatable, CustomStringConvertible, Sendable {
    public var line: Int?
    public var message: String

    public init(line: Int?, _ message: String) {
        self.line = line
        self.message = message
    }

    public var description: String {
        line.map { "Line \($0): \(message)" } ?? message
    }
}

/// The part of YAML the config file uses: nested `key: value` maps, quoted strings and comments.
/// Anything else is an error rather than a guess, so a file never silently means something else.
public enum SimpleYAML {
    public struct Node: Equatable, Sendable {
        public enum Value: Equatable, Sendable {
            case scalar(String)
            case map([Entry])
        }

        public var line: Int
        public var value: Value
    }

    public struct Entry: Equatable, Sendable {
        public var key: String
        public var node: Node
    }

    private struct Line {
        var number: Int
        var indent: Int
        var key: String
        /// nil when nothing follows the colon.
        var value: String?
    }

    public static func parse(_ text: String) throws -> [Entry] {
        var lines: [Line] = []
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            if let line = try parseLine(String(raw), number: index + 1) { lines.append(line) }
        }
        var position = 0
        let entries = try parseBlock(lines, &position, indent: 0)
        if position < lines.count {
            throw ConfigError(line: lines[position].number, "Unexpected indentation.")
        }
        return entries
    }

    /// Returns the entries at exactly `indent`, consuming deeper lines as their children.
    private static func parseBlock(_ lines: [Line], _ position: inout Int, indent: Int) throws -> [Entry] {
        var entries: [Entry] = []
        var seen: Set<String> = []
        while position < lines.count, lines[position].indent == indent {
            let line = lines[position]
            position += 1
            guard seen.insert(line.key).inserted else {
                throw ConfigError(line: line.number, "“\(line.key)” appears more than once.")
            }
            if let value = line.value {
                if position < lines.count, lines[position].indent > indent {
                    throw ConfigError(line: lines[position].number, "Unexpected indentation.")
                }
                entries.append(Entry(key: line.key, node: Node(line: line.number, value: .scalar(value))))
            } else if position < lines.count, lines[position].indent > indent {
                let children = try parseBlock(lines, &position, indent: lines[position].indent)
                if position < lines.count, lines[position].indent > indent {
                    throw ConfigError(line: lines[position].number, "Inconsistent indentation.")
                }
                entries.append(Entry(key: line.key, node: Node(line: line.number, value: .map(children))))
            } else {
                entries.append(Entry(key: line.key, node: Node(line: line.number, value: .map([]))))
            }
        }
        return entries
    }

    private static func parseLine(_ raw: String, number: Int) throws -> Line? {
        var rest = Substring(raw)
        if number == 1, rest.first == "\u{FEFF}" { rest.removeFirst() }
        let indent = rest.prefix { $0 == " " }.count
        rest = rest.dropFirst(indent)
        if rest.first == "\t" { throw ConfigError(line: number, "Use spaces, not tabs, to indent.") }
        if rest.first == "#" || rest.allSatisfy(\.isWhitespace) { return nil }
        if indent == 0, rest.trimmingCharacters(in: .whitespaces) == "---" { return nil }

        let key: String
        if rest.first == "\"" || rest.first == "'" {
            (key, rest) = try parseQuoted(rest, number: number)
            guard rest.first == ":" else { throw ConfigError(line: number, "Expected “:” after the key.") }
            rest.removeFirst()
        } else {
            guard let colon = rest.firstIndex(of: ":") else {
                throw ConfigError(line: number, "Expected “key: value”.")
            }
            key = rest[..<colon].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: colon)...]
            if key.isEmpty || key.hasPrefix("- ") || key == "-" {
                throw ConfigError(line: number, "Lists aren't supported here. Expected “key: value”.")
            }
        }
        if let first = rest.first, !first.isWhitespace {
            throw ConfigError(line: number, "Expected a space after the colon in “\(key):”.")
        }
        return Line(number: number, indent: indent, key: key, value: try parseValue(rest, number: number))
    }

    private static func parseValue(_ text: Substring, number: Int) throws -> String? {
        var rest = text.drop(while: \.isWhitespace)
        guard let first = rest.first, first != "#" else { return nil }
        if first == "\"" || first == "'" {
            let value: String
            (value, rest) = try parseQuoted(rest, number: number)
            let tail = rest.drop(while: \.isWhitespace)
            if let next = tail.first, next != "#" {
                throw ConfigError(line: number, "Unexpected text after the closing quote.")
            }
            return value
        }
        if "[{&*!|>%@`".contains(first) {
            throw ConfigError(line: number, "“\(first)” isn't supported here. Put the value in quotes if it's text.")
        }
        // A comment starts at a # with a space before it.
        var end = rest.endIndex
        var previous: Character = " "
        for index in rest.indices {
            if rest[index] == "#", previous.isWhitespace {
                end = index
                break
            }
            previous = rest[index]
        }
        return rest[..<end].trimmingCharacters(in: .whitespaces)
    }

    private static func parseQuoted(_ text: Substring, number: Int) throws -> (String, Substring) {
        var rest = text
        let quote = rest.removeFirst()
        var result = ""
        while let character = rest.first {
            rest.removeFirst()
            if character == quote {
                if quote == "'", rest.first == "'" {
                    rest.removeFirst()
                    result.append("'")
                    continue
                }
                return (result, rest)
            }
            if quote == "\"", character == "\\" {
                guard let escaped = rest.first else { break }
                rest.removeFirst()
                guard escaped == "\"" || escaped == "\\" else {
                    throw ConfigError(line: number, "Only \\\" and \\\\ escapes are supported.")
                }
                result.append(escaped)
                continue
            }
            result.append(character)
        }
        throw ConfigError(line: number, "Missing closing quote.")
    }
}
