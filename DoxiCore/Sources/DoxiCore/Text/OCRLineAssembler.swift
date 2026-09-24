import Foundation

/// A raw text observation from OCR (one Vision `VNRecognizedTextObservation`).
public struct OCRObservation: Sendable {
    public var text: String
    /// Normalized, bottom-left origin.
    public var box: NormalizedRect
    public var confidence: Double

    public init(text: String, box: NormalizedRect, confidence: Double) {
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}

/// Orders OCR observations into reading order and joins observations that sit
/// on the same visual row ("Grand Total" … "₹29,500") into one line, keeping
/// each fragment's box so highlights stay precise.
public enum OCRLineAssembler {
    public static func assemble(_ observations: [OCRObservation]) -> [TextLine] {
        let items = observations.filter { !$0.text.trimmed().isEmpty }
            .sorted { $0.box.maxY != $1.box.maxY ? $0.box.maxY > $1.box.maxY : $0.box.x < $1.box.x }
        var rows: [[OCRObservation]] = []
        for item in items {
            if let idx = rows.indices.last, sameRow(rows[idx], item) {
                rows[idx].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { row in
            let ordered = row.sorted { $0.box.x < $1.box.x }
            var text = ""
            var parts: [TextLinePart] = []
            for (i, obs) in ordered.enumerated() {
                if i > 0 { text += "  " }
                let start = (text as NSString).length
                let t = obs.text.trimmed()
                text += t
                parts.append(TextLinePart(range: TextRange(location: start, length: (t as NSString).length), box: obs.box))
            }
            let box = ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
            let confidence = ordered.map(\.confidence).min() ?? 0
            return TextLine(text: text, box: box, confidence: confidence, parts: ordered.count > 1 ? parts : nil)
        }
    }

    /// Vertical overlap of more than half the smaller height means the same row.
    static func sameRow(_ row: [OCRObservation], _ item: OCRObservation) -> Bool {
        guard let ref = row.last else { return false }
        let overlap = min(ref.box.maxY, item.box.maxY) - max(ref.box.y, item.box.y)
        let minHeight = min(ref.box.height, item.box.height)
        guard minHeight > 0 else { return false }
        // Only join fragments to the right of what is already on the row.
        let rightmost = row.map(\.box.maxX).max() ?? 0
        return overlap / minHeight > 0.5 && item.box.x >= rightmost - 0.01
    }
}
