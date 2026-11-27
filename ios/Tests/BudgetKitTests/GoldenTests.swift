import XCTest
@testable import BudgetKit

/// The iPhone app must give exactly the same answers as the web app, because both work on the
/// same shared data. These files were made by running the web app's own code
/// (scripts/make-golden.mjs) on thousands of generated inputs.
final class GoldenTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    func json(_ name: String) throws -> Any { try JSONSerialization.jsonObject(with: try fixture(name)) }

    func testReceiptParsingMatchesWebAppOnThousandsOfReceipts() throws {
        let cases = try XCTUnwrap(json("receipts") as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 1000)
        var mismatches: [String] = []
        for c in cases {
            let text = c["text"] as! String
            let want = (c["items"] as! [[String: Any]]).map { ReceiptItem(name: $0["name"] as! String, price: $0["price"] as! Int) }
            let got = ReceiptParser.parse(text)
            if got != want { mismatches.append("ITEMS\n\(text)\nweb: \(want)\nios: \(got)") }
            let wantTotal = c["total"] as? Int
            let gotTotal = ReceiptParser.findTotal(text)
            if gotTotal != wantTotal { mismatches.append("TOTAL\n\(text)\nweb: \(String(describing: wantTotal)) ios: \(String(describing: gotTotal))") }
        }
        XCTAssertEqual(mismatches.count, 0, "First differences:\n" + mismatches.prefix(5).joined(separator: "\n-----\n"))
    }

    func testMoneyTypingMatchesWebApp() throws {
        let cases = try XCTUnwrap(json("money") as? [[String: Any]])
        var bad: [String] = []
        for c in cases {
            let input = c["input"] as! String
            let want = c["cents"] as? Int
            if Money.cents(input) != want { bad.append("\"\(input)\": web \(String(describing: want)) ios \(String(describing: Money.cents(input)))") }
        }
        XCTAssertEqual(bad, [])
    }

    func testItemNameMatchingMatchesWebApp() throws {
        let cases = try XCTUnwrap(json("normalize") as? [[String: String]])
        var bad: [String] = []
        for c in cases where PriceHistory.normalize(c["input"]!) != c["key"]! {
            bad.append("\"\(c["input"]!)\": web \"\(c["key"]!)\" ios \"\(PriceHistory.normalize(c["input"]!))\"")
        }
        XCTAssertEqual(bad, [])
    }

    func testOpensWebAppDataAndWritesItBackUnchanged() throws {
        let raw = try fixture("webdata")
        let data = try BudgetData.decode(raw)
        XCTAssertEqual(data.transactions.count, 600)
        // Written back by the iPhone app and compared as JSON values with the web app's original.
        let again = try JSONSerialization.jsonObject(with: try data.encoded()) as! NSDictionary
        let original = try JSONSerialization.jsonObject(with: raw) as! NSDictionary
        XCTAssertEqual(again, original)
        let initial = try BudgetData.decode(try fixture("webinitial"))
        XCTAssertEqual(initial.categories.map(\.name), BudgetData.initial().categories.map(\.name))
        XCTAssertEqual(initial.categories.map(\.spaceId), BudgetData.initial().categories.map(\.spaceId))
        XCTAssertEqual(initial.categories.map(\.kind), BudgetData.initial().categories.map(\.kind))
        XCTAssertEqual(initial.spaces, BudgetData.initial().spaces)
        XCTAssertEqual(initial.users, BudgetData.initial().users)
        XCTAssertEqual(initial.settings, BudgetData.initial().settings)
    }

    func testTotalsHistoryAndPriceComparisonMatchWebApp() throws {
        let store = BudgetStore(data: try BudgetData.decode(try fixture("webdata")))
        let answers = try XCTUnwrap(json("webanswers") as? [String: Any])

        for s in answers["summaries"] as! [[String: Any]] {
            let got = store.monthSummary(spaceId: s["spaceId"] as! String, month: s["month"] as! String)
            let label = "\(s["spaceId"]!) \(s["month"]!)"
            XCTAssertEqual(got.income, s["income"] as! Int, label)
            XCTAssertEqual(got.spent, s["spent"] as! Int, label)
            XCTAssertEqual(got.budget, s["budget"] as! Int, label)
            XCTAssertEqual(got.count, s["count"] as! Int, label)
            XCTAssertEqual(got.byCategory, s["byCategory"] as! [String: Int], label)
        }
        for e in answers["entryOrder"] as! [[String: Any]] {
            XCTAssertEqual(store.transactions(in: e["spaceId"] as! String, month: e["month"] as? String).map(\.id), e["ids"] as! [String])
        }
        let history = store.itemHistory()
        let wantHistory = answers["history"] as! [[String: Any]]
        XCTAssertEqual(history.count, wantHistory.count)
        for h in wantHistory {
            let g = try XCTUnwrap(history[h["key"] as! String], "missing \(h["key"]!)")
            XCTAssertEqual(g.name, h["name"] as! String)
            XCTAssertEqual(g.entries.map(\.price), h["prices"] as! [Int])
            XCTAssertEqual(g.entries.map(\.txId), h["txIds"] as! [String])
        }
        for p in answers["previous"] as! [[String: Any]] {
            let got = store.previousPrice(of: p["name"] as! String, before: p["before"] as! String, excluding: p["excluding"] as? String)
            if let want = p["result"] as? [String: Any] {
                XCTAssertEqual(got?.date, want["date"] as? String)
                XCTAssertEqual(got?.price, want["price"] as? Int)
            } else {
                XCTAssertNil(got)
            }
        }
    }
}
