import Foundation

struct EventQueueSnapshot<Event: Sendable>: Sendable {
    var startTime: Date
    var endTime: Date
    var events: [Event]
    var droppedCount: Int

    var isEmpty: Bool {
        events.isEmpty && droppedCount == 0
    }
}

extension EventQueueSnapshot where Event: Hashable {
    func aggregated() -> [AggregatedEvent<Event>] {
        var counts: [Event: Int] = [:]
        for event in events {
            counts[event, default: 0] += 1
        }

        return counts.map { event, count in
            AggregatedEvent(startTime: startTime, endTime: endTime, count: count, event: event)
        }
    }
}

/// Holds collected events until they are reported, dropping the oldest once full.
///
/// Once full, the buffer is written in a ring so that a push overwrites the oldest event in place
/// rather than shifting every event down by one, which keeps the client's hot path cheap.
final class EventQueue<Event: Sendable>: Sendable {
    private struct State {
        var events: [Event] = []
        var oldestIndex = 0
        var startTime: Date?
        var droppedCount = 0

        var orderedEvents: [Event] {
            Array(events[oldestIndex...]) + events[..<oldestIndex]
        }
    }

    private let limit: Int
    private let state = Locked(State())

    init(limit: Int = 1000) {
        self.limit = max(1, limit)
    }

    var isEmpty: Bool {
        state.withLock { $0.events.isEmpty && $0.droppedCount == 0 }
    }

    var events: [Event] {
        state.withLock { $0.orderedEvents }
    }

    func push(_ event: Event) {
        state.withLock { state in
            if state.startTime == nil {
                state.startTime = Date()
            }

            if state.events.count < limit {
                state.events.append(event)
            } else {
                state.events[state.oldestIndex] = event
                state.oldestIndex = (state.oldestIndex + 1) % limit
                state.droppedCount += 1
            }
        }
    }

    func takeSnapshot() -> EventQueueSnapshot<Event> {
        let endTime = Date()

        let collected = state.exchange(\.self, with: State())

        return EventQueueSnapshot(
            startTime: collected.startTime ?? endTime,
            endTime: endTime,
            events: collected.orderedEvents,
            droppedCount: collected.droppedCount
        )
    }

    func clear() {
        state.withLock { $0 = State() }
    }
}
