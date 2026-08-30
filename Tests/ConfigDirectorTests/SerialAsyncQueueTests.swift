@testable import ConfigDirector
import Foundation
import Testing

struct SerialAsyncQueueTests {
    @Test func runsAnOperationSubmittedLaterAfterTheOneAlreadyRunning() async {
        let queue = SerialAsyncQueue()
        let order = Locked<[Int]>([])
        let firstStarted = Locked(false)

        let first = Task {
            await queue.enqueue {
                firstStarted.withLock { $0 = true }
                await settle(0.2)
                order.withLock { $0.append(1) }
            }
        }

        #expect(await waitUntil { firstStarted.withLock { $0 } }, "the first operation never started")

        let second = Task {
            await queue.enqueue {
                order.withLock { $0.append(2) }
            }
        }

        _ = await (first.value, second.value)
        #expect(order.withLock { $0 } == [1, 2], "a later submission overtook one already running")
    }

    @Test func neverRunsTwoOperationsAtOnce() async {
        let queue = SerialAsyncQueue()
        let running = Locked(0)
        let sawOverlap = Locked(false)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 50 {
                group.addTask {
                    await queue.enqueue {
                        let concurrent = running.withLock { count -> Int in
                            count += 1
                            return count
                        }
                        if concurrent > 1 {
                            sawOverlap.withLock { $0 = true }
                        }
                        await settle(0.001)
                        running.withLock { $0 -= 1 }
                    }
                }
            }
        }

        #expect(sawOverlap.withLock { $0 } == false, "two operations ran at the same time")
        #expect(running.withLock { $0 } == 0)
    }

    @Test func returnsOnlyAfterItsOwnOperationHasFinished() async {
        let queue = SerialAsyncQueue()
        let finished = Locked(false)

        await queue.enqueue {
            await settle(0.1)
            finished.withLock { $0 = true }
        }

        #expect(finished.withLock { $0 }, "enqueue returned before its operation finished")
    }
}
