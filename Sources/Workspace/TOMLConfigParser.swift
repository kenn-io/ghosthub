import Foundation

/// Pure-function helpers for parsing and rendering TOML config values.
/// Extracted from SettingsStore to keep parsing logic isolated and testable.
public enum TOMLConfigParser {

    // MARK: - Line Stripping

    /// Strip inline comments from a raw TOML line, respecting quoted strings.
    public static func strippedTOMLLine(_ rawLine: String) -> String {
        var result = ""
        var quote: Character?
        var isEscaped = false

        for character in rawLine {
            if let activeQuote = quote {
                if character == activeQuote,
                   activeQuote == "'" || !isEscaped {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            }
            if character == "#", quote == nil {
                break
            }
            result.append(character)
            if quote == "\"", character == "\\", !isEscaped {
                isEscaped = true
            } else {
                isEscaped = false
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Header / Key Extraction

    /// Extract the section name from a `[section]` header line.
    public static func sectionHeaderName(
        from trimmedLine: String
    ) -> String? {
        guard trimmedLine.hasPrefix("["),
              trimmedLine.hasSuffix("]")
        else {
            return nil
        }
        return String(
            trimmedLine.dropFirst().dropLast()
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - TOML String Quoting

    /// Remove surrounding TOML quotes (double or single) and unescape.
    public static func unquoteTOMLString(_ raw: String) -> String {
        if raw.hasPrefix("\""), raw.hasSuffix("\""),
           raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'"),
           raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    /// Wrap a string in double quotes with TOML escaping.
    public static func renderTOMLString(_ value: String) -> String {
        let escaped = value.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 0x08:
                return "\\b"
            case 0x09:
                return "\\t"
            case 0x0A:
                return "\\n"
            case 0x0C:
                return "\\f"
            case 0x0D:
                return "\\r"
            case 0x22:
                return "\\\""
            case 0x5C:
                return "\\\\"
            case 0x00 ... 0x1F, 0x7F:
                return String(format: "\\u%04X", scalar.value)
            default:
                return String(scalar)
            }
        }.joined()
        return "\"\(escaped)\""
    }

    /// Render a Double as a TOML number (integer when possible).
    public static func renderTOMLNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(
            format: "%.1f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    // MARK: - Top-Level Config Parsing

    /// Parse a top-level `key = value` from flat config content.
    /// Scans in reverse so the last occurrence wins.
    public static func parseConfigValue(
        for key: String,
        in contents: String
    ) -> String? {
        for rawLine in contents.split(
            whereSeparator: \.isNewline
        ).reversed() {
            let line = strippedTOMLLine(String(rawLine))
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            let parts = line.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2 else {
                continue
            }

            let candidateKey = parts[0]
                .trimmingCharacters(in: .whitespaces)
            guard candidateKey == key else {
                continue
            }

            return parts[1].trimmingCharacters(in: .whitespaces)
        }

        return nil
    }

    /// Parse a boolean from a top-level `key = value`.
    public static func parseBoolConfigValue(
        for key: String,
        in contents: String
    ) -> Bool? {
        guard let value = parseConfigValue(
            for: key, in: contents
        ) else {
            return nil
        }

        switch value.lowercased() {
        case "true", "yes", "on", "1":
            return true
        case "false", "no", "off", "0":
            return false
        default:
            return nil
        }
    }

    /// Parse the `copy-on-select` key which accepts extra values
    /// like `clipboard` and `none`.
    public static func parseCopyOnSelect(in contents: String) -> Bool? {
        guard let value = parseConfigValue(
            for: "copy-on-select", in: contents
        ) else {
            return nil
        }

        switch value.lowercased() {
        case "clipboard", "true", "yes", "on", "1":
            return true
        case "false", "no", "off", "0", "none":
            return false
        default:
            return nil
        }
    }

    /// Parse `shell-integration-features` to determine cursor behavior.
    public static func parseShellIntegrationCursorBehavior(
        in contents: String
    ) -> Bool? {
        guard let value = parseConfigValue(
            for: "shell-integration-features",
            in: contents
        ) else {
            return nil
        }

        let features = value
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
        return !features.contains("no-cursor")
    }

    // MARK: - Section-Scoped Config Parsing

    /// Parse a value under a named `[section]` header.
    public static func parseAppConfigValue(
        sectionName: String,
        key: String,
        in contents: String
    ) -> String? {
        var currentSection: String?

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = strippedTOMLLine(String(rawLine))
            guard !line.isEmpty else {
                continue
            }

            if let headerName = sectionHeaderName(from: line) {
                currentSection = headerName
                continue
            }

            guard currentSection == sectionName,
                  let separatorIndex = line.firstIndex(of: "=")
            else {
                continue
            }

            let candidateKey = line[..<separatorIndex]
                .trimmingCharacters(in: .whitespaces)
            guard candidateKey == key else {
                continue
            }

            return line[line.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespaces)
        }

        return nil
    }

    /// Parse a string value under a named section, unquoting if needed.
    ///
    /// Handles double-quote stripping inline rather than delegating to
    /// `unquoteTOMLString`. App config (config.toml) uses section-scoped
    /// TOML where string values are always double-quoted; single-quoted
    /// strings and bare values are not part of that format. By contrast,
    /// `unquoteTOMLString` also handles single-quoted strings and bare
    /// values from Ghostty's flat config format. The inline handling here
    /// is intentional to match the stricter app config format.
    public static func parseAppConfigStringValue(
        sectionName: String,
        key: String,
        in contents: String
    ) -> String? {
        guard let value = parseAppConfigValue(
            sectionName: sectionName,
            key: key,
            in: contents
        ) else {
            return nil
        }
        guard value.hasPrefix("\""),
              value.hasSuffix("\""),
              value.count >= 2
        else {
            return value
        }
        return String(
            value
                .dropFirst()
                .dropLast()
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        )
    }

    /// Parse a TOML array of basic or literal strings under a named section.
    public static func parseAppConfigStringArrayValue(
        sectionName: String,
        key: String,
        in contents: String
    ) -> [String]? {
        guard let assignment = appConfigAssignment(
            sectionName: sectionName,
            key: key,
            in: contents
        ) else {
            return nil
        }
        var parser = TOMLStringArrayParser(assignment.value)
        return parser.parse()?.values
    }

    /// Locate every line occupied by a valid string-array assignment.
    public static func appConfigStringArrayLineRange(
        sectionName: String,
        key: String,
        in contents: String
    ) -> Range<Int>? {
        guard let assignment = appConfigAssignment(
            sectionName: sectionName,
            key: key,
            in: contents
        ) else {
            return nil
        }
        var parser = TOMLStringArrayParser(assignment.value)
        guard let parsed = parser.parse() else { return nil }
        let occupiedLineCount = assignment.value[..<parsed.endIndex]
            .reduce(into: 1) { count, character in
                if character.isNewline {
                    count += 1
                }
            }
        return assignment.lineIndex ..< (
            assignment.lineIndex + occupiedLineCount
        )
    }

    /// Parse a boolean value under a named section.
    public static func parseAppConfigBoolValue(
        sectionName: String,
        key: String,
        in contents: String
    ) -> Bool? {
        guard let value = parseAppConfigValue(
            sectionName: sectionName,
            key: key,
            in: contents
        ) else {
            return nil
        }

        switch value.lowercased() {
        case "true", "yes", "on", "1":
            return true
        case "false", "no", "off", "0":
            return false
        default:
            return nil
        }
    }

    /// Parse a Double value under a named section.
    public static func parseAppConfigDoubleValue(
        sectionName: String,
        key: String,
        in contents: String
    ) -> Double? {
        guard let value = parseAppConfigValue(
            sectionName: sectionName,
            key: key,
            in: contents
        ) else {
            return nil
        }
        return Double(value)
    }

    private static func appConfigAssignment(
        sectionName: String,
        key: String,
        in contents: String
    ) -> (value: String, lineIndex: Int)? {
        let lines = contents.components(separatedBy: "\n")
        var currentSection: String?

        for (lineIndex, rawLine) in lines.enumerated() {
            let line = strippedTOMLLine(rawLine)
            guard !line.isEmpty else { continue }
            if let headerName = sectionHeaderName(from: line) {
                currentSection = headerName
                continue
            }
            guard currentSection == sectionName,
                  let separatorIndex = line.firstIndex(of: "=")
            else {
                continue
            }
            let candidateKey = line[..<separatorIndex]
                .trimmingCharacters(in: .whitespaces)
            guard candidateKey == key else { continue }

            let firstLine = line[line.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespaces)
            let sectionEnd = lines[(lineIndex + 1)...]
                .firstIndex(where: { candidate in
                    sectionHeaderName(
                        from: strippedTOMLLine(candidate)
                    ) != nil
                }) ?? lines.endIndex
            let continuation = lines[(lineIndex + 1) ..< sectionEnd]
            return (
                ([String(firstLine)] + Array(continuation))
                    .joined(separator: "\n"),
                lineIndex
            )
        }
        return nil
    }
}

private struct TOMLStringArrayParser {
    struct Result {
        var values: [String]
        var endIndex: String.Index
    }

    private let source: String
    private var index: String.Index

    init(_ source: String) {
        self.source = source
        index = source.startIndex
    }

    mutating func parse() -> Result? {
        skipTrivia()
        guard consume("[") else { return nil }
        skipTrivia()
        if consume("]") {
            return Result(values: [], endIndex: index)
        }

        var values: [String] = []
        while true {
            guard let value = parseString() else { return nil }
            values.append(value)
            skipTrivia()
            if consume("]") {
                return Result(values: values, endIndex: index)
            }
            guard consume(",") else { return nil }
            skipTrivia()
            if consume("]") {
                return Result(values: values, endIndex: index)
            }
        }
    }

    private mutating func parseString() -> String? {
        if hasPrefix("\"\"\"") {
            return parseMultilineString(delimiter: "\"", basic: true)
        }
        if hasPrefix("'''") {
            return parseMultilineString(delimiter: "'", basic: false)
        }
        if consume("\"") {
            return parseSingleLineString(delimiter: "\"", basic: true)
        }
        if consume("'") {
            return parseSingleLineString(delimiter: "'", basic: false)
        }
        return nil
    }

    private mutating func parseSingleLineString(
        delimiter: Character,
        basic: Bool
    ) -> String? {
        var result = ""
        while let character = currentCharacter {
            advance()
            if character == delimiter {
                return result
            }
            guard !character.isNewline else { return nil }
            if basic, character == "\\" {
                guard let escaped = parseEscape() else { return nil }
                result.append(contentsOf: escaped)
            } else {
                result.append(character)
            }
        }
        return nil
    }

    private mutating func parseMultilineString(
        delimiter: Character,
        basic: Bool
    ) -> String? {
        advance(by: 3)
        consumeOpeningNewline()
        var result = ""
        let closing = String(repeating: delimiter, count: 3)

        while currentCharacter != nil {
            if hasPrefix(closing) {
                advance(by: 3)
                return result
            }
            guard let character = currentCharacter else { return nil }
            advance()
            if basic, character == "\\" {
                if consumeNewline() {
                    skipWhitespaceAndNewlines()
                    continue
                }
                guard let escaped = parseEscape() else { return nil }
                result.append(contentsOf: escaped)
            } else {
                result.append(character)
            }
        }
        return nil
    }

    private mutating func parseEscape() -> String? {
        guard let character = currentCharacter else { return nil }
        advance()
        switch character {
        case "b":
            return "\u{8}"
        case "t":
            return "\t"
        case "n":
            return "\n"
        case "f":
            return "\u{C}"
        case "r":
            return "\r"
        case "\"":
            return "\""
        case "\\":
            return "\\"
        case "u":
            return parseUnicodeEscape(length: 4)
        case "U":
            return parseUnicodeEscape(length: 8)
        default:
            return nil
        }
    }

    private mutating func parseUnicodeEscape(length: Int) -> String? {
        var digits = ""
        for _ in 0 ..< length {
            guard let character = currentCharacter,
                  character.isHexDigit
            else {
                return nil
            }
            digits.append(character)
            advance()
        }
        guard let value = UInt32(digits, radix: 16),
              let scalar = UnicodeScalar(value)
        else {
            return nil
        }
        return String(scalar)
    }

    private mutating func skipTrivia() {
        while let character = currentCharacter {
            if character.isWhitespace {
                advance()
            } else if character == "#" {
                while let commentCharacter = currentCharacter,
                      !commentCharacter.isNewline {
                    advance()
                }
            } else {
                return
            }
        }
    }

    private mutating func consumeOpeningNewline() {
        _ = consumeNewline()
    }

    private mutating func consumeNewline() -> Bool {
        if consume("\r") {
            _ = consume("\n")
            return true
        }
        return consume("\n")
    }

    private mutating func skipWhitespaceAndNewlines() {
        while let character = currentCharacter,
              character.isWhitespace {
            advance()
        }
    }

    private var currentCharacter: Character? {
        index < source.endIndex ? source[index] : nil
    }

    private func hasPrefix(_ value: String) -> Bool {
        source[index...].hasPrefix(value)
    }

    @discardableResult
    private mutating func consume(_ character: Character) -> Bool {
        guard currentCharacter == character else { return false }
        advance()
        return true
    }

    private mutating func advance(by count: Int = 1) {
        for _ in 0 ..< count where index < source.endIndex {
            index = source.index(after: index)
        }
    }
}
