import Testing
import UIKit
@testable import Nigeyo

@Suite @MainActor struct DemoBackgroundGraceTests {
    @Test func transitionsShareOneLeaseAndReleaseExactlyOnce() {
        var begins = 0
        var ended: [UIBackgroundTaskIdentifier] = []
        let id = UIBackgroundTaskIdentifier(rawValue: 42)
        let grace = DemoBackgroundGrace(begin: { _ in begins += 1; return id }, finish: { ended.append($0) })
        grace.start()
        grace.start()
        #expect(begins == 1)
        grace.end()
        grace.end()
        #expect(ended == [id])
        // A later lock may request a new lease.
        grace.start()
        #expect(begins == 2)
        grace.end()
        #expect(ended == [id, id])
    }

    @Test func systemExpirationReleasesLease() {
        var expiration: (@MainActor @Sendable () -> Void)?
        var ends = 0
        let grace = DemoBackgroundGrace(begin: { expiration = $0; return .init(rawValue: 43) }, finish: { _ in ends += 1 })
        grace.start()
        expiration?()
        grace.end()
        #expect(ends == 1)
    }

    @Test func deniedRequestIsNotEnded() {
        var ends = 0
        let grace = DemoBackgroundGrace(begin: { _ in .invalid }, finish: { _ in ends += 1 })
        grace.start()
        grace.end()
        #expect(ends == 0)
    }

    @Test func delayedExpirationOfOldLeaseDoesNotEndNewLease() {
        var expirations: [@MainActor @Sendable () -> Void] = []
        var ends = 0
        let grace = DemoBackgroundGrace(begin: { expirations.append($0); return .init(rawValue: expirations.count) },
                                        finish: { _ in ends += 1 })
        grace.start()
        grace.end()
        grace.start()
        expirations[0]()
        #expect(ends == 1)
        expirations[1]()
        #expect(ends == 2)
    }

    @Test func durationCapReleasesLeaseWithoutSystemExpiration() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        var ends = 0
        let grace = DemoBackgroundGrace(begin: { _ in .init(rawValue: 44) }, finish: { _ in
            ends += 1
            continuation.yield(())
            continuation.finish()
        }, maximumDuration: .milliseconds(1))
        grace.start()
        for await _ in stream { break }
        grace.end()
        #expect(ends == 1)
    }
}
