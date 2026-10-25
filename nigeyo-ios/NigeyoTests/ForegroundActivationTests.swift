import Testing
@testable import Nigeyo

@Suite @MainActor struct ForegroundActivationTests {
    @Test func pendingReconnectIsDiscardedAfterLock() async {
        let activation = ForegroundActivation()
        let revision = activation.begin()
        let (pending, release) = AsyncStream<Void>.makeStream()
        var reconnects = 0
        let work = Task {
            for await _ in pending { break }
            if activation.isCurrent(revision) { reconnects += 1 }
        }
        activation.invalidate() // lock while authorization/store work is pending
        release.yield(())
        release.finish()
        await work.value
        #expect(reconnects == 0)
        let next = activation.begin()
        #expect(activation.isCurrent(next))
        #expect(!activation.isCurrent(revision))
    }
}
