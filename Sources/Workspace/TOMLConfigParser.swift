import Foundation

/// Pure-function helpers for parsing and rendering TOML config values.
/// Extracted from SettingsStore to keep parsing logic isolated and testable.
public enum TOMLConfigParser {

    // MARK: - Line Stripping

    /// Strip inline comments from a raw TOML line, respecting quoted strings.
    public static func strippedTOMLLine(_ rawLine: String) -> String {
        var result = ""
        var inQuotes = false
        var isEscaped = false

        for character in rawLine {
            if character == "\"", !isEscaped {
                inQuotes.toggle()
            }
            if character == "#", !inQuotes {
                break
            }
            result.append(character)
            if character == "\\", !isEscaped {
                isEscaped = true
            } else {
                isEscaped = false
            }
        }

        return result.trimmingCharacters(in: .whitespaces)
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
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
}
