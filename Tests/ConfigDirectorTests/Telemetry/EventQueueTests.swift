@testable import ConfigDirector
import Foundation
import Testing

struct EventQueueTests {
    @Test func collectsEventsUntilTheyAreTaken() {
        let queue = EventQueue<String>()
        #expect(queue.isEmpty)

        queue.push("one")
        queue.push("two")
        #expect(queue.isEmpty == false)

        let snapshot = queue.takeSnapshot()

        #expect(snapshot.events == ["one", "two"])
        #expect(snapshot.droppedCount == 0)
        #expect(snapshot.startTime <= snapshot.endTime)
        #expect(queue.isEmpty, "taking a snapshot leaves the queue ready for the next batch")
    }

    @Test func dropsTheOldestEventsOnceFullAndCountsThem() {
        let queue = EventQueue<Int>(limit: 3)

        for event in 1 ... 5 {
            queue.push(event)
        }
        let snapshot = queue.takeSnapshot()

        #expect(snapshot.events == [3, 4, 5])
        #expect(snapshot.droppedCount == 2)
    }

    @Test func reportsDroppedEventsEvenWhenNoneAreLeft() {
        let queue = EventQueue<Int>(limit: 1)
        queue.push(1)
        queue.push(2)
        _ = queue.takeSnapshot()

        #expect(queue.isEmpty, "the dropped count is reset along with the events")
    }

    @Test func clearingDiscardsEverything() {
        let queue = EventQueue<Int>(limit: 1)
        queue.push(1)
        queue.push(2)

        queue.clear()

        #expect(queue.isEmpty)
        #expect(queue.takeSnapshot().droppedCount == 0)
    }

    @Test func aggregatesIdenticalEventsIntoOneEntryWithACount() {
        let queue = EventQueue<String>()
        for event in ["a", "b", "a", "a"] {
            queue.push(event)
        }
        let snapshot = queue.takeSnapshot()

        let aggregated = snapshot.aggregated().sorted { $0.count > $1.count }

        #expect(aggregated.map(\.event) == ["a", "b"])
        #expect(aggregated.map(\.count) == [3, 1])
        #expect(aggregated.allSatisfy { $0.startTime == snapshot.startTime })
        #expect(aggregated.allSatisfy { $0.endTime == snapshot.endTime })
    }

    @Test func aggregatingNothingProducesNothing() {
        #expect(EventQueue<String>().takeSnapshot().aggregated().isEmpty)
    }
}
