//
//  MetadataParser.swift
//  AudioStreamingTests
//
//  Created by Dimitrios Chatzieleftheriou on 01/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import XCTest

@testable import AudioStreaming

class MetadataParserTests: XCTestCase {
    /// NOTE: Usual metadata values from icy stream are in the following format
    /// "StreamTtitle='A song title - Artist';StreamProducer='A producer'"

    func testParserOutputsCorrectResultFromCorrectData() throws {
        let string = "StreamTitle='A song - Artist';StreamSong='A song';StreamArtist='Artist';"
        let data = string.data(using: .utf8)!

        let parser = MetadataParser()

        let output = parser.parse(input: data)

        switch output {
        case let .success(values):
            XCTAssertFalse(values.isEmpty)
            XCTAssertEqual(values["StreamTitle"], "A song - Artist")
            XCTAssertEqual(values["StreamSong"], "A song")
            XCTAssertEqual(values["StreamArtist"], "Artist")
        case .failure:
            XCTFail()
        }
    }

    func testParserOutputsCorrectResultFromActualRawDataOfAudioStream() throws {
        let string = "StreamTitle=\'Gramatik - In This Whole World (Original Mix)\';\0\0\0\0"
        let data = string.data(using: .utf8)!

        let parser = MetadataParser()

        let output = parser.parse(input: data)

        switch output {
        case let .success(values):
            XCTAssertFalse(values.isEmpty)
            XCTAssertEqual(values["StreamTitle"], "Gramatik - In This Whole World (Original Mix)")
        case .failure:
            XCTFail()
        }
    }

    func testParserOutputsCorrectResultWhenEntryContainsEqualSign() throws {
        let string = "StreamTitle=\'Gramatik - In This Whole World (Original Mix)\';StreamUrl=\'\';track_info=\'k4Smc3RhdHVzoUihQNJiGp6BpHR5cGWhVKJpZKhNWDUxMTYzNISmc3RhdHVzoUOhQNJiGp9cpHR5cGWhVKJpZKhNWDUxMDM3MoSmc3RhdHVzoUOhQNJiGqAqpHR5cGWhVKJpZKhNWDUxMjA5Ng==\';UTC=\'20220226T214447.206\';\0\0\0\0\0\0\0\0\0"
        let data = string.data(using: .utf8)!

        let parser = MetadataParser()

        let output = parser.parse(input: data)

        switch output {
        case let .success(values):
            XCTAssertFalse(values.isEmpty)
            XCTAssertEqual(values["StreamTitle"], "Gramatik - In This Whole World (Original Mix)")
            XCTAssertEqual(values["StreamUrl"], "")
            XCTAssertEqual(values["track_info"], "k4Smc3RhdHVzoUihQNJiGp6BpHR5cGWhVKJpZKhNWDUxMTYzNISmc3RhdHVzoUOhQNJiGp9cpHR5cGWhVKJpZKhNWDUxMDM3MoSmc3RhdHVzoUOhQNJiGqAqpHR5cGWhVKJpZKhNWDUxMjA5Ng==")
            XCTAssertEqual(values["UTC"], "20220226T214447.206")
        case .failure:
            XCTFail()
        }
    }

    // MARK: - A value ends at its closing quote (radio-tech-docs#1916)

    private func parsed(_ string: String) -> [String: String]? {
        guard case let .success(values) = MetadataParser().parse(input: string.data(using: .utf8)!) else {
            return nil
        }
        return values
    }

    /// Every `'` was deleted from every value: «Shakin' Shakin' Shakes» read
    /// «Shakin Shakin Shakes».
    func testParserKeepsApostrophesInsideTheValue() throws {
        let values = parsed("StreamTitle='The Shakin' Shakin' Shakes - Shakin' Shakin' Shakes';\0\0")
        XCTAssertEqual(values, ["StreamTitle": "The Shakin' Shakin' Shakes - Shakin' Shakin' Shakes"])
    }

    /// The block was split on every `;`, so the title ended at its own
    /// semicolon and the tail became a key of its own.
    func testParserKeepsSemicolonsInsideTheValue() throws {
        let values = parsed("StreamTitle='Artist - Live; Unplugged';\0\0\0")
        XCTAssertEqual(values, ["StreamTitle": "Artist - Live; Unplugged"])
    }

    /// Both at once, followed by a `StreamUrl` whose own query holds a `;`.
    func testParserSeparatesStreamTitleFromStreamUrl() throws {
        let values = parsed(
            "StreamTitle='Guns N' Roses - Sweet Child o' Mine; Live';StreamUrl='https://example.com/cover.jpg?a=1;b=2';\0"
        )
        XCTAssertEqual(values, [
            "StreamTitle": "Guns N' Roses - Sweet Child o' Mine; Live",
            "StreamUrl": "https://example.com/cover.jpg?a=1;b=2",
        ])
    }

    /// An apostrophe right before a `;` closes nothing unless the next `Key=`
    /// or the end follows; one right before the closing quote stays.
    func testParserFindsTheClosingQuoteNextToOtherQuotes() throws {
        XCTAssertEqual(parsed("StreamTitle='Shakin'; Shakes';"), ["StreamTitle": "Shakin'; Shakes"])
        XCTAssertEqual(parsed("StreamTitle='Rockin'';StreamUrl='';"), ["StreamTitle": "Rockin'", "StreamUrl": ""])
    }

    /// The shapes around the quoted one: no trailing `;`, an unquoted value,
    /// an empty unquoted value, and a value whose closing quote never came.
    func testParserReadsValuesWithoutTheUsualDelimiters() throws {
        XCTAssertEqual(parsed("StreamTitle='Shakin' Shakes'"), ["StreamTitle": "Shakin' Shakes"])
        XCTAssertEqual(parsed("StreamTitle=Plain title;StreamUrl=;"), ["StreamTitle": "Plain title", "StreamUrl": ""])
        XCTAssertEqual(parsed("StreamTitle='Cut off"), ["StreamTitle": "Cut off"])
    }

    func testParserOutputsFailureOnEmptyStringData() throws {
        let data = "".data(using: .utf8)!
        let parser = MetadataParser()

        let output = parser.parse(input: data)

        switch output {
        case .success:
            XCTFail()
        case let .failure(error):
            XCTAssertEqual(error, MetadataParsingError.empty)
        }
    }
}
