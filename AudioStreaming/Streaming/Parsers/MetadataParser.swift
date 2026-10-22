//
//  Created by Dimitrios Chatzieleftheriou on 28/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

public enum MetadataParsingError: Error, Equatable {
    case unableToParse
    case empty
}

typealias MetadataOutput = Result<[String: String], MetadataParsingError>

struct MetadataParser: Parser {
    typealias Input = Data
    typealias Output = MetadataOutput

    /// ICY metadata is a run of `Key='value';` items, padded with zeros to a
    /// multiple of 16 bytes. A value may itself hold `'` and `;` —
    /// «Shakin' Shakin' Shakes», «Live; Unplugged» — so a quoted value ends at
    /// the quote that closes it: a `'` followed by the end of the block, or by
    /// `;` and then the end or the next `Key=`. Never at the first `;`, and no
    /// quote is deleted from inside a value.
    func parse(input: Data) -> MetadataOutput {
        guard let string = String(data: input, encoding: .utf8) else { return .failure(.unableToParse) }
        var rest = Substring(string.trimmingCharacters(in: CharacterSet(charactersIn: "\0")))
        var metadata: [String: String] = [:]

        while let equals = rest.firstIndex(of: "=") {
            let key = rest[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let valueStart = rest.index(after: equals)
            let value: Substring

            if valueStart < rest.endIndex, rest[valueStart] == "'" {
                let quoted = rest[rest.index(after: valueStart)...]
                let closing = closingQuote(in: quoted)
                value = quoted[..<closing]
                rest = closing < quoted.endIndex ? quoted[quoted.index(after: closing)...] : ""
                if rest.first == ";" { rest = rest.dropFirst() }
            } else {
                let end = rest[valueStart...].firstIndex(of: ";") ?? rest.endIndex
                value = rest[valueStart..<end]
                rest = end < rest.endIndex ? rest[rest.index(after: end)...] : ""
            }

            if !key.isEmpty {
                metadata[key] = String(value)
            }
        }

        guard !metadata.isEmpty else { return .failure(.empty) }
        return .success(metadata)
    }

    /// The `'` that closes a quoted value; the last `'` when none is followed
    /// by a delimiter, and the end when the value has no closing quote at all.
    private func closingQuote(in value: Substring) -> Substring.Index {
        var lastQuote: Substring.Index?
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "'" {
                if closesValue(value[value.index(after: index)...]) { return index }
                lastQuote = index
            }
            index = value.index(after: index)
        }
        return lastQuote ?? value.endIndex
    }

    /// What follows a closing quote: nothing, or `;` and then nothing or the
    /// next `Key=`.
    private func closesValue(_ following: Substring) -> Bool {
        guard let first = following.first else { return true }
        guard first == ";" else { return false }
        let next = following.dropFirst().drop(while: { $0 == " " })
        guard !next.isEmpty else { return true }
        let key = next.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
        return !key.isEmpty && next.dropFirst(key.count).first == "="
    }
}
