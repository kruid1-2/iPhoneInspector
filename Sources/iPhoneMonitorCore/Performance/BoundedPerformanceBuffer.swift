import Foundation

public struct BoundedPerformanceBuffer<Element>: Sendable where Element: Sendable {
    public let capacity: Int
    public private(set) var elements: [Element]
    public private(set) var evictedCount: Int

    public init(capacity: Int, elements: [Element] = []) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.elements = Array(elements.suffix(capacity))
        evictedCount = max(0, elements.count - capacity)
    }

    @discardableResult
    public mutating func append(_ element: Element) -> Int {
        elements.append(element)
        let overflow = max(0, elements.count - capacity)
        if overflow > 0 {
            elements.removeFirst(overflow)
            evictedCount += overflow
        }
        return overflow
    }

    @discardableResult
    public mutating func append(contentsOf newElements: [Element]) -> Int {
        guard !newElements.isEmpty else { return 0 }
        elements.append(contentsOf: newElements)
        let overflow = max(0, elements.count - capacity)
        if overflow > 0 {
            elements.removeFirst(overflow)
            evictedCount += overflow
        }
        return overflow
    }

    public mutating func removeAll(keepingCapacity: Bool = true) {
        elements.removeAll(keepingCapacity: keepingCapacity)
        evictedCount = 0
    }
}
