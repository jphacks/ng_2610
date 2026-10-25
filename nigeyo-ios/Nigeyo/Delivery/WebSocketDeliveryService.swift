import Foundation

enum ConnectionState: String, Sendable {
    case disconnected, connecting, connected, reconnecting
}

protocol DeliveryService: Sendable {
    func connect(_ pairing: Pairing) async
    func disconnect() async
    func sendHello() async
    func states() async -> AsyncStream<ConnectionState>
}

/// Demo-only receiver: URLSessionWebSocketTask with bearer auth, hello + 5 s heartbeat,
/// and 1/2/4/8/15/30 s reconnect backoff. Not a background push channel (spec §9.5).
actor WebSocketDeliveryService: DeliveryService {
    struct HelloInfo: Sendable {
        var installationId: UUID
        var appVersion: String
        var language: LanguageID
        var languagePackageVersion: Int
        var liveActivitiesEnabled: Bool
        var notificationAuthorization: NotificationAuthorization
        var regionalSubscription: RegionalSubscription? = nil
    }

    static let backoff: [TimeInterval] = [1, 2, 4, 8, 15, 30]
    static let heartbeatInterval: TimeInterval = 5

    private let regionalReceive: @Sendable (RegionalAlert) async -> RegionalAck?
    private let processor: CommandProcessor
    private let helloInfo: @Sendable () async -> HelloInfo
    private let deviceState: @Sendable () async -> DeviceState
    private let currentSessionId: @Sendable () async -> UUID?
    private let log: @Sendable (String) async -> Void
    private let session = URLSession(configuration: .ephemeral)

    private var pairing: Pairing?
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var state: ConnectionState = .disconnected
    private var observers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    init(processor: CommandProcessor, helloInfo: @escaping @Sendable () async -> HelloInfo, deviceState: @escaping @Sendable () async -> DeviceState,
         currentSessionId: @escaping @Sendable () async -> UUID?, regionalReceive: @escaping @Sendable (RegionalAlert) async -> RegionalAck? = { _ in nil }, log: @escaping @Sendable (String) async -> Void) {
        self.regionalReceive = regionalReceive
        self.processor = processor
        self.helloInfo = helloInfo
        self.deviceState = deviceState
        self.currentSessionId = currentSessionId
        self.log = log
    }

    func states() -> AsyncStream<ConnectionState> {
        let id = UUID()
        let (stream, c) = AsyncStream<ConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        c.yield(state)
        c.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        observers[id] = c
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func set(_ s: ConnectionState) {
        guard s != state else { return }
        state = s
        for c in observers.values { c.yield(s) }
    }

    func connect(_ pairing: Pairing) {
        disconnect()
        self.pairing = pairing
        loop = Task { await self.run() }
    }

    /// User-initiated: no reconnect afterwards.
    func disconnect() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        pairing = nil
        set(.disconnected)
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled, let pairing {
            set(attempt == 0 ? .connecting : .reconnecting)
            var request = URLRequest(url: pairing.endpoint)
            request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = WireConstants.maxMessageBytes
            self.task = task
            task.resume()
            let connected = await runConnection(on: task)
            if Task.isCancelled { return }
            attempt = connected ? 1 : attempt + 1
            let delay = Self.backoff[min(max(attempt - 1, 0), Self.backoff.count - 1)]
            await log("socket closed; retry in \(Int(delay))s")
            set(.reconnecting)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Returns true if the connection got as far as a successful hello.
    private func runConnection(on task: URLSessionWebSocketTask) async -> Bool {
        do {
            try await send(helloMessage(), on: task)
        } catch {
            return false
        }
        set(.connected)
        await log("connected to \(pairing?.endpoint.host ?? "?")")
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatInterval))
                guard let self, !Task.isCancelled else { return }
                await self.sendHeartbeat(on: task)
            }
        }
        defer { heartbeat.cancel() }
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                return true
            }
            let data: Data
            switch message {
            case .string(let s): data = Data(s.utf8)
            case .data: data = Data() // binary frames are not part of the contract → invalid-payload
            @unknown default: data = Data()
            }
            if let regional = try? JSONDecoder.nigeyo.decode(RegionalAlert.self, from: data), regional.type == "regional-alert" {
                if let ack = await regionalReceive(regional) { try? await send(ack, on: task) }
                continue
            }
            if let ack = await processor.handle(IncomingMessage.decode(data)), ack.runId != nil || ack.commandId != nil {
                try? await send(ack, on: task)
            }
        }
        return true
    }

    func sendHello() async {
        guard let task, state == .connected else { return }
        try? await send(helloMessage(), on: task)
    }

    private func helloMessage() async -> HelloMessage {
        let info = await helloInfo()
        return HelloMessage(installationId: info.installationId, appVersion: info.appVersion, preferredLanguage: info.language,
                            languagePackageVersion: info.languagePackageVersion, liveActivitiesEnabled: info.liveActivitiesEnabled,
                            notificationAuthorization: info.notificationAuthorization.rawValue, regionalSubscription: info.regionalSubscription)
    }

    private func sendHeartbeat(on task: URLSessionWebSocketTask) async {
        try? await send(helloMessage(), on: task)
        let device = await deviceState()
        let info = await helloInfo()
        let hb = HeartbeatMessage(installationId: info.installationId, appState: device.appState, protectedDataAvailable: device.protectedDataAvailable,
                                  currentSessionId: await currentSessionId())
        try? await send(hb, on: task)
    }

    private func send<T: Encodable>(_ value: T, on task: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder.nigeyo.encode(value)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
}
