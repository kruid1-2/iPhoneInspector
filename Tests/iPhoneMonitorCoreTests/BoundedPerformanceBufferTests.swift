import XCTest
@testable import iPhoneMonitorCore

final class BoundedPerformanceBufferTests: XCTestCase {
    func testEvictsOldestElementsAtCapacity() {
        var buffer = BoundedPerformanceBuffer<Int>(capacity: 3)
        XCTAssertEqual(buffer.append(contentsOf: [1, 2, 3, 4, 5]), 2)
        XCTAssertEqual(buffer.elements, [3, 4, 5])
        XCTAssertEqual(buffer.evictedCount, 2)
    }

    func testInitialElementsAreBounded() {
        let buffer = BoundedPerformanceBuffer<Int>(capacity: 2, elements: [1, 2, 3])
        XCTAssertEqual(buffer.elements, [2, 3])
        XCTAssertEqual(buffer.evictedCount, 1)
    }

    func testRemoveAllResetsEvictionCount() {
        var buffer = BoundedPerformanceBuffer<Int>(capacity: 1, elements: [1, 2])
        buffer.removeAll()
        XCTAssertTrue(buffer.elements.isEmpty)
        XCTAssertEqual(buffer.evictedCount, 0)
    }
}
