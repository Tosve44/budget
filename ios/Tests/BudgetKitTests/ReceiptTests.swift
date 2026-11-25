import XCTest
@testable import BudgetKit

final class ReceiptTests: XCTestCase {
    static let mercator = """
    MERCATOR d.o.o.
    Dunajska cesta 107, Ljubljana
    ID za DDV: SI45884595
    Račun št.: 12-34-5678
    MLEKO ALPSKO 3,5% 1L        1,29 C
    KRUH BELI 500G              1,49 C
    2 x 0,89
    JOGURT NAVADNI 180G         1,78 C
    BANANE
    0,856 kg x 1,49 EUR/kg      1,28 C
    ČOKOLADA MILKA 100G         1,59 A
    Popust                     -0,30
    SKUPAJ EUR                  7,13
    Gotovina                   10,00
    Vračilo                     2,87
    DDV 9,5%  osnova 5,27       0,50
    ZOI: 3a5f9c2e
    EOR: 7d1b-22aa
    """

    static let lidl = """
    Lidl Slovenija d.o.o. k.d.
    EUR
    Jajca M 10/1           2,49 B
    Maslo 250g             2,99 B
    Testenine špageti      0,89 B
    Paradižnik             1,15 B
      0,620 kg x 1,85 EUR/kg
    Skupaj                 7,52
    Kartica                7,52
    """

    static let spar = """
    SPAR Slovenija
    Kava Barcaffe 400g   € 5,49
    Sir Edamec 300g      € 3,99
    Pivo Laško 0,5L 4x   € 4,36
    ZA PLAČILO           €13,84
    """

    func items(_ pairs: [(String, Int)]) -> [ReceiptItem] { pairs.map { ReceiptItem(name: $0.0, price: $0.1) } }

    func testMercator() {
        XCTAssertEqual(ReceiptParser.parse(Self.mercator), items([
            ("MLEKO ALPSKO 3,5% 1L", 129), ("KRUH BELI 500G", 149), ("JOGURT NAVADNI 180G", 178),
            ("BANANE", 128), ("ČOKOLADA MILKA 100G", 159),
        ]))
        XCTAssertEqual(ReceiptParser.findTotal(Self.mercator), 713)
    }

    func testLidlWithWeightLineBelowTheItem() {
        XCTAssertEqual(ReceiptParser.parse(Self.lidl), items([
            ("Jajca M 10/1", 249), ("Maslo 250g", 299), ("Testenine špageti", 89), ("Paradižnik", 115),
        ]))
        XCTAssertEqual(ReceiptParser.findTotal(Self.lidl), 752)
    }

    func testSparWithEuroSignInFront() {
        XCTAssertEqual(ReceiptParser.parse(Self.spar), items([("Kava Barcaffe 400g", 549), ("Sir Edamec 300g", 399), ("Pivo Laško 0,5L 4x", 436)]))
        XCTAssertEqual(ReceiptParser.findTotal(Self.spar), 1384)
    }

    func testHoferAndTusStyle() {
        let hofer = """
        HOFER trgovina d.o.o.
        Mleko trajno 1l          0,89 A
        Banane                   1,19 A
        Čips paprika 150g        1,29 B
        SKUPAJ                   3,37
        """
        XCTAssertEqual(ReceiptParser.parse(hofer).map(\.price), [89, 119, 129])
        XCTAssertEqual(ReceiptParser.findTotal(hofer), 337)
        let tus = """
        TUŠ
        Kruh polnozrnati 500 g   2,19
        Pivo Union 0,5 l         1,15
        3 kom x 1,15             3,45
        ZA PLAČILO EUR           5,64
        """
        XCTAssertEqual(ReceiptParser.parse(tus), items([("Kruh polnozrnati 500 g", 219), ("Pivo Union 0,5 l", 115)]), "same as the web app: a quantity line under a priced line is skipped")
        XCTAssertEqual(ReceiptParser.findTotal(tus), 564)
    }

    func testReaderNoise() {
        let t = """
        25.11.2026 10:15
        MLEKO 1L 1:29 C
        JABOLKA 2:15:C
        Kava 400g € 5, 49
        Sir 300g e 3,99
        KRUH 5006 1,49 C
        """
        XCTAssertEqual(ReceiptParser.parse(t), items([("MLEKO 1L", 129), ("JABOLKA", 215), ("Kava 400g", 549), ("Sir 300g", 399), ("KRUH 500G", 149)]))
        XCTAssertEqual(ReceiptParser.parse("Jogurt Ego 150g 0,69 c\nCips Chio 1509 1,99 A"), items([("Jogurt Ego 150g", 69), ("Cips Chio 150g", 199)]))
    }

    func testTotalIgnoresTaxLinesAndPicksTheLargest() {
        XCTAssertNil(ReceiptParser.findTotal("DDV skupaj 0,50\nnothing"))
        XCTAssertEqual(ReceiptParser.findTotal("Skupaj 3,00\nZA PLAČILO 1.234,56"), 123456)
        XCTAssertNil(ReceiptParser.findTotal(""))
    }

    func testNothingUsefulGivesNothing() {
        XCTAssertEqual(ReceiptParser.parse(""), [])
        XCTAssertEqual(ReceiptParser.parse("\n\n   \n"), [])
        XCTAssertEqual(ReceiptParser.parse("Hvala za nakup!\nwww.spar.si"), [])
        XCTAssertEqual(ReceiptParser.parse("A 1,00\n12 3,40\nKruh 0,00\nVrnjeno -1,00"), [], "too short, no letters, free, refund")
    }

    func testVeryLongTextIsFast() {
        let big = String(repeating: Self.mercator + "\n", count: 300)
        measure { _ = ReceiptParser.parse(big) }
        XCTAssertEqual(ReceiptParser.parse(big).count, 1500)
    }

    // MARK: putting the phone's text pieces back into lines

    func piece(_ t: String, _ x: Double, _ y: Double, w: Double = 0.3, h: Double = 0.02, slope: Double = 0) -> TextLines.Piece {
        // A tilted piece's straight box is taller by the tilt across its width.
        .init(text: t, minX: x, minY: y - max(0, -slope) * w, maxX: x + w, maxY: y + h + max(0, slope) * w, slope: slope)
    }

    func testPiecesOnTheSameRowAreJoinedLeftToRight() {
        let ps = [
            piece("1,29 C", 0.7, 0.101, w: 0.15), piece("MLEKO 1L", 0.05, 0.1),
            piece("KRUH", 0.05, 0.13, w: 0.1), piece("1,49 C", 0.7, 0.132, w: 0.15),
            piece("SKUPAJ", 0.05, 0.2, w: 0.15), piece("2,78", 0.75, 0.199, w: 0.1),
        ]
        XCTAssertEqual(TextLines.assemble(ps), "MLEKO 1L 1,29 C\nKRUH 1,49 C\nSKUPAJ 2,78")
        XCTAssertEqual(TextLines.assemble([]), "")
        XCTAssertEqual(TextLines.assemble([piece("  ", 0, 0)]), "")
    }

    /// Takes the sample receipts, cuts every line into a name piece and a price piece the way the
    /// phone's reader does, tilts the photo a little and shakes every piece, then checks that
    /// putting the pieces back together gives the same items and total as the original text.
    func testTiltedAndShakyPhotosStillGiveTheSameItems() {
        var rng = SeededRandom(seed: 7)
        for text in [Self.mercator, Self.lidl, Self.spar] {
            let lines = text.split(separator: "\n").map(String.init)
            for tiltDeg in [-4.0, -2.0, 0, 1.5, 3.5] {
                let slope = tan(tiltDeg * .pi / 180)
                var pieces: [TextLines.Piece] = []
                for (i, line) in lines.enumerated() {
                    let rowY = 0.05 + Double(i) * 0.03
                    let jitter = { Double.random(in: -0.002...0.002, using: &rng) }
                    if let m = ReceiptParser.priceMatch(line), m.start > 0 {
                        let ns = line as NSString
                        let name = ns.substring(to: m.start).trimmingCharacters(in: .whitespaces)
                        let price = ns.substring(from: m.start)
                        if !name.isEmpty { pieces.append(piece(name, 0.05, rowY + slope * 0.05 + jitter(), w: 0.4, slope: slope + jitter())) }
                        pieces.append(piece(price, 0.75, rowY + slope * 0.75 + jitter(), w: 0.15, slope: slope + jitter()))
                    } else {
                        pieces.append(piece(line, 0.05, rowY + slope * 0.05 + jitter(), w: 0.5, slope: slope + jitter()))
                    }
                }
                pieces.shuffle(using: &rng)
                let rebuilt = TextLines.assemble(pieces)
                XCTAssertEqual(ReceiptParser.parse(rebuilt), ReceiptParser.parse(text), "tilt \(tiltDeg)\n\(rebuilt)")
                XCTAssertEqual(ReceiptParser.findTotal(rebuilt), ReceiptParser.findTotal(text), "tilt \(tiltDeg)")
            }
        }
    }
}

final class PlanTests: XCTestCase {
    func testFreeVersionHasFewerCategoriesAndNoCustomOnes() {
        let s = BudgetStore(storage: nil)
        let P = "sp_personal_tosve", H = "sp_house"
        let fullP = s.pickableCategories(in: P, kind: .expense, plan: .full)
        let freeP = s.pickableCategories(in: P, kind: .expense, plan: .free)
        XCTAssertEqual(fullP.count, 17)
        XCTAssertEqual(Set(freeP.map(\.name)), PlanRules.freePersonalExpenses)
        XCTAssertEqual(Set(s.pickableCategories(in: H, kind: .expense, plan: .free).map(\.name)), PlanRules.freeHouseExpenses)
        XCTAssertEqual(s.pickableCategories(in: P, kind: .income, plan: .free).count, 2, "income is always included")
        XCTAssertTrue(PlanRules.canAddCustomCategory(plan: .full))
        XCTAssertFalse(PlanRules.canAddCustomCategory(plan: .free))
        XCTAssertFalse(PlanRules.canRenameCategory(plan: .free))
        // The free lists only name categories that really exist.
        let names = Set(DefaultCategories.personalExpenses)
        XCTAssertTrue(PlanRules.freePersonalExpenses.isSubset(of: names))
        XCTAssertTrue(PlanRules.freeHouseExpenses.isSubset(of: Set(DefaultCategories.houseExpenses)))
        // Hidden categories are not offered on any plan.
        s.updateCategory(freeP[0].id, archived: true)
        XCTAssertFalse(s.pickableCategories(in: P, kind: .expense, plan: .free).contains { $0.id == freeP[0].id })
    }
}

final class PhotoStoreTests: XCTestCase {
    func testSaveLoadDeleteAndCleanUp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ps = PhotoStore(folder: dir)
        let a = try ps.save(Data([1, 2, 3]))
        let b = try ps.save(Data([4]), id: "rc_keep")
        XCTAssertTrue(a.hasPrefix("rc_"))
        XCTAssertEqual(ps.load(a), Data([1, 2, 3]))
        XCTAssertEqual(ps.removeUnused(keeping: [b]), 1)
        XCTAssertNil(ps.load(a))
        XCTAssertEqual(ps.load(b), Data([4]))
        ps.delete(b)
        XCTAssertNil(ps.load(b))
        // Odd ids stay inside the photo folder.
        try ps.save(Data([9]), id: "../escape")
        XCTAssertEqual(ps.load("../escape"), Data([9]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escape.jpg").path))
        XCTAssertNil(ps.load("../../etc/passwd"))
        XCTAssertThrowsError(try ps.save(Data(), id: ""))
        // A photo downloaded from the partner.
        try ps.save(Data([7]), id: "cloud:sp_house_1/tx_2.jpg")
        XCTAssertEqual(ps.load("cloud:sp_house_1/tx_2.jpg"), Data([7]))
        XCTAssertEqual(ps.removeUnused(keeping: ["cloud:sp_house_1/tx_2.jpg"]), 1)
        XCTAssertEqual(ps.load("cloud:sp_house_1/tx_2.jpg"), Data([7]))
    }
}
