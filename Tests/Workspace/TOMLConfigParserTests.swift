import Testing
@testable import GhosthubWorkspace

struct TOMLConfigParserTests {

    // MARK: - strippedTOMLLine

    @Test func strippedTOMLLine_removesInlineComment() {
        let result = TOMLConfigParser.strippedTOMLLine(
            "key = value # comment"
        )
        #expect(result == "key = value")
    }

    @Test func strippedTOMLLine_preservesHashInsideQuotes() {
        let result = TOMLConfigParser.strippedTOMLLine(
            "key = \"value # not a comment\""
        )
        #expect(result == "key = \"value # not a comment\"")
    }

    @Test func strippedTOMLLine_handlesEscapedQuote() {
        let result = TOMLConfigParser.strippedTOMLLine(
            "key = \"val\\\"ue\" # comment"
        )
        #expect(result == "key = \"val\\\"ue\"")
    }

    @Test func strippedTOMLLine_commentOnlyLine() {
        let result = TOMLConfigParser.strippedTOMLLine("# just a comment")
        #expect(result == "")
    }

    @Test func strippedTOMLLine_emptyLine() {
        let result = TOMLConfigParser.strippedTOMLLine("   ")
        #expect(result == "")
    }

    @Test func strippedTOMLLine_trimsWhitespace() {
        let result = TOMLConfigParser.strippedTOMLLine("  key = value  ")
        #expect(result == "key = value")
    }

    // MARK: - sectionHeaderName

    @Test func sectionHeaderName_validHeader() {
        #expect(
            TOMLConfigParser.sectionHeaderName(from: "[appearance]")
                == "appearance"
        )
    }

    @Test func sectionHeaderName_withWhitespace() {
        #expect(
            TOMLConfigParser.sectionHeaderName(from: "[ appearance ]")
                == "appearance"
        )
    }

    @Test func sectionHeaderName_notAHeader() {
        #expect(
            TOMLConfigParser.sectionHeaderName(from: "key = value") == nil
        )
    }

    @Test func sectionHeaderName_emptyBrackets() {
        #expect(
            TOMLConfigParser.sectionHeaderName(from: "[]") == ""
        )
    }

    // MARK: - unquoteTOMLString

    @Test func unquoteTOMLString_doubleQuoted() {
        #expect(
            TOMLConfigParser.unquoteTOMLString("\"hello\"") == "hello"
        )
    }

    @Test func unquoteTOMLString_singleQuoted() {
        #expect(
            TOMLConfigParser.unquoteTOMLString("'hello'") == "hello"
        )
    }

    @Test func unquoteTOMLString_unquoted() {
        #expect(
            TOMLConfigParser.unquoteTOMLString("hello") == "hello"
        )
    }

    @Test func unquoteTOMLString_escapedBackslash() {
        #expect(
            TOMLConfigParser.unquoteTOMLString("\"a\\\\b\"") == "a\\b"
        )
    }

    @Test func unquoteTOMLString_escapedQuote() {
        #expect(
            TOMLConfigParser.unquoteTOMLString("\"a\\\"b\"") == "a\"b"
        )
    }

    @Test func unquoteTOMLString_singleQuoteNoEscape() {
        // Single-quoted strings are literal in TOML
        #expect(
            TOMLConfigParser.unquoteTOMLString("'a\\\\b'") == "a\\\\b"
        )
    }

    // MARK: - renderTOMLString

    @Test func renderTOMLString_simple() {
        #expect(
            TOMLConfigParser.renderTOMLString("hello") == "\"hello\""
        )
    }

    @Test func renderTOMLString_escapesBackslash() {
        #expect(
            TOMLConfigParser.renderTOMLString("a\\b") == "\"a\\\\b\""
        )
    }

    @Test func renderTOMLString_escapesQuote() {
        #expect(
            TOMLConfigParser.renderTOMLString("a\"b") == "\"a\\\"b\""
        )
    }

    // MARK: - renderTOMLNumber

    @Test func renderTOMLNumber_wholeNumber() {
        #expect(TOMLConfigParser.renderTOMLNumber(14.0) == "14")
    }

    @Test func renderTOMLNumber_fractional() {
        #expect(TOMLConfigParser.renderTOMLNumber(14.5) == "14.5")
    }

    @Test func renderTOMLNumber_zero() {
        #expect(TOMLConfigParser.renderTOMLNumber(0.0) == "0")
    }

    // MARK: - parseConfigValue

    @Test func parseConfigValue_findsKey() {
        let contents = "font-size = 14\nfont-family = \"Menlo\""
        #expect(
            TOMLConfigParser.parseConfigValue(
                for: "font-size", in: contents
            ) == "14"
        )
    }

    @Test func parseConfigValue_lastOccurrenceWins() {
        let contents = "key = first\nkey = second"
        #expect(
            TOMLConfigParser.parseConfigValue(
                for: "key", in: contents
            ) == "second"
        )
    }

    @Test func parseConfigValue_missingKey() {
        let contents = "font-size = 14"
        #expect(
            TOMLConfigParser.parseConfigValue(
                for: "missing", in: contents
            ) == nil
        )
    }

    @Test func parseConfigValue_ignoresComments() {
        let contents = "# key = commented\nkey = real"
        #expect(
            TOMLConfigParser.parseConfigValue(
                for: "key", in: contents
            ) == "real"
        )
    }

    @Test func parseConfigValue_stripsInlineComment() {
        let contents = "key = value # inline comment"
        #expect(
            TOMLConfigParser.parseConfigValue(
                for: "key", in: contents
            ) == "value"
        )
    }

    // MARK: - parseBoolConfigValue

    @Test(arguments: ["true", "yes", "on", "1"])
    func parseBoolConfigValue_trueVariants(literal: String) {
        let contents = "flag = \(literal)"
        #expect(
            TOMLConfigParser.parseBoolConfigValue(
                for: "flag", in: contents
            ) == true
        )
    }

    @Test(arguments: ["false", "no", "off", "0"])
    func parseBoolConfigValue_falseVariants(literal: String) {
        let contents = "flag = \(literal)"
        #expect(
            TOMLConfigParser.parseBoolConfigValue(
                for: "flag", in: contents
            ) == false
        )
    }

    @Test func parseBoolConfigValue_invalidValue() {
        let contents = "flag = maybe"
        #expect(
            TOMLConfigParser.parseBoolConfigValue(
                for: "flag", in: contents
            ) == nil
        )
    }

    @Test func parseBoolConfigValue_missingKey() {
        #expect(
            TOMLConfigParser.parseBoolConfigValue(
                for: "flag", in: ""
            ) == nil
        )
    }

    // MARK: - parseCopyOnSelect

    @Test(arguments: ["clipboard", "true", "yes", "on", "1"])
    func parseCopyOnSelect_trueVariants(literal: String) {
        let contents = "copy-on-select = \(literal)"
        #expect(
            TOMLConfigParser.parseCopyOnSelect(in: contents) == true
        )
    }

    @Test(arguments: ["false", "no", "off", "0", "none"])
    func parseCopyOnSelect_falseVariants(literal: String) {
        let contents = "copy-on-select = \(literal)"
        #expect(
            TOMLConfigParser.parseCopyOnSelect(in: contents) == false
        )
    }

    @Test func parseCopyOnSelect_unknown() {
        let contents = "copy-on-select = primary"
        #expect(
            TOMLConfigParser.parseCopyOnSelect(in: contents) == nil
        )
    }

    // MARK: - parseShellIntegrationCursorBehavior

    @Test func parseShellIntegrationCursorBehavior_noCursorFeature() {
        let contents = "shell-integration-features = no-cursor,title"
        #expect(
            TOMLConfigParser.parseShellIntegrationCursorBehavior(
                in: contents
            ) == false
        )
    }

    @Test func parseShellIntegrationCursorBehavior_withCursor() {
        let contents = "shell-integration-features = title,cursor"
        #expect(
            TOMLConfigParser.parseShellIntegrationCursorBehavior(
                in: contents
            ) == true
        )
    }

    @Test func parseShellIntegrationCursorBehavior_missingKey() {
        #expect(
            TOMLConfigParser.parseShellIntegrationCursorBehavior(
                in: ""
            ) == nil
        )
    }

    // MARK: - parseAppConfigValue

    @Test func parseAppConfigValue_findsKeyInSection() {
        let contents = """
        [appearance]
        theme = "dark"
        font_size = 14
        """
        #expect(
            TOMLConfigParser.parseAppConfigValue(
                sectionName: "appearance",
                key: "theme",
                in: contents
            ) == "\"dark\""
        )
    }

    @Test func parseAppConfigValue_ignoresWrongSection() {
        let contents = """
        [other]
        theme = "dark"
        [appearance]
        font_size = 14
        """
        #expect(
            TOMLConfigParser.parseAppConfigValue(
                sectionName: "appearance",
                key: "theme",
                in: contents
            ) == nil
        )
    }

    @Test func parseAppConfigValue_missingSection() {
        let contents = "theme = \"dark\""
        #expect(
            TOMLConfigParser.parseAppConfigValue(
                sectionName: "appearance",
                key: "theme",
                in: contents
            ) == nil
        )
    }

    // MARK: - parseAppConfigStringValue

    @Test func parseAppConfigStringValue_unquotesValue() {
        let contents = """
        [section]
        name = "hello world"
        """
        #expect(
            TOMLConfigParser.parseAppConfigStringValue(
                sectionName: "section",
                key: "name",
                in: contents
            ) == "hello world"
        )
    }

    @Test func parseAppConfigStringValue_unquotedFallback() {
        let contents = """
        [section]
        name = bare
        """
        #expect(
            TOMLConfigParser.parseAppConfigStringValue(
                sectionName: "section",
                key: "name",
                in: contents
            ) == "bare"
        )
    }

    @Test func parseAppConfigStringValue_escapedContent() {
        let contents = """
        [section]
        path = "a\\\\b"
        """
        #expect(
            TOMLConfigParser.parseAppConfigStringValue(
                sectionName: "section",
                key: "path",
                in: contents
            ) == "a\\b"
        )
    }

    // MARK: - parseAppConfigBoolValue

    @Test func parseAppConfigBoolValue_true() {
        let contents = """
        [section]
        enabled = true
        """
        #expect(
            TOMLConfigParser.parseAppConfigBoolValue(
                sectionName: "section",
                key: "enabled",
                in: contents
            ) == true
        )
    }

    @Test func parseAppConfigBoolValue_false() {
        let contents = """
        [section]
        enabled = off
        """
        #expect(
            TOMLConfigParser.parseAppConfigBoolValue(
                sectionName: "section",
                key: "enabled",
                in: contents
            ) == false
        )
    }

    @Test func parseAppConfigBoolValue_missing() {
        let contents = "[section]"
        #expect(
            TOMLConfigParser.parseAppConfigBoolValue(
                sectionName: "section",
                key: "enabled",
                in: contents
            ) == nil
        )
    }

    // MARK: - parseAppConfigDoubleValue

    @Test func parseAppConfigDoubleValue_integer() {
        let contents = """
        [section]
        size = 14
        """
        #expect(
            TOMLConfigParser.parseAppConfigDoubleValue(
                sectionName: "section",
                key: "size",
                in: contents
            ) == 14.0
        )
    }

    @Test func parseAppConfigDoubleValue_fractional() {
        let contents = """
        [section]
        opacity = 0.85
        """
        #expect(
            TOMLConfigParser.parseAppConfigDoubleValue(
                sectionName: "section",
                key: "opacity",
                in: contents
            ) == 0.85
        )
    }

    @Test func parseAppConfigDoubleValue_nonNumeric() {
        let contents = """
        [section]
        value = abc
        """
        #expect(
            TOMLConfigParser.parseAppConfigDoubleValue(
                sectionName: "section",
                key: "value",
                in: contents
            ) == nil
        )
    }

    // MARK: - Roundtrip

    @Test func renderThenUnquote_roundtrips() {
        let original = "path/to/\"file\""
        let rendered = TOMLConfigParser.renderTOMLString(original)
        let recovered = TOMLConfigParser.unquoteTOMLString(rendered)
        #expect(recovered == original)
    }
}
