import Foundation
import GhosthubWorkspace

enum AppConfigEditor {
    static func replacingString(
        sectionName: String,
        key: String,
        value: String?,
        in contents: String
    ) -> String {
        let newline = contents.contains("\r\n") ? "\r\n" : "\n"
        var lines = contents.components(separatedBy: newline)
        let renderedLine = value.map {
            "\(key) = \(TOMLConfigParser.renderTOMLString($0))"
        }

        guard let sectionIndex = lines.firstIndex(where: {
            TOMLConfigParser.sectionHeaderName(
                from: TOMLConfigParser.strippedTOMLLine($0)
            ) == sectionName
        }) else {
            guard let renderedLine else { return contents }
            var updated = contents
            if !updated.isEmpty, !updated.hasSuffix(newline) {
                updated += newline
            }
            if !updated.isEmpty, !updated.hasSuffix(newline + newline) {
                updated += newline
            }
            return updated + "[\(sectionName)]" + newline
                + renderedLine + newline
        }

        let sectionEnd = lines[(sectionIndex + 1)...].firstIndex(where: {
            TOMLConfigParser.sectionHeaderName(
                from: TOMLConfigParser.strippedTOMLLine($0)
            ) != nil
        }) ?? lines.endIndex
        if let keyIndex = lines[(sectionIndex + 1) ..< sectionEnd]
            .firstIndex(where: { assignmentKey(in: $0) == key }) {
            let oldLine = lines[keyIndex]
            let indentation = String(oldLine.prefix { $0.isWhitespace })
            let comment = inlineComment(in: oldLine)
            if let renderedLine {
                lines[keyIndex] = indentation + renderedLine
                    + (comment.map { " " + $0 } ?? "")
            } else if let comment {
                lines[keyIndex] = indentation + comment
            } else {
                lines.remove(at: keyIndex)
            }
        } else if let renderedLine {
            lines.insert(renderedLine, at: sectionEnd)
        }
        return lines.joined(separator: newline)
    }

    static func replacingStrings(
        sectionName: String,
        values: [String: String?],
        in contents: String
    ) -> String {
        values.keys.sorted().reduce(contents) { updated, key in
            replacingString(
                sectionName: sectionName,
                key: key,
                value: values[key] ?? nil,
                in: updated
            )
        }
    }

    static func replacingStringArray(
        sectionName: String,
        key: String,
        values: [String],
        in contents: String
    ) -> String {
        let renderedValues = values.map(
            TOMLConfigParser.renderTOMLString
        )
        let renderedValue = "[\(renderedValues.joined(separator: ", "))]"
        let renderedLine = "\(key) = \(renderedValue)"
        let newline = contents.contains("\r\n") ? "\r\n" : "\n"
        var lines = contents.components(separatedBy: newline)
        let sectionHeader = "[\(sectionName)]"

        guard let sectionIndex = lines.firstIndex(where: {
            TOMLConfigParser.sectionHeaderName(
                from: TOMLConfigParser.strippedTOMLLine($0)
            ) == sectionName
        }) else {
            var updated = contents
            if !updated.isEmpty, !updated.hasSuffix(newline) {
                updated += newline
            }
            if !updated.isEmpty, !updated.hasSuffix(newline + newline) {
                updated += newline
            }
            return updated + sectionHeader + newline + renderedLine + newline
        }

        let sectionEnd = lines[(sectionIndex + 1)...].firstIndex(where: {
            TOMLConfigParser.sectionHeaderName(
                from: TOMLConfigParser.strippedTOMLLine($0)
            ) != nil
        }) ?? lines.endIndex
        if let keyIndex = lines[(sectionIndex + 1) ..< sectionEnd]
            .firstIndex(where: { line in
                let trimmed = TOMLConfigParser.strippedTOMLLine(line)
                guard trimmed.hasPrefix(key) else { return false }
                let remainder = trimmed.dropFirst(key.count)
                    .trimmingCharacters(in: .whitespaces)
                return remainder.hasPrefix("=")
            }) {
            let valueRange = TOMLConfigParser
                .appConfigStringArrayLineRange(
                    sectionName: sectionName,
                    key: key,
                    in: contents
                ) ?? keyIndex ..< (keyIndex + 1)
            lines.replaceSubrange(valueRange, with: [renderedLine])
        } else {
            lines.insert(renderedLine, at: sectionEnd)
        }
        return lines.joined(separator: newline)
    }

    private static func assignmentKey(in rawLine: String) -> String? {
        let line = TOMLConfigParser.strippedTOMLLine(rawLine)
        guard let separatorIndex = line.firstIndex(of: "=") else {
            return nil
        }
        return line[..<separatorIndex]
            .trimmingCharacters(in: .whitespaces)
    }

    private static func inlineComment(in line: String) -> String? {
        var quote: Character?
        var isEscaped = false
        for index in line.indices {
            let character = line[index]
            if let activeQuote = quote {
                if character == activeQuote,
                   activeQuote == "'" || !isEscaped {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line[index...])
            }
            if quote == "\"", character == "\\", !isEscaped {
                isEscaped = true
            } else {
                isEscaped = false
            }
        }
        return nil
    }
}
