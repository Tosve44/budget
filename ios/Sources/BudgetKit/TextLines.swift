import Foundation

/// Apple's text reader (Vision) returns separate pieces of text with their position on the photo.
/// On a receipt the product name and its price are often two pieces far apart on the same row.
/// This puts pieces that sit on the same row back together, left to right, so the receipt
/// parser sees "MLEKO 1L    1,29 C" as one line, just like the web app's reader gives it.
public enum TextLines {
    public struct Piece: Equatable, Sendable {
        public var text: String
        /// Position on the photo, 0...1, measured from the top-left corner.
        public var minX: Double, minY: Double, maxX: Double, maxY: Double
        /// How much the piece's text line slopes (down is positive, dy/dx), from its corners.
        /// The phone's reader reports tilted boxes, so a tilted photo can be straightened.
        public var slope: Double

        public init(text: String, minX: Double, minY: Double, maxX: Double, maxY: Double, slope: Double = 0) {
            self.text = text; self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY; self.slope = slope
        }
        var midY: Double { (minY + maxY) / 2 }
        /// Height of the letters themselves: a tilted piece's straight box is taller than its text.
        var height: Double {
            let box = maxY - minY
            return max(box - abs(slope) * (maxX - minX), box * 0.3)
        }
    }

    /// Joins pieces into text lines, top to bottom.
    /// Two pieces are on the same row when their vertical middles are closer than about half a
    /// text height. Rows are allowed to slope a little (photos are rarely perfectly straight):
    /// the slope is measured from the pieces themselves.
    public static func assemble(_ pieces: [Piece]) -> String {
        let ps = pieces.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.maxY > $0.minY }
        guard !ps.isEmpty else { return "" }
        let slope = estimateSlope(ps)
        // Straighten: the y a piece would have at the left edge of the photo.
        func y(_ p: Piece) -> Double { p.midY - slope * ((p.minX + p.maxX) / 2) }
        let sorted = ps.sorted { y($0) < y($1) }
        var rows: [[Piece]] = []
        var rowY: [Double] = []
        var rowH: [Double] = []
        for p in sorted {
            if let last = rows.indices.last, abs(y(p) - rowY[last]) < 0.5 * min(rowH[last], p.height) {
                rows[last].append(p)
                let n = Double(rows[last].count)
                rowY[last] = (rowY[last] * (n - 1) + y(p)) / n
                rowH[last] = max(rowH[last], p.height)
            } else {
                rows.append([p]); rowY.append(y(p)); rowH.append(p.height)
            }
        }
        return rows.map { row in
            row.sorted { $0.minX < $1.minX }.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// The typical slope of the text rows: the median slope of the pieces (wider pieces have a
    /// more reliable slope, so only those are used when there are enough). 0 if unsure.
    static func estimateSlope(_ ps: [Piece]) -> Double {
        let wide = ps.filter { $0.maxX - $0.minX > 0.1 }
        var slopes = (wide.count >= 3 ? wide : ps).map(\.slope).filter(\.isFinite)
        guard !slopes.isEmpty else { return 0 }
        slopes.sort()
        let s = slopes[slopes.count / 2]
        return abs(s) < 0.2 ? s : 0
    }
}
