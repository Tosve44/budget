import Foundation

public enum Money {
    /// Turns typed or printed money into cents. Accepts "12,50", "12.50", "1.299,00", "1,299.00", "7",
    /// "12,50 €". The last "," or "." is the decimal point, except a dot followed by exactly three
    /// digits, which is the Slovenian thousands separator ("1.000" is one thousand euros).
    /// Anything else (minus signs, "1e5", letters) is refused with nil.
    /// Exactly the rules of `toCents` in the web app's store.js (checked by the golden tests).
    public static func cents(_ input: String) -> Int? {
        // Spaces (also the narrow ones some keyboards insert) and apostrophes ("1'000") go.
        var s = input.replacingOccurrences(of: ReceiptParser.S, with: "", options: .regularExpression)
            .replacingOccurrences(of: "'", with: "")
        // The first "€", or "eur" at the very end (any case), whichever comes first.
        if let r = s.range(of: #"€|[eE][uU][rR]$"#, options: .regularExpression) { s.removeSubrange(r) }
        guard s.range(of: #"^[0-9][0-9.,]*$|^[.,][0-9]+$"#, options: .regularExpression) != nil else { return nil }
        let normalized: String
        if let lastSep = s.lastIndex(where: { $0 == "," || $0 == "." }) {
            let intPart = s[..<lastSep].filter { $0 != "," && $0 != "." }
            let frac = String(s[s.index(after: lastSep)...])
            let mixed = s.contains(",") && s.contains(".")
            if s[lastSep] == ".", frac.count == 3, !mixed, !intPart.isEmpty, intPart.contains(where: { $0 != "0" }) {
                normalized = intPart + frac
            } else {
                normalized = "\(intPart.isEmpty ? "0" : intPart).\(frac.isEmpty ? "0" : frac)"
            }
        } else {
            normalized = s
        }
        // Absurdly long numbers are refused instead of overflowing (the limits refuse them anyway).
        guard let n = Double(normalized), n.isFinite, n < 1e15 else { return nil }
        return cents(n)
    }

    /// Euros as a Double to cents, rounding half up like JavaScript's Math.round.
    public static func cents(_ euros: Double) -> Int {
        Int((euros * 100 + 0.5).rounded(.down))
    }

    /// "12,50" style text for an input field ("" for 0 when `emptyForZero`).
    public static func inputText(_ cents: Int, emptyForZero: Bool = true) -> String {
        if cents == 0 && emptyForZero { return "" }
        let sign = cents < 0 ? "-" : ""
        let a = abs(cents)
        let rest = a % 100
        return rest == 0 ? "\(sign)\(a / 100)" : "\(sign)\(a / 100),\(rest < 10 ? "0" : "")\(rest)"
    }

    /// Formatted for display, e.g. "1.234,50 €" in Slovenia. Whole amounts drop the cents.
    public static func format(_ cents: Int, currency: String = "EUR", locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = locale
        f.minimumFractionDigits = cents % 100 == 0 ? 0 : 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: Double(cents) / 100)) ?? String(format: "%.2f %@", Double(cents) / 100, currency)
    }

    /// Percent change from `before` to `now`, one decimal place. nil when there is nothing to compare with.
    public static func percentChange(now: Int, before: Int) -> Double? {
        guard before != 0 else { return nil }
        return (Double(now - before) / Double(before) * 1000 + 0.5).rounded(.down) / 10
    }
}

public enum DateKey {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// "2026-11" for a date (in the phone's time zone).
    public static func month(_ date: Date = Date()) -> String {
        let p = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", p.year!, p.month!)
    }

    /// "2026-11-25" for a date (in the phone's time zone).
    public static func day(_ date: Date = Date()) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
    }

    /// Moves a "YYYY-MM" month forward or back, across years.
    public static func shift(month: String, by delta: Int) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return month }
        let total = parts[0] * 12 + (parts[1] - 1) + delta
        let y = Int((Double(total) / 12).rounded(.down))
        let m = total - y * 12 + 1
        return String(format: "%04d-%02d", y, m)
    }

    /// The Date for a "YYYY-MM-DD" key (noon, so time zone changes can't move it to another day).
    public static func date(fromDay key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var dc = DateComponents()
        dc.year = p[0]; dc.month = p[1]; dc.day = p[2]; dc.hour = 12
        guard let d = calendar.date(from: dc), day(d) == key else { return nil }
        return d
    }

    /// Whether a string is a real "YYYY-MM-DD" date.
    public static func isValidDay(_ key: String) -> Bool {
        key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil && date(fromDay: key) != nil
    }

    /// ISO 8601 timestamp with milliseconds, like JavaScript's toISOString().
    public static func timestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
