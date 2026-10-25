import UIKit

/// A bounded opportunity to finish a connected demo after locking. This is not
/// a background push channel; iOS may expire the task before our 25-second cap.
@MainActor
final class DemoBackgroundGrace {
    typealias Begin = (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier

    private let begin: Begin
    private let finish: (UIBackgroundTaskIdentifier) -> Void
    private let maximumDuration: Duration
    private let event: (String) -> Void
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var timeout: Task<Void, Never>?
    private var generation = UUID()

    init(begin: @escaping Begin = { expiration in
        UIApplication.shared.beginBackgroundTask(withName: "Finish Nigeyo demo") {
            Task { @MainActor in expiration() }
        }
    }, finish: @escaping (UIBackgroundTaskIdentifier) -> Void = {
        UIApplication.shared.endBackgroundTask($0)
    }, maximumDuration: Duration = .seconds(25), event: @escaping (String) -> Void = { _ in }) {
        self.begin = begin
        self.finish = finish
        self.maximumDuration = maximumDuration
        self.event = event
    }

    func start() {
        // Inactive → background must not acquire twice or extend the deadline.
        guard identifier == .invalid else { return }
        let generation = UUID()
        self.generation = generation
        identifier = begin { [weak self] in
            guard let self, self.generation == generation else { return }
            self.end(reason: "system-expired")
        }
        guard identifier != .invalid else { event("demo grace denied"); return }
        event("demo grace started")
        let duration = maximumDuration
        timeout = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.end(reason: "duration-cap")
        }
    }

    func end(reason: String = "explicit") {
        timeout?.cancel()
        timeout = nil
        guard identifier != .invalid else { return }
        let task = identifier
        identifier = .invalid
        generation = UUID()
        finish(task)
        event("demo grace ended: \(reason)")
    }
}
