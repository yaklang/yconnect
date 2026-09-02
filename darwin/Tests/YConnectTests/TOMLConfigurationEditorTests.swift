import Foundation
import XCTest
@testable import YConnect

final class TOMLConfigurationEditorTests: XCTestCase {
    func testCodexFixtureUpsertsRootAndReplacesManagedProviderTables() throws {
        let original = """
        # User-owned Codex comment must survive.
        model = "old-model#not-a-comment" # keep this inline comment
        model = "duplicate-model"
        model_provider = "legacy"

        [features]
        web_search = true
        note = "https://example.invalid/docs#fragment" # quoted hash is data

        [model_providers.other]
        name = "Other provider"
        base_url = "https://other.invalid/v1"

        [model_providers.yakcool]
        base_url = "https://old.invalid/v1"
        wire_api = "chat"

        [model_providers.yakcool.auth]
        command = "/old/helper"
        args = [
          "old",
          "arguments",
        ]

        [model_providers.yakcool.auth.metadata]
        owner = "user-owned-child"

        [[model_providers.yakcool]]
        name = "array-table-must-survive"
        """

        var editor = try TOMLConfigurationEditor(data: Data(original.utf8))
        try editor.upsertTopLevel(key: "model", value: .string("gpt-5.6-terra"))
        try editor.upsertTopLevel(key: "model_provider", value: .string("yakcool"))
        try editor.replaceManagedTable(
            named: "model_providers.yakcool",
            entries: [
                TOMLConfigurationEntry("name", .string("YakCool")),
                TOMLConfigurationEntry("base_url", .string("https://aibalance.yaklang.com/v1")),
                TOMLConfigurationEntry("env_key", .string("YAKCOOL_API_KEY")),
                TOMLConfigurationEntry("wire_api", .string("responses")),
            ]
        )
        try editor.replaceManagedTable(
            named: "model_providers.yakcool.auth",
            entries: [
                TOMLConfigurationEntry("command", .string("/Applications/YConnect.app/Contents/MacOS/yconnect-secret")),
                TOMLConfigurationEntry("args", .stringArray(["read", "yakcool"])),
                TOMLConfigurationEntry("timeout_ms", .integer(5_000)),
                TOMLConfigurationEntry("refresh_interval_ms", .integer(300_000)),
            ]
        )

        let rendered = try XCTUnwrap(String(data: editor.renderedData(), encoding: .utf8))
        XCTAssertEqual(exactLineCount("model = \"gpt-5.6-terra\" # keep this inline comment", in: rendered), 1)
        XCTAssertEqual(exactLineCount("model_provider = \"yakcool\"", in: rendered), 1)
        XCTAssertEqual(exactLineCount("[model_providers.yakcool]", in: rendered), 1)
        XCTAssertEqual(exactLineCount("[model_providers.yakcool.auth]", in: rendered), 1)
        XCTAssertTrue(rendered.contains("wire_api = \"responses\""))
        XCTAssertTrue(rendered.contains("args = [\"read\", \"yakcool\"]"))

        XCTAssertTrue(rendered.contains("# User-owned Codex comment must survive."))
        XCTAssertTrue(rendered.contains("note = \"https://example.invalid/docs#fragment\" # quoted hash is data"))
        XCTAssertTrue(rendered.contains("[model_providers.other]"))
        XCTAssertTrue(rendered.contains("base_url = \"https://other.invalid/v1\""))
        XCTAssertTrue(rendered.contains("[model_providers.yakcool.auth.metadata]"))
        XCTAssertTrue(rendered.contains("owner = \"user-owned-child\""))
        XCTAssertTrue(rendered.contains("[[model_providers.yakcool]]"))
        XCTAssertTrue(rendered.contains("name = \"array-table-must-survive\""))
        XCTAssertFalse(rendered.contains("duplicate-model"))
        XCTAssertFalse(rendered.contains("/old/helper"))
        XCTAssertFalse(rendered.contains("\"arguments\""))
    }

    func testGrokFixturePreservesCRLFAndQuotedHashes() throws {
        let originalLines = [
            "# Grok user config",
            "[ui]",
            "theme = \"rose#muted\" # this is a real comment",
            "",
            "[[model.yakcool]]",
            "name = \"array entry\"",
            "",
            "[models]",
            "default = \"old#model\" # preserve default comment",
            "web_search = \"user-search-model\"",
            "",
            "[model.yakcool]",
            "model = \"old\"",
            "base_url = \"https://old.invalid/v1#route\"",
            "",
            "[auth_provider.yconnect]",
            "command = \"/old/path#literal\" # replace me",
            "timeout_secs = 1",
            "",
            "[permission]",
            "rules = []",
        ]
        let original = originalLines.joined(separator: "\r\n") + "\r\n"
        var editor = try TOMLConfigurationEditor(data: Data(original.utf8))

        try editor.upsert(key: "default", value: .string("yakcool"), inTable: "models")
        try editor.replaceManagedTable(
            named: "model.yakcool",
            entries: [
                TOMLConfigurationEntry("model", .string("grok-4.6")),
                TOMLConfigurationEntry("base_url", .string("https://aibalance.yaklang.com/v1")),
                TOMLConfigurationEntry("name", .string("YakCool")),
                TOMLConfigurationEntry("api_backend", .string("responses")),
                TOMLConfigurationEntry("auth_provider", .string("yconnect")),
            ]
        )
        try editor.replaceManagedTable(
            named: "auth_provider.yconnect",
            entries: [
                TOMLConfigurationEntry("command", .string("/Applications/YConnect.app/Contents/MacOS/yconnect-secret")),
                TOMLConfigurationEntry("token_ttl_secs", .integer(300)),
                TOMLConfigurationEntry("timeout_secs", .integer(5)),
            ]
        )

        let data = editor.renderedData()
        let rendered = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(exactLineCount("default = \"yakcool\" # preserve default comment", in: rendered), 1)
        XCTAssertTrue(rendered.contains("theme = \"rose#muted\" # this is a real comment"))
        XCTAssertTrue(rendered.contains("web_search = \"user-search-model\""))
        XCTAssertTrue(rendered.contains("[[model.yakcool]]"))
        XCTAssertTrue(rendered.contains("name = \"array entry\""))
        XCTAssertTrue(rendered.contains("[permission]"))
        XCTAssertTrue(rendered.contains("api_backend = \"responses\""))
        XCTAssertFalse(rendered.contains("old.invalid"))
        XCTAssertFalse(rendered.contains("/old/path"))
        assertUsesOnlyCRLF(data)
    }

    func testEmptyDocumentRendersSafeEscapedStringsAsData() throws {
        var editor = TOMLConfigurationEditor()
        let hostile = "quote\" slash\\ newline\n tab\t hash# control\u{1} model_provider = \"evil\""

        try editor.upsertTopLevel(key: "model", value: .string(hostile))
        try editor.upsertTopLevel(key: "model_provider", value: .string("yakcool"))
        try editor.replaceManagedTable(
            named: "models",
            entries: [TOMLConfigurationEntry("default", .string("yakcool"))]
        )

        let data = editor.renderedData()
        let rendered = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(rendered.hasPrefix("model = \"quote\\\" slash\\\\ newline\\n tab\\t hash# control\\u0001 model_provider = \\\"evil\\\"\"\n"))
        XCTAssertEqual(exactLineCount("model_provider = \"yakcool\"", in: rendered), 1)
        XCTAssertEqual(exactLineCount("[models]", in: rendered), 1)
        XCTAssertEqual(exactLineCount("default = \"yakcool\"", in: rendered), 1)
        XCTAssertFalse(rendered.contains("\nmodel_provider = \"evil\"\n"))
        XCTAssertEqual(data, Data(rendered.utf8))
    }

    func testRemoveManagedTableIsExact() throws {
        let original = """
        [model.yakcool]
        model = "remove"

        [model.yakcool.metadata]
        owner = "keep-child"

        [[model.yakcool]]
        model = "keep-array"

        [model.yakcooler]
        model = "keep-prefix-neighbour"
        """
        var editor = try TOMLConfigurationEditor(data: Data(original.utf8))

        try editor.removeManagedTable(named: "model.yakcool")

        let rendered = try XCTUnwrap(String(data: editor.renderedData(), encoding: .utf8))
        XCTAssertEqual(exactLineCount("[model.yakcool]", in: rendered), 0)
        XCTAssertFalse(rendered.contains("model = \"remove\""))
        XCTAssertTrue(rendered.contains("[model.yakcool.metadata]"))
        XCTAssertTrue(rendered.contains("owner = \"keep-child\""))
        XCTAssertTrue(rendered.contains("[[model.yakcool]]"))
        XCTAssertTrue(rendered.contains("model = \"keep-array\""))
        XCTAssertTrue(rendered.contains("[model.yakcooler]"))
        XCTAssertTrue(rendered.contains("model = \"keep-prefix-neighbour\""))
    }

    func testRemoveManagedSubtreeRemovesDescendantsArraysAndDottedAssignmentsByComponent() throws {
        let original = """
        model.yakcool = { token = "inline-target" }
        model.yakcool.env_http_headers.Authorization = "Bearer dotted-secret"

        [model.yakcool]
        model = "remove"
        http_headers.Authorization = "Bearer local-dotted-secret"

        [model.yakcool.http_headers]
        Authorization = "Bearer child-secret"

        [[model.yakcool.aws]]
        token = "array-secret"

        # keep prefix-neighbour comment
        [model.yakcooler]
        token = "keep-prefix-neighbour"

        [model.other]
        note = "keep-unrelated"
        """
        var editor = try TOMLConfigurationEditor(data: Data(original.utf8))

        try editor.removeManagedSubtree(named: "model.yakcool")

        let rendered = try XCTUnwrap(String(data: editor.renderedData(), encoding: .utf8))
        for removed in [
            "inline-target",
            "dotted-secret",
            "local-dotted-secret",
            "child-secret",
            "array-secret",
            "[model.yakcool]",
            "[model.yakcool.http_headers]",
            "[[model.yakcool.aws]]",
        ] {
            XCTAssertFalse(rendered.contains(removed), "managed subtree residue: \(removed)")
        }
        XCTAssertTrue(rendered.contains("[model.yakcooler]"))
        XCTAssertTrue(rendered.contains("# keep prefix-neighbour comment"))
        XCTAssertTrue(rendered.contains("token = \"keep-prefix-neighbour\""))
        XCTAssertTrue(rendered.contains("[model.other]"))
        XCTAssertTrue(rendered.contains("note = \"keep-unrelated\""))
    }

    func testRemoveManagedSubtreeRejectsAncestorInlineAssignmentBeforeMutation() throws {
        let original = Data("""
        model = { yakcool = { token = "do-not-partially-edit" }, other = { enabled = true } }

        [unrelated]
        keep = true
        """.utf8)
        var editor = try TOMLConfigurationEditor(data: original)

        XCTAssertThrowsError(try editor.removeManagedSubtree(named: "model.yakcool")) { error in
            XCTAssertEqual(
                error as? TOMLConfigurationEditorError,
                .conflictingAncestorAssignment("model")
            )
        }
        XCTAssertEqual(editor.renderedData(), original)
    }

    func testTableUpsertDoesNotSelectArrayTable() throws {
        let original = """
        [[models]]
        default = "array-owned"
        """
        var editor = try TOMLConfigurationEditor(data: Data(original.utf8))

        try editor.upsert(key: "default", value: .string("yakcool"), inTable: "models")

        let rendered = try XCTUnwrap(String(data: editor.renderedData(), encoding: .utf8))
        XCTAssertTrue(rendered.contains("[[models]]\ndefault = \"array-owned\""))
        XCTAssertTrue(rendered.contains("[models]\ndefault = \"yakcool\""))
        XCTAssertEqual(exactLineCount("default = \"array-owned\"", in: rendered), 1)
        XCTAssertEqual(exactLineCount("default = \"yakcool\"", in: rendered), 1)
    }

    func testDuplicateManagedEntriesAreRejectedBeforeMutation() throws {
        let original = Data("# untouched\n".utf8)
        var editor = try TOMLConfigurationEditor(data: original)

        XCTAssertThrowsError(
            try editor.replaceManagedTable(
                named: "model.yakcool",
                entries: [
                    TOMLConfigurationEntry("model", .string("first")),
                    TOMLConfigurationEntry("model", .string("second")),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? TOMLConfigurationEditorError, .duplicateEntry("model"))
        }
        XCTAssertEqual(editor.renderedData(), original)
    }

    func testInvalidUTF8IsRejected() {
        XCTAssertThrowsError(try TOMLConfigurationEditor(data: Data([0xFF, 0xFE]))) { error in
            XCTAssertEqual(error as? TOMLConfigurationEditorError, .invalidUTF8)
        }
    }

    private func exactLineCount(_ expected: String, in text: String) -> Int {
        text.components(separatedBy: .newlines).filter { $0 == expected }.count
    }

    private func assertUsesOnlyCRLF(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0D {
                XCTAssertLessThan(index + 1, bytes.count, file: file, line: line)
                if index + 1 < bytes.count {
                    XCTAssertEqual(bytes[index + 1], 0x0A, file: file, line: line)
                }
                index += 2
                continue
            }
            XCTAssertNotEqual(bytes[index], 0x0A, file: file, line: line)
            index += 1
        }
    }
}
