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
        var lines = contents.components(separatedBy: "\n")
        let sectionHeader = "[\(sectionName)]"

        guard let sectionIndex = lines.firstIndex(where: {
            TOMLConfigParser.strippedTOMLLine($0) == sectionHeader
        }) else {
            var updated = contents
            if !updated.isEmpty, !updated.hasSuffix("\n") {
                updated += "\n"
            }
            if !updated.isEmpty, !updated.hasSuffix("\n\n") {
                updated += "\n"
            }
            return updated + sectionHeader + "\n" + renderedLine + "\n"
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
        return lines.joined(separator: "\n")
    }
}
