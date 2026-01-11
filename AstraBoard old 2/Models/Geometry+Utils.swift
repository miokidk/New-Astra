import CoreGraphics

extension Double {
    var cg: CGFloat { CGFloat(self) }
}

extension CGFloat {
    var double: Double { Double(self) }
}

extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGSize) -> CGPoint {
        CGPoint(x: lhs.x + rhs.width, y: lhs.y + rhs.height)
    }
}
