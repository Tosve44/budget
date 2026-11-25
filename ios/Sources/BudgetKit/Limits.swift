import Foundation

/// The cloud database refuses rows over these sizes, and one refused row stops the whole upload
/// (and with it all syncing). So the phone keeps every record inside them. Same as the web app.
public enum Limits {
    /// Amounts and budgets in cents: below 1,000,000,000 (10 million euros).
    public static let maxCents = 999_999_999
    public static let note = 500
    public static let categoryName = 60
    public static let items = 300
    public static let itemName = 120
    public static let personName = 40

    /// A person's name as the database takes it: 1 to 40 characters.
    public static func displayName(_ s: String) -> String {
        let t = clip(s.trimmingCharacters(in: .whitespacesAndNewlines), personName)
        return t.isEmpty ? "Me" : t
    }

    /// Cuts text to at most `max` characters, counted the way the database counts them.
    public static func clip(_ s: String, _ max: Int) -> String {
        guard s.unicodeScalars.count > max else { return s }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s.unicodeScalars.prefix(max))
        return String(out)
    }

    public static func clamp(_ cents: Int) -> Int { min(max(cents, -maxCents), maxCents) }

    static func length(_ s: String) -> Int { s.unicodeScalars.count }
}
