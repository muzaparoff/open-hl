// SPDX-License-Identifier: MIT

import Foundation

/// Loads JSON fixture files bundled with the test target.
///
/// Fixtures live in `Tests/HyperliquidAPITests/Fixtures/` and are declared
/// as `.process("Fixtures")` resources in the test target's `Package.swift`.
/// `Bundle.module` resolves to the test bundle at runtime.
enum FixtureLoader {

    enum Error: Swift.Error {
        case fileNotFound(String)
        case readFailed(String, underlying: Swift.Error)
    }

    /// Loads `<name>.jsonl` from the `Fixtures` subdirectory of the test bundle
    /// and returns one `Data` per non-empty line.
    ///
    /// Each line in a `.jsonl` file is an independent JSON document (as
    /// captured from a WebSocket session). Empty lines (trailing newline) are
    /// silently ignored.
    static func loadLines(_ name: String) throws -> [Data] {
        let fileName = name.hasSuffix(".jsonl") ? name : "\(name).jsonl"
        guard
            let url = Bundle.module.url(
                forResource: fileName,
                withExtension: nil,
                subdirectory: "Fixtures"
            )
        else {
            throw Error.fileNotFound(fileName)
        }
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            throw Error.readFailed(fileName, underlying: error)
        }
        let text = String(decoding: raw, as: UTF8.self)
        return
            text
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { Data($0.utf8) }
    }

    /// Loads `<name>.json` from the `Fixtures` subdirectory of the test bundle.
    static func load(_ name: String) throws -> Data {
        let fileName = name.hasSuffix(".json") ? name : "\(name).json"
        guard
            let url = Bundle.module.url(
                forResource: fileName,
                withExtension: nil,
                subdirectory: "Fixtures"
            )
        else {
            throw Error.fileNotFound(fileName)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw Error.readFailed(fileName, underlying: error)
        }
    }
}
