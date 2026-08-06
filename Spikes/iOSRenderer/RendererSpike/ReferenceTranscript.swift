import Foundation

enum ReferenceTranscript {
    static let bytes = Array(text.utf8)

    private static let text: String = {
        var lines = [
            "\u{1B}[2J\u{1B}[H",
            "\u{1B}[1;36mGhosthub iPad renderer spike\u{1B}[0m",
            "ANSI: \u{1B}[31mred\u{1B}[0m  \u{1B}[32mgreen\u{1B}[0m  \u{1B}[34mblue\u{1B}[0m",
            "Unicode: λ → 日本語 👻",
            "Cursor target: [waiting]",
            "",
        ]
        lines.append(contentsOf: (1 ... 80).map { row in
            String(format: "scroll row %02d  The renderer owns terminal presentation.", row)
        })

        return lines.joined(separator: "\r\n")
            + "\u{1B}[5;16H\u{1B}[1;33mupdated by cursor motion\u{1B}[0m"
            + "\u{1B}[999;1H"
    }()
}
