public struct PileExpansion<Display: Hashable> {
    private var expanded: Set<Display> = []

    public init() {}

    public func isExpanded(on display: Display) -> Bool {
        expanded.contains(display)
    }

    public mutating func expand(on display: Display) {
        expanded.insert(display)
    }

    public mutating func collapse(on display: Display) {
        expanded.remove(display)
    }

    public func pilesToFold(pointerOver hovered: Display?) -> Set<Display> {
        expanded.filter { $0 != hovered }
    }
}

extension PileExpansion: Sendable where Display: Sendable {}
