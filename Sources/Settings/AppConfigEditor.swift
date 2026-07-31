import Foundation
import GhosthubWorkspace

enum AppConfigEditor {
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
}
