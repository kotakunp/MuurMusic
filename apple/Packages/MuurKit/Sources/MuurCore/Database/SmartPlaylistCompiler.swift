import Foundation
import GRDB

/// A bound SQL value produced by `SmartPlaylistCompiler` (kept GRDB-independent for tests).
public enum SmartSQLValue: Hashable, Sendable {
    case text(String)
    case integer(Int64)
    case real(Double)

    var databaseValueConvertible: any DatabaseValueConvertible {
        switch self {
        case .text(let value): return value
        case .integer(let value): return value
        case .real(let value): return value
        }
    }
}

/// SQL compiled from a `SmartPlaylistDefinition`.
public struct CompiledSmartQuery: Hashable, Sendable {
    /// WHERE clause over the `tracks` table ("1" when there are no usable rules).
    public var whereClause: String
    public var arguments: [SmartSQLValue]
    public var orderBy: String
    /// 0 = unlimited.
    public var limit: Int

    public init(whereClause: String, arguments: [SmartSQLValue], orderBy: String, limit: Int) {
        self.whereClause = whereClause
        self.arguments = arguments
        self.orderBy = orderBy
        self.limit = limit
    }

    public var sql: String {
        var sql = "SELECT tracks.* FROM tracks WHERE \(whereClause) ORDER BY \(orderBy)"
        if limit > 0 { sql += " LIMIT \(limit)" }
        return sql
    }

    public var statementArguments: StatementArguments {
        StatementArguments(arguments.map { $0.databaseValueConvertible as (any DatabaseValueConvertible)? })
    }

    /// Runs the query.
    public func fetch(_ db: Database) throws -> [Track] {
        try Track.fetchAll(db, sql: sql, arguments: statementArguments)
    }
}

/// Translates smart playlist rules (SHARED_FORMATS `muur-smart`) into SQL.
///
/// Rule semantics:
/// - Text fields (`genre`, `artist`, `albumArtist`, `album`, `composer`, `title`, `format`): `is`/`isNot` compare
///   case-insensitively, `contains`/`startsWith` use `LIKE`, `gt`/`lt`/`between` compare case-insensitively.
/// - Numeric fields: `is`, `isNot`, `gt`, `lt`, `between` (inclusive).
/// - Date fields (`dateAdded`, `lastPlayed`): values are ISO-8601 dates or Unix seconds; `inLast` takes a number of
///   days or a string such as `"12h"`, `"30d"`, `"2w"`, `"6m"`, `"1y"`; `is` matches the whole calendar day (UTC).
/// - `favorite` takes a boolean.
/// Rules whose operator does not apply to the field, or whose value cannot be parsed, are ignored.
public enum SmartPlaylistCompiler {
    public static func compile(_ definition: SmartPlaylistDefinition, now: Date = Date()) -> CompiledSmartQuery {
        var parts: [String] = []
        var arguments: [SmartSQLValue] = []
        for rule in definition.rules {
            guard let condition = SmartPlaylistCompiler.condition(for: rule, now: now) else { continue }
            parts.append("(\(condition.sql))")
            arguments.append(contentsOf: condition.arguments)
        }
        let joiner = definition.match == .all ? " AND " : " OR "
        let whereClause = parts.isEmpty ? "1" : parts.joined(separator: joiner)
        return CompiledSmartQuery(whereClause: whereClause, arguments: arguments, orderBy: orderBy(definition.sort),
                                  limit: max(0, definition.limit))
    }

    /// ORDER BY clause for a sort spec such as `"title"`, `"-playCount"` or `"random"`.
    public static func orderBy(_ sort: String) -> String {
        var key = sort.trimmingCharacters(in: .whitespaces)
        var ascending = true
        if key.hasPrefix("-") {
            ascending = false
            key.removeFirst()
        } else if key.hasPrefix("+") {
            key.removeFirst()
        }
        if key.lowercased() == "random" { return "RANDOM()" }
        let aliases: [String: TrackSortField] = ["format": .bitrate, "length": .duration, "added": .dateAdded, "plays": .playCount]
        let field = TrackSortField(rawValue: key) ?? aliases[key] ?? .title
        return TrackSort(field: field, ascending: ascending).orderSQL
    }

    static func column(for field: SmartRuleField) -> String {
        switch field {
        case .genre: return "tracks.genre"
        case .artist: return "tracks.artist"
        case .albumArtist: return LibraryQueries.albumArtistExpression
        case .album: return "tracks.album"
        case .composer: return "tracks.composer"
        case .title: return "tracks.title"
        case .format: return "tracks.codec"
        case .year: return "tracks.year"
        case .rating: return "tracks.rating"
        case .playCount: return "tracks.playCount"
        case .dateAdded: return "tracks.dateAdded"
        case .lastPlayed: return "tracks.lastPlayed"
        case .bitDepth: return "tracks.bitDepth"
        case .sampleRate: return "tracks.sampleRate"
        case .duration: return "tracks.duration"
        case .favorite: return "tracks.favorite"
        case .bpm: return "tracks.bpm"
        case .bitrate: return "tracks.bitrate"
        }
    }

    /// SQL condition and arguments for one rule, or nil when the rule is not applicable.
    public static func condition(for rule: SmartRule, now: Date = Date()) -> (sql: String, arguments: [SmartSQLValue])? {
        let columnSQL = column(for: rule.field)
        if rule.field.isDate {
            return dateCondition(column: columnSQL, rule: rule, now: now)
        }
        if rule.field == .favorite {
            guard let flag = boolValue(rule.value) else { return nil }
            switch rule.op {
            case .is: return ("\(columnSQL) = ?", [.integer(flag ? 1 : 0)])
            case .isNot: return ("\(columnSQL) <> ?", [.integer(flag ? 1 : 0)])
            default: return nil
            }
        }
        if rule.field.isNumeric {
            guard let value = rule.value.doubleValue else { return nil }
            let bound = numeric(value, field: rule.field)
            switch rule.op {
            case .is: return ("\(columnSQL) = ?", [bound])
            case .isNot: return ("(\(columnSQL) IS NULL OR \(columnSQL) <> ?)", [bound])
            case .gt: return ("\(columnSQL) > ?", [bound])
            case .lt: return ("\(columnSQL) < ?", [bound])
            case .between:
                guard let second = rule.value2?.doubleValue else { return nil }
                let low = min(value, second), high = max(value, second)
                return ("\(columnSQL) BETWEEN ? AND ?", [numeric(low, field: rule.field), numeric(high, field: rule.field)])
            case .contains, .startsWith, .inLast:
                return nil
            }
        }
        guard let text = rule.value.stringValue else { return nil }
        switch rule.op {
        case .is: return ("\(columnSQL) = ? COLLATE NOCASE", [.text(text)])
        case .isNot: return ("\(columnSQL) <> ? COLLATE NOCASE", [.text(text)])
        case .contains: return ("\(columnSQL) LIKE ? ESCAPE '\\'", [.text("%" + LibraryQueries.likeEscape(text) + "%")])
        case .startsWith: return ("\(columnSQL) LIKE ? ESCAPE '\\'", [.text(LibraryQueries.likeEscape(text) + "%")])
        case .gt: return ("\(columnSQL) > ? COLLATE NOCASE", [.text(text)])
        case .lt: return ("\(columnSQL) < ? COLLATE NOCASE", [.text(text)])
        case .between:
            guard let second = rule.value2?.stringValue else { return nil }
            return ("\(columnSQL) BETWEEN ? AND ? COLLATE NOCASE", [.text(text), .text(second)])
        case .inLast:
            return nil
        }
    }

    private static func numeric(_ value: Double, field: SmartRuleField) -> SmartSQLValue {
        switch field {
        case .sampleRate, .duration: return .real(value)
        default: return value == value.rounded() ? .integer(Int64(value)) : .real(value)
        }
    }

    private static func boolValue(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let flag): return flag
        case .number(let number): return number != 0
        case .string(let text):
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    private static func dateCondition(column: String, rule: SmartRule, now: Date) -> (sql: String, arguments: [SmartSQLValue])? {
        switch rule.op {
        case .inLast:
            guard let seconds = durationSeconds(rule.value) else { return nil }
            return ("\(column) >= ?", [.real(now.timeIntervalSince1970 - seconds)])
        case .is:
            guard let date = dateValue(rule.value) else { return nil }
            let start = (date / 86_400).rounded(.down) * 86_400
            return ("(\(column) >= ? AND \(column) < ?)", [.real(start), .real(start + 86_400)])
        case .isNot:
            guard let date = dateValue(rule.value) else { return nil }
            let start = (date / 86_400).rounded(.down) * 86_400
            return ("(\(column) IS NULL OR \(column) < ? OR \(column) >= ?)", [.real(start), .real(start + 86_400)])
        case .gt:
            guard let date = dateValue(rule.value) else { return nil }
            return ("\(column) > ?", [.real(date)])
        case .lt:
            guard let date = dateValue(rule.value) else { return nil }
            return ("\(column) < ?", [.real(date)])
        case .between:
            guard let first = dateValue(rule.value), let second = rule.value2.flatMap(dateValue) else { return nil }
            return ("\(column) BETWEEN ? AND ?", [.real(min(first, second)), .real(max(first, second))])
        case .contains, .startsWith:
            return nil
        }
    }

    /// Unix seconds from an ISO-8601 date / date-time string or a number.
    static func dateValue(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let number):
            return number
        case .string(let text):
            if let number = Double(text) { return number }
            if let date = DateParsing.iso8601Date(text) { return date.timeIntervalSince1970 }
            let parts = text.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3 {
                var components = DateComponents()
                components.year = parts[0]
                components.month = parts[1]
                components.day = parts[2]
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
                return calendar.date(from: components)?.timeIntervalSince1970
            }
            return nil
        default:
            return nil
        }
    }

    /// Seconds for `inLast` values: a number of days or "<n>h|d|w|m|y".
    static func durationSeconds(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let days):
            return days * 86_400
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
            if let days = Double(trimmed) { return days * 86_400 }
            guard let unit = trimmed.last, let amount = Double(trimmed.dropLast()) else { return nil }
            switch unit {
            case "h": return amount * 3_600
            case "d": return amount * 86_400
            case "w": return amount * 7 * 86_400
            case "m": return amount * 30 * 86_400
            case "y": return amount * 365 * 86_400
            default: return nil
            }
        default:
            return nil
        }
    }
}
