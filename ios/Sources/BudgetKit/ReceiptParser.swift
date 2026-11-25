import Foundation

/// Finds the product lines and the total in the text read from a receipt photo.
///
/// This is a line-by-line port of `parseReceipt` and `findTotal` in the web app's receipt.js.
/// The patterns are written out so they behave exactly like JavaScript's: JavaScript's `\d`, `\w`
/// and `\b` only know English letters and digits, while Apple's regular expressions know all
/// languages, so those shortcuts are spelled out by hand here. A test feeds thousands of
/// generated receipt lines to both versions and checks they give the same answer.
public enum ReceiptParser {
    // JavaScript's \s, exactly.
    static let S = #"[\t\n\u000B\f\r    -     　﻿]"#
    // JavaScript's \W (anything but A-Z, a-z, 0-9, _).
    static let W = "[^A-Za-z0-9_]"
    // JavaScript's \b around a word (non-Unicode mode).
    static let bStart = "(?<![A-Za-z0-9_])"
    static let bEnd = "(?![A-Za-z0-9_])"

    // Words that mark lines which are not products (totals, tax, payment, etc.).
    // Includes common English, Slovenian, Serbian/Croatian/Bosnian and German receipt words.
    static let skip = re(bStart + #"(skupaj|za pla[čc]ilo|ddv|vrnjeno|vra[čc]ilo|zoi|eor|davčna|davcna|blagajnik|total|subtotal|sub-total|sum|summe|ukupno|ukupan|za uplatu|uplata|plaćeno|placeno|povra[ćc]aj|kusur|pdv|vat|tax|mwst|ust|gotovina|cash|kartica|card|visa|mastercard|maestro|change|rabat|popust|discount|osnovica|stopa|iznos|račun|racun|receipt|fiskalni|pib|datum|date|vreme|time|kasir|cashier|bon|tel|www|hvala|thank)"# + bEnd, ci: true)

    // A price at the end of a line: 129.99, 1.299,00, 89,50, optionally followed by a tax letter
    // (A, B, C...) or €. A little junk between the price and the end of the line is allowed
    // ("1,29/:C", "2,15.€", "1;28").
    static let priceAtEnd = re("(?<=^|\(S)|[€:])(-?[0-9]{1,3}(?:\\.[0-9]{3})+,[0-9]{2}|-?[0-9]+[.,;:] ?[0-9]{2})(?:\(S)|\(W)|_)*(?:[A-ZĐŠČĆŽ€$]{1,3}|[a-e])?(?:\(S)|\(W)|_)*$")

    static let totalWords = re(bStart + #"(skupaj|za pla[čc]ilo|total|ukupno|za uplatu|summe)"# + bEnd, ci: true)
    static let taxWords = re(bStart + "(ddv|pdv|vat|osnova)" + bEnd, ci: true)
    static let spaces = re("\(S)+")
    static let lineBreak = re("\r?\n")
    static let currencyBeforePrice = re("(\(S)+(€|EUR|e|E))+\(S)*$")
    static let euroAtEnd = re("€\(S)*$")
    static let junk = re(#"[|_~*#"]+"#)
    static let leadingNumbers = re("^(?:[0-9.,]|\(S))+(?=\\p{L})")
    static let quantityOnly = re("^[0-9.,]+\(S)*(kom|kg|g|l|pcs|st)?\(S)*[x×*]\(S)*[0-9.,]+", ci: true)
    static let twoLetters = re("\\p{L}{2,}")
    static let gramMisread = re(bStart + "([0-9]*[1-9]0{1,2})[69]" + bEnd)

    static func re(_ pattern: String, ci: Bool = false) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : [])
    }

    // MARK: small helpers that behave like JavaScript string methods

    static func test(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    static func replace(_ r: NSRegularExpression, in s: String, with t: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                   withTemplate: NSRegularExpression.escapedTemplate(for: t))
    }

    static func jsTrim(_ s: String) -> String {
        replace(re("^\(S)+|\(S)+$"), in: s, with: "")
    }

    static func cleanLines(_ text: String) -> [String] {
        let ns = text as NSString
        var lines: [String] = []
        var start = 0
        for m in lineBreak.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            lines.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        lines.append(ns.substring(from: start))
        return lines.map { jsTrim(replace(spaces, in: $0, with: " ")) }
    }

    /// The price found at the end of a line: where it starts (UTF-16 offset) and its text.
    static func priceMatch(_ line: String) -> (start: Int, text: String)? {
        let ns = line as NSString
        guard let m = priceAtEnd.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (m.range.location, ns.substring(with: m.range(at: 1)))
    }

    static func priceCents(_ text: String) -> Int? {
        Money.cents(text.replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: ":", with: ",")
            .replacingOccurrences(of: " ", with: ""))
    }

    /// Common misreads in product names: "500G" read as "5006", "150g" as "1509".
    static func fixName(_ name: String) -> String {
        let upper = name == name.uppercased()
        let ns = name as NSString
        var out = ""
        var last = 0
        for m in gramMisread.matches(in: name, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += ns.substring(with: m.range(at: 1)) + (upper ? "G" : "g")
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    // MARK: public API

    /// The receipt's grand total ("SKUPAJ", "ZA PLAČILO", "TOTAL"...), which already includes discounts.
    /// When several lines qualify, the largest amount wins. nil if no total is printed.
    public static func findTotal(_ text: String) -> Int? {
        var total: Int?
        for line in cleanLines(text) {
            guard test(totalWords, line), !test(taxWords, line), let m = priceMatch(line),
                  let c = priceCents(m.text), c > 0 else { continue }
            total = max(total ?? 0, c)
        }
        return total
    }

    /// Product lines with their prices, in the order they are printed.
    public static func parse(_ text: String) -> [ReceiptItem] {
        var items: [ReceiptItem] = []
        let lines = cleanLines(text).filter { !$0.isEmpty }
        for (i, line) in lines.enumerated() {
            if test(skip, line) { continue }
            guard let m = priceMatch(line) else { continue }
            // Drop a currency sign before the price (the reader often sees € as "e" or "E").
            var name = (line as NSString).substring(to: m.start)
            name = jsTrim(replace(euroAtEnd, in: replace(currencyBeforePrice, in: name, with: ""), with: ""))
            guard let price = priceCents(m.text), price > 0 else { continue }
            // Quantity lines like "2 x 1,29" or "0,750 kg x 199,99": the product name is usually on the line above.
            let qtyOnly = test(quantityOnly, name)
            if !qtyOnly && !test(twoLetters, name) { continue } // e.g. a date and time "25.11.2026 10:15"
            if qtyOnly {
                let above = i > 0 ? lines[i - 1] : nil
                if let above, priceMatch(above) == nil, !test(skip, above), test(twoLetters, above) {
                    name = above
                } else {
                    continue
                }
            }
            name = jsTrim(replace(leadingNumbers, in: replace(spaces, in: replace(junk, in: name, with: " "), with: " "), with: ""))
            if (name as NSString).length < 2 { continue }
            items.append(ReceiptItem(name: fixName(name), price: price))
        }
        return items
    }
}
