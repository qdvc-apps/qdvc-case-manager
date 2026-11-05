import Foundation

/// A calendar date with no time or time zone, as legacy exports write them.
public struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1, day <= LocalDate.daysIn(month: month, year: year),
              (1...9999).contains(year) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// `2026-11-05`.
    public init?(iso: String) {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            return nil
        }
        self.init(year: y, month: m, day: d)
    }

    public static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    public static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    public static func today(calendar: Calendar = .current) -> LocalDate {
        let c = calendar.dateComponents([.year, .month, .day], from: Date())
        return LocalDate(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1)!
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }
    public var monthKey: MonthKey { MonthKey(year: year, month: month) }

    /// Days since 1970-01-01 (Howard Hinnant's days_from_civil).
    public var dayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    public init(dayNumber z0: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        self.year = y
        self.month = m
        self.day = d
    }

    public func adding(days: Int) -> LocalDate { LocalDate(dayNumber: dayNumber + days) }

    /// "5 Nov 2026".
    public var display: String { "\(day) \(MonthKey.shortNames[month - 1]) \(year)" }

    public static func < (a: LocalDate, b: LocalDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// A calendar month: the columns of the workload pivot.
public struct MonthKey: Hashable, Comparable, Sendable, Identifiable, CustomStringConvertible {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        // Normalise, so arithmetic can overshoot.
        let total = year * 12 + (month - 1)
        self.year = Int((Double(total) / 12).rounded(.down))
        self.month = total - self.year * 12 + 1
    }

    /// `2026-11`.
    public init?(iso: String) {
        let parts = iso.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m) else { return nil }
        self.init(year: y, month: m)
    }

    public var id: String { iso }
    public var iso: String { String(format: "%04d-%02d", year, month) }
    public var description: String { iso }

    public static let shortNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    public static let longNames = ["January", "February", "March", "April", "May", "June", "July",
                                   "August", "September", "October", "November", "December"]

    /// "Nov 2026".
    public var label: String { "\(MonthKey.shortNames[month - 1]) \(year)" }
    /// "Nov 26".
    public var shortLabel: String { "\(MonthKey.shortNames[month - 1]) \(String(format: "%02d", year % 100))" }
    /// "November 2026".
    public var longLabel: String { "\(MonthKey.longNames[month - 1]) \(year)" }

    public var first: LocalDate { LocalDate(year: year, month: month, day: 1)! }
    public var last: LocalDate { LocalDate(year: year, month: month, day: LocalDate.daysIn(month: month, year: year))! }

    public func adding(months n: Int) -> MonthKey { MonthKey(year: year, month: month + n) }

    /// Months from `self` to `other`, counting both (empty if `other` is earlier).
    public func through(_ other: MonthKey) -> [MonthKey] {
        var out: [MonthKey] = []
        var m = self
        while m <= other {
            out.append(m)
            m = m.adding(months: 1)
        }
        return out
    }

    /// The `count` months ending with (and including) `self`.
    public func trailing(_ count: Int) -> [MonthKey] {
        guard count > 0 else { return [] }
        return adding(months: -(count - 1)).through(self)
    }

    public static func < (a: MonthKey, b: MonthKey) -> Bool { (a.year, a.month) < (b.year, b.month) }
}

/// How to read an all-numeric date such as 03/04/2026.
public enum DateOrder: String, CaseIterable, Sendable, Identifiable {
    case dayFirst = "day-first"
    case monthFirst = "month-first"
    case yearFirst = "year-first"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dayFirst: return "Day first (31/12/2026)"
        case .monthFirst: return "Month first (12/31/2026)"
        case .yearFirst: return "Year first (2026-12-31)"
        }
    }
}

/// Reads the many ways legacy exports write a date: ISO (with or without a
/// time), 05/11/2026, 5-Nov-26, November 5, 2026, 20261105, and Excel serial
/// day numbers. Anything after the date (a time) is ignored.
public enum DateParser {
    private static let monthNames: [String: Int] = {
        var map: [String: Int] = [:]
        for (i, name) in MonthKey.longNames.enumerated() {
            map[name.lowercased()] = i + 1
            map[String(name.lowercased().prefix(3))] = i + 1
        }
        map["sept"] = 9
        return map
    }()

    public static func parse(_ raw: String, order: DateOrder = .dayFirst) -> LocalDate? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Split into runs of letters or digits; drop ordinal suffixes (5th).
        var tokens: [String] = []
        var current = ""
        var currentIsDigit = false
        for ch in s {
            let isDigit = ch.isASCII && ch.isNumber
            let isLetter = ch.isLetter
            if isDigit || isLetter {
                if !current.isEmpty && isDigit != currentIsDigit {
                    tokens.append(current)
                    current = ""
                }
                currentIsDigit = isDigit
                current.append(ch)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        tokens = tokens.filter { !["st", "nd", "rd", "th", "t"].contains($0.lowercased()) }
        guard !tokens.isEmpty else { return nil }

        // One token: yyyyMMdd or an Excel serial number.
        if tokens.count == 1 || (tokens.count > 1 && tokens[0].count == 8 && Int(tokens[0]) != nil) {
            let t = tokens[0]
            if t.count == 8, let y = Int(t.prefix(4)), let m = Int(t.dropFirst(4).prefix(2)), let d = Int(t.suffix(2)) {
                return LocalDate(year: y, month: m, day: d)
            }
            if tokens.count == 1, let serial = Int(t), (20000...80000).contains(serial) {
                // Excel's day 0 is 1899-12-30 (allowing for its 1900 leap-year bug).
                return LocalDate(year: 1899, month: 12, day: 30)!.adding(days: serial)
            }
            return nil
        }
        guard tokens.count >= 3 else { return nil }
        let date = Array(tokens.prefix(3))

        func year(_ t: String) -> Int? {
            guard let v = Int(t) else { return nil }
            if t.count == 4 { return v }
            if t.count <= 2 { return v < 70 ? 2000 + v : 1900 + v }
            return nil
        }

        // A month name anywhere.
        if let nameIndex = date.firstIndex(where: { monthNames[$0.lowercased()] != nil }) {
            let month = monthNames[date[nameIndex].lowercased()]!
            let others = date.enumerated().filter { $0.offset != nameIndex }.map(\.element)
            guard others.count == 2, others.allSatisfy({ Int($0) != nil }) else { return nil }
            let dayToken: String
            let yearToken: String
            if others[0].count == 4 { yearToken = others[0]; dayToken = others[1] }
            else if others[1].count == 4 { yearToken = others[1]; dayToken = others[0] }
            else { dayToken = others[0]; yearToken = others[1] }   // 05-Nov-26, Nov 05 26
            guard let d = Int(dayToken), let y = year(yearToken) else { return nil }
            return LocalDate(year: y, month: month, day: d)
        }

        guard let a = Int(date[0]), let b = Int(date[1]), let c = Int(date[2]) else { return nil }
        if date[0].count == 4 {
            return LocalDate(year: a, month: b, day: c)
        }
        if order == .yearFirst, let y = year(date[0]) {
            return LocalDate(year: y, month: b, day: c)
        }
        guard let y = year(date[2]) else { return nil }
        // A part over 12 can only be the day, whatever the preferred order.
        if a > 12 && b <= 12 { return LocalDate(year: y, month: b, day: a) }
        if b > 12 && a <= 12 { return LocalDate(year: y, month: a, day: b) }
        return order == .monthFirst ? LocalDate(year: y, month: a, day: b) : LocalDate(year: y, month: b, day: a)
    }
}
