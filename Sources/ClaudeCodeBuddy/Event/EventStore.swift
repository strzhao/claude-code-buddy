import Foundation

/// A single recorded event for query/verification purposes.
struct StoredEvent {
    let timestamp: Date
    let type: String
    let sessionId: String
    let details: [String: Any]

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: timestamp),
            "type": type,
            "session_id": sessionId,
        ]
        for (key, value) in details {
            dict[key] = value
        }
        return dict
    }
}

/// Thread-safe ring buffer that records EventBus events for AI quality verification.
/// Fixed capacity (200 events). Oldest events are overwritten when full.
final class EventStore {
    static let capacity = 200

    private var buffer: [StoredEvent] = []
    private var writeIndex = 0
    private var totalRecorded = 0
    private let queue = DispatchQueue(label: "com.claudebuddy.eventstore", qos: .utility)

    // MARK: - Recording

    func record(_ event: StoredEvent) {
        queue.async { [weak self] in
            self?.recordSync(event)
        }
    }

    private func recordSync(_ event: StoredEvent) {
        if buffer.count < Self.capacity {
            buffer.append(event)
        } else {
            buffer[writeIndex] = event
        }
        writeIndex = (writeIndex + 1) % Self.capacity
        totalRecorded += 1
    }

    // MARK: - Querying

    /// Returns events matching the given filters, ordered newest-first.
    /// - Parameters:
    ///   - sessionId: If non-nil, only return events for this session.
    ///   - last: Maximum number of events to return (0 = all).
    /// - Returns: Tuple of (matched events, total events stored).
    func query(sessionId: String? = nil, last: Int = 0) -> (events: [StoredEvent], totalStored: Int) {
        queue.sync {
            let total = totalRecorded
            // buffer is in insertion order; reverse for newest-first
            var result: [StoredEvent]
            if buffer.count < Self.capacity {
                // Not yet full — buffer is strictly ordered
                result = buffer.reversed()
            } else {
                // Full — need to start from writeIndex (oldest) and go around
                var ordered: [StoredEvent] = []
                ordered.reserveCapacity(Self.capacity)
                for i in 0..<Self.capacity {
                    let idx = (writeIndex + i) % Self.capacity
                    ordered.append(buffer[idx])
                }
                result = ordered.reversed()
            }

            // Filter by sessionId
            if let sid = sessionId {
                result = result.filter { $0.sessionId == sid }
            }

            // Limit count
            if last > 0 && result.count > last {
                result = Array(result.prefix(last))
            }

            return (result, total)
        }
    }

    // MARK: - Testing Support

    /// Synchronous record for testing purposes only.
    func recordSyncForTesting(_ event: StoredEvent) {
        queue.sync {
            recordSync(event)
        }
    }

    var count: Int {
        queue.sync { buffer.count }
    }

    var totalRecordedCount: Int {
        queue.sync { totalRecorded }
    }
}
