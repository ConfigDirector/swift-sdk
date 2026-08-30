import Foundation

/// Everything an ``EventQueue`` had collected when a report was prepared.
struct EventQueueSnapshot<Event: Sendable>: Sendable {
    /// When the first of the ``events`` was collected.
    var startTime: Date

    /// When the snapshot was taken.
    var endTime: Date

    var events: [Event]

    /// How many events were dropped because the queue was full.
    var droppedCount: Int

    var isEmpty: Bool {
        events.isEmpty && droppedCount == 0
    }
}

extension EventQueueSnapshot where Event: Hashable {
    /// Collapses identical events into one entry each, carrying how many times the event occurred
    /// over the window this snapshot covers.
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

/// Holds collected events until they are reported.
///
/// The queue is bounded: once it is full the oldest events are dropped to make room for new ones,
/// and the number dropped is reported alongside the events that were kept.
final class EventQueue<Event: Sendable>: Sendable {
    private struct State {
        var events: [Event] = []
        var startTime: Date?
        var droppedCount = 0
    }

    /// The most events the queue holds before it starts dropping the oldest.
    private let limit: Int
    private let state = Locked(State())

    init(limit: Int = 1000) {
        self.limit = max(1, limit)
    }

    var isEmpty: Bool {
        state.withLock { $0.events.isEmpty && $0.droppedCount == 0 }
    }

    var events: [Event] {
        state.withLock { $0.events }
    }

    func push(_ event: Event) {
        state.withLock { state in
            if state.startTime == nil {
                state.startTime = Date()
            }

            if state.events.count >= limit {
                let dropCount = state.events.count - limit + 1
                state.events.removeFirst(dropCount)
                state.droppedCount += dropCount
            }
            state.events.append(event)
        }
    }

    /// Removes every event from the queue and returns it, leaving the queue ready to collect the
    /// next batch.
    func takeSnapshot() -> EventQueueSnapshot<Event> {
        let endTime = Date()

        let collected = state.exchange(\.self, with: State())

        return EventQueueSnapshot(
            startTime: collected.startTime ?? endTime,
            endTime: endTime,
            events: collected.events,
            droppedCount: collected.droppedCount
        )
    }

    func clear() {
        state.withLock { $0 = State() }
    }
}
