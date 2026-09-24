import Foundation

/// A rectangle in normalized page coordinates (0...1) with the origin at the
/// **bottom-left** of the page. This matches both Vision's bounding boxes and
/// PDF page space, so OCR boxes and PDF text boxes share one representation.
public struct NormalizedRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func union(_ other: NormalizedRect) -> NormalizedRect {
        let minX = min(x, other.x), minY = min(y, other.y)
        return NormalizedRect(x: minX, y: minY, width: max(maxX, other.maxX) - minX, height: max(maxY, other.maxY) - minY)
    }

    /// Horizontal slice of the rect covering the fraction `start..<end` of its width.
    /// Used to approximate the box of a substring within an OCR line.
    public func horizontalSlice(from start: Double, to end: Double) -> NormalizedRect {
        let s = max(0, min(1, start)), e = max(s, min(1, end))
        return NormalizedRect(x: x + width * s, y: y, width: width * (e - s), height: height)
    }

    /// Maps a rect measured on a page image that was displayed rotated clockwise by
    /// `degrees` (0, 90, 180, 270) back into the unrotated page space.
    public func unrotated(fromClockwiseDegrees degrees: Int) -> NormalizedRect {
        switch ((degrees % 360) + 360) % 360 {
        case 90:
            // A point (u, v) in the rotated view corresponds to (1 - v, u) in page space.
            return NormalizedRect(x: 1 - maxY, y: x, width: height, height: width)
        case 180:
            return NormalizedRect(x: 1 - maxX, y: 1 - maxY, width: width, height: height)
        case 270:
            return NormalizedRect(x: y, y: 1 - maxX, width: height, height: width)
        default:
            return self
        }
    }

    /// The inverse of `unrotated(fromClockwiseDegrees:)`.
    public func rotated(clockwiseDegrees degrees: Int) -> NormalizedRect {
        unrotated(fromClockwiseDegrees: 360 - (((degrees % 360) + 360) % 360))
    }
}
