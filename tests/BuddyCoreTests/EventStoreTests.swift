import XCTest
@testable import BuddyCore

final class EventStoreTests: XCTestCase {

    private var store: EventStore!

    override func setUp() {
        store = EventStore()
    }

    // MARK: - Basic Recording & Query

    func testRecordAndQuery() {
        let event = StoredEvent(
            timestamp: Date(), type: "state_changed", sessionId: "s1",
            details: ["new_state": "thinking"]
        )
        store.recordSyncForTesting(event)

        let (events, total) = store.query()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(total, 1)
        XCTAssertEqual(events[0].type, "state_changed")
        XCTAssertEqual(events[0].sessionId, "s1")
    }

    func testQueryBySessionId() {
        store.recordSyncForTesting(StoredEvent(timestamp: Date(), type: "t1", sessionId: "s1", details: [:]))
        store.recordSyncForTesting(StoredEvent(timestamp: Date(), type: "t2", sessionId: "s2", details: [:]))
        store.recordSyncForTesting(StoredEvent(timestamp: Date(), type: "t3", sessionId: "s1", details: [:]))

        let (events, total) = store.query(sessionId: "s1")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(total, 3)
        XCTAssertTrue(events.allSatisfy { $0.sessionId == "s1" })
    }

    func testQueryWithLast() {
        for i in 0..<10 {
            store.recordSyncForTesting(StoredEvent(timestamp: Date(), type: "t\(i)", sessionId: "s1", details: [:]))
        }

        let (events, _) = store.query(last: 3)
        XCTAssertEqual(events.count, 3)
        // Should be newest-first
        XCTAssertEqual(events[0].type, "t9")
        XCTAssertEqual(events[1].type, "t8")
        XCTAssertEqual(events[2].type, "t7")
    }

    func testQueryBySessionIdWithLast() {
        for i in 0..<5 {
            store.recordSyncForTesting(StoredEvent(timestamp: Date(), type: "t\(i)", sessionId: "s1", details: [:]))
            store.recordSyncForTesting(StoredEvent(timestamp: Date(), type: "t\(i)", sessionId: "s2", details: [:]))
        }

        let (events, _) = store.query(sessionId: "s1", last: 2)
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.sessionId == "s1" })
    }

    // MARK: - Ring Buffer Overflow

    func testRingBufferOverflow() {
        let capacity = EventStore.capacity // 200

        // Fill beyond capacity
        for i in 0...(capacity + 50) {
            store.recordSyncForTesting(StoredEvent(timestamp: Date(), type: "t\(i)", sessionId: "s1", details: [:]))
        }

        let (events, total) = store.query()
        XCTAssertEqual(events.count, capacity) // Buffer is capped at capacity
        XCTAssertEqual(total, capacity + 51) // But totalRecorded tracks all
        // Newest event should be t250
        XCTAssertEqual(events[0].type, "t\(capacity + 50)")
    }

    func testEmptyQuery() {
        let (events, total) = store.query()
        XCTAssertEqual(events.count, 0)
        XCTAssertEqual(total, 0)
    }

    func testQueryNonExistentSession() {
        store.recordSyncForTesting(StoredEvent(timestamp: Date(), type: "t1", sessionId: "s1", details: [:]))

        let (events, _) = store.query(sessionId: "nonexistent")
        XCTAssertEqual(events.count, 0)
    }

    // MARK: - Order Verification

    func testNewestFirstOrder() {
        for i in 1...5 {
            store.recordSyncForTesting(StoredEvent(timestamp: Date().addingTimeInterval(Double(i)), type: "t\(i)", sessionId: "s1", details: [:]))
        }

        let (events, _) = store.query()
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events[0].type, "t5") // newest first
        XCTAssertEqual(events[4].type, "t1") // oldest last
    }

    // MARK: - toDict

    func testStoredEventToDict() {
        let event = StoredEvent(
            timestamp: Date(), type: "state_changed", sessionId: "s1",
            details: ["new_state": "thinking", "tool_description": "Read"]
        )
        let dict = event.toDict()
        XCTAssertEqual(dict["type"] as? String, "state_changed")
        XCTAssertEqual(dict["session_id"] as? String, "s1")
        XCTAssertEqual(dict["new_state"] as? String, "thinking")
        XCTAssertEqual(dict["tool_description"] as? String, "Read")
        XCTAssertNotNil(dict["ts"]) // ISO8601 timestamp
    }
}
