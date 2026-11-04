import XCTest
@testable import MuurCore

final class SmartPlaylistCompilerTests: XCTestCase {

    func testTextAndNumericRulesCompileToParameterizedSQL() {
        let definition = SmartPlaylistDefinition(
            name: "Jazz Favorites",
            match: .all,
            rules: [
                SmartRule(field: .genre, op: .is, value: .string("Jazz")),
                SmartRule(field: .playCount, op: .gt, value: .number(5)),
            ],
            sort: "-playCount",
            limit: 25
        )
        let query = SmartPlaylistCompiler.compile(definition)
        XCTAssertTrue(query.whereClause.contains("tracks.genre = ? COLLATE NOCASE"))
        XCTAssertTrue(query.whereClause.contains("tracks.playCount > ?"))
        XCTAssertTrue(query.whereClause.contains(" AND "))
        XCTAssertEqual(query.arguments, [.text("Jazz"), .integer(5)])
        XCTAssertTrue(query.orderBy.contains("playCount DESC"))
        XCTAssertEqual(query.limit, 25)
        XCTAssertTrue(query.sql.hasSuffix(" LIMIT 25"))
    }

    func testAnyMatchJoinsWithOr() {
        let definition = SmartPlaylistDefinition(
            name: "Either",
            match: .any,
            rules: [
                SmartRule(field: .artist, op: .contains, value: .string("Miles")),
                SmartRule(field: .favorite, op: .is, value: .bool(true)),
            ]
        )
        let query = SmartPlaylistCompiler.compile(definition)
        XCTAssertTrue(query.whereClause.contains(" OR "))
        XCTAssertTrue(query.whereClause.contains("tracks.artist LIKE ? ESCAPE '\\'"))
        XCTAssertTrue(query.whereClause.contains("tracks.favorite = ?"))
        XCTAssertEqual(query.arguments, [.text("%Miles%"), .integer(1)])
    }

    func testInvalidRulesAreIgnoredAndBetweenSwapsBounds() {
        let definition = SmartPlaylistDefinition(
            name: "Mixed",
            rules: [
                SmartRule(field: .genre, op: .inLast, value: .string("x")), // not applicable to text
                SmartRule(field: .year, op: .between, value: .number(2020), value2: .number(1990)),
            ]
        )
        let query = SmartPlaylistCompiler.compile(definition)
        XCTAssertFalse(query.whereClause.contains("genre"))
        XCTAssertTrue(query.whereClause.contains("tracks.year BETWEEN ? AND ?"))
        XCTAssertEqual(query.arguments, [.integer(1990), .integer(2020)])
    }

    func testEmptyRuleSetMatchesEverything() {
        let query = SmartPlaylistCompiler.compile(SmartPlaylistDefinition(name: "All"))
        XCTAssertEqual(query.whereClause, "1")
        XCTAssertEqual(query.limit, 0)
        XCTAssertFalse(query.sql.contains("LIMIT"))
    }

    func testSortSpecAliasesAndRandom() {
        XCTAssertTrue(SmartPlaylistCompiler.orderBy("random").contains("RANDOM()"))
        XCTAssertTrue(SmartPlaylistCompiler.orderBy("-plays").contains("playCount DESC"))
        XCTAssertTrue(SmartPlaylistCompiler.orderBy("+added").contains("dateAdded ASC"))
    }

    func testLikeWildcardsAreEscaped() {
        let rule = SmartRule(field: .title, op: .contains, value: .string("100%_"))
        let condition = SmartPlaylistCompiler.condition(for: rule)
        XCTAssertEqual(condition?.arguments, [.text("%100\\%\\_%")])
    }

    func testCompiledQueryExecutesAgainstTheRealSchema() async throws {
        let database = try MuurDatabase.inMemory()
        let repository = LibraryRepository(database: database)
        _ = try await repository.upsert([
            Track(sourceURI: "file:///a.flac", title: "A", genre: "Jazz", playCount: 10),
            Track(sourceURI: "file:///b.flac", title: "B", genre: "Rock", playCount: 1),
            Track(sourceURI: "file:///c.flac", title: "C", genre: "jazz", playCount: 0),
        ])
        let definition = SmartPlaylistDefinition(
            name: "Jazz played",
            rules: [
                SmartRule(field: .genre, op: .is, value: .string("Jazz")),
                SmartRule(field: .playCount, op: .gt, value: .number(5)),
            ],
            sort: "title"
        )
        let query = SmartPlaylistCompiler.compile(definition)
        let tracks = try await database.read { db in try query.fetch(db) }
        XCTAssertEqual(tracks.map(\.title), ["A"]) // case-insensitive genre match, playCount filter
    }
}
