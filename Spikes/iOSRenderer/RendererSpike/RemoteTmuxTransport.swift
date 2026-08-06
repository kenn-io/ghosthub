import Combine
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

struct TerminalGeometry: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let pixelWidth: Int
    let pixelHeight: Int
}

enum RemoteTmuxTransportState: Equatable, Sendable {
    case idle
    case connecting
    case verifyingHost
    case authenticating
    case openingSession
    case connected
    case reconnecting(reason: String)
    case failed(message: String)

    var title: String {
        switch self {
        case .idle:
            "Not connected"
        case .connecting:
            "Connecting"
        case .verifyingHost:
            "Verifying host"
        case .authenticating:
            "Authenticating"
        case .openingSession:
            "Attaching tmux"
        case .connected:
            "Connected"
        case .reconnecting:
            "Reconnecting"
        case .failed:
            "Connection failed"
        }
    }

    var detail: String? {
        switch self {
        case let .reconnecting(reason), let .failed(reason):
            reason
        default:
            nil
        }
    }

    var isActive: Bool {
        switch self {
        case .connecting, .verifyingHost, .authenticating, .openingSession,
             .connected, .reconnecting:
            true
        case .idle, .failed:
            false
        }
    }
}

@MainActor
final class RemoteTmuxTransport: ObservableObject {
    @Published private(set) var state: RemoteTmuxTransportState = .idle

    var outputHandler: ((Data) -> Void)?

    private var core: SSHTransportCore?
    private var reconnectTask: Task<Void, Never>?
    private var configuration: RemoteTmuxConfiguration?
    private var geometry: TerminalGeometry?
    private var shouldReconnect = false
    private var reachedConnectedState = false

    deinit {
        reconnectTask?.cancel()
        core?.disconnect()
    }

    func connect(_ configuration: RemoteTmuxConfiguration) {
        disconnect(resetState: false)
        self.configuration = configuration
        shouldReconnect = true
        reachedConnectedState = false
        startConnection()
    }

    func send(_ data: Data) {
        guard state == .connected else { return }
        core?.send(data)
    }

    func resize(_ geometry: TerminalGeometry) {
        guard geometry.columns > 0, geometry.rows > 0 else { return }
        guard self.geometry != geometry else { return }
        self.geometry = geometry
        core?.resize(geometry)
    }

    func disconnect() {
        disconnect(resetState: true)
    }

    func shutdown() {
        outputHandler = nil
        disconnect(resetState: true)
        configuration = nil
    }

    private func startConnection() {
        guard let configuration else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        state = reachedConnectedState ? .reconnecting(reason: "The SSH stream closed.") :
            .connecting

        let core = SSHTransportCore(
            configuration: configuration,
            geometry: geometry ?? TerminalGeometry(
                columns: 80,
                rows: 24,
                pixelWidth: 0,
                pixelHeight: 0
            )
        ) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                self?.receive(event)
            }
        }
        self.core = core
        core.start()
    }

    private func receive(_ event: SSHTransportEvent) {
        switch event {
        case let .stage(stage):
            state = stage
        case let .output(data):
            outputHandler?(data)
        case .connected:
            reachedConnectedState = true
            state = .connected
            if let geometry {
                core?.resize(geometry)
            }
        case let .closed(message):
            core = nil
            guard shouldReconnect else {
                state = .idle
                return
            }
            guard reachedConnectedState else {
                state = .failed(message: message)
                return
            }
            state = .reconnecting(reason: message)
            reconnectTask?.cancel()
            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, shouldReconnect else { return }
                startConnection()
            }
        }
    }

    private func disconnect(resetState: Bool) {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        core?.disconnect()
        core = nil
        if resetState {
            state = .idle
        }
    }
}

private enum SSHTransportEvent: Sendable {
    case stage(RemoteTmuxTransportState)
    case output(Data)
    case connected
    case closed(String)
}

private enum SSHTransportError: LocalizedError {
    case hostKeyMismatch
    case passwordAuthenticationUnavailable
    case ptyRejected
    case commandRejected
    case invalidChannel

    var errorDescription: String? {
        switch self {
        case .hostKeyMismatch:
            "The SSH server host key did not match the trusted key."
        case .passwordAuthenticationUnavailable:
            "The SSH server did not accept password authentication."
        case .ptyRejected:
            "The SSH server rejected the terminal request."
        case .commandRejected:
            "The SSH server rejected the tmux attach command."
        case .invalidChannel:
            "The SSH server opened an unexpected channel type."
        }
    }
}

private final class SSHPasswordDelegate: NIOSSHClientUserAuthenticationDelegate,
    @unchecked Sendable {
    let username: String
    let password: String
    let emit: @Sendable (SSHTransportEvent) -> Void
    private let lock = NSLock()
    private var didOfferPassword = false

    init(
        username: String,
        password: String,
        emit: @escaping @Sendable (SSHTransportEvent) -> Void
    ) {
        self.username = username
        self.password = password
        self.emit = emit
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        emit(.stage(.authenticating))
        guard availableMethods.contains(.password) else {
            nextChallengePromise.fail(SSHTransportError.passwordAuthenticationUnavailable)
            return
        }
        let shouldOffer = lock.withLock { () -> Bool in
            guard !didOfferPassword else { return false }
            didOfferPassword = true
            return true
        }
        guard shouldOffer else {
            nextChallengePromise.succeed(nil)
            return
        }
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .password(.init(password: password))
            )
        )
    }
}

private final class SSHPinnedHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let trustedKey: NIOSSHPublicKey
    let emit: @Sendable (SSHTransportEvent) -> Void

    init(
        trustedKey: NIOSSHPublicKey,
        emit: @escaping @Sendable (SSHTransportEvent) -> Void
    ) {
        self.trustedKey = trustedKey
        self.emit = emit
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        emit(.stage(.verifyingHost))
        if hostKey == trustedKey {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(SSHTransportError.hostKeyMismatch)
        }
    }
}

private final class SSHTransportCore: @unchecked Sendable {
    private let configuration: RemoteTmuxConfiguration
    private let initialGeometry: TerminalGeometry
    private let emit: @Sendable (SSHTransportEvent) -> Void
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()

    private var parentChannel: Channel?
    private var childChannel: Channel?
    private var didFinish = false

    init(
        configuration: RemoteTmuxConfiguration,
        geometry: TerminalGeometry,
        emit: @escaping @Sendable (SSHTransportEvent) -> Void
    ) {
        self.configuration = configuration
        initialGeometry = geometry
        self.emit = emit
    }

    func start() {
        emit(.stage(.connecting))
        let passwordDelegate = SSHPasswordDelegate(
            username: configuration.username,
            password: configuration.password,
            emit: emit
        )
        let hostKeyDelegate = SSHPinnedHostKeyDelegate(
            trustedKey: configuration.trustedHostKey,
            emit: emit
        )
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: passwordDelegate,
                                serverAuthDelegate: hostKeyDelegate
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(
                        SSHParentErrorHandler { [weak self] error in
                            self?.finish(error.localizedDescription)
                        }
                    )
                }
            }
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)

        bootstrap.connect(host: configuration.host, port: configuration.port)
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(channel):
                    let shouldOpen = lock.withLock { () -> Bool in
                        guard !didFinish else { return false }
                        parentChannel = channel
                        return true
                    }
                    guard shouldOpen else {
                        channel.close(promise: nil)
                        return
                    }
                    openSession(on: channel)
                case let .failure(error):
                    finish(error.localizedDescription)
                }
            }
    }

    func send(_ data: Data) {
        guard let channel = lock.withLock({ childChannel }) else { return }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(buffer, promise: nil)
    }

    func resize(_ geometry: TerminalGeometry) {
        guard let channel = lock.withLock({ childChannel }) else { return }
        channel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: geometry.columns,
                terminalRowHeight: geometry.rows,
                terminalPixelWidth: geometry.pixelWidth,
                terminalPixelHeight: geometry.pixelHeight
            ),
            promise: nil
        )
    }

    func disconnect() {
        let result = lock.withLock { () -> (didStop: Bool, channel: Channel?) in
            guard !didFinish else { return (false, nil) }
            didFinish = true
            return (true, parentChannel)
        }
        guard result.didStop else { return }
        if let channel = result.channel {
            channel.close(promise: nil)
        }
        shutdownGroup()
    }

    private func openSession(on channel: Channel) {
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(handler):
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                handler.createChannel(promise, channelType: .session) { child, type in
                    guard type == .session else {
                        return child.eventLoop.makeFailedFuture(
                            SSHTransportError.invalidChannel
                        )
                    }
                    return child.pipeline.addHandler(
                        SSHTmuxChannelHandler(
                            command: self.configuration.remoteCommand,
                            geometry: self.initialGeometry,
                            emit: self.emit,
                            close: { [weak self] message in
                                self?.finish(message)
                            }
                        )
                    )
                }
                promise.futureResult.whenComplete { [weak self] result in
                    guard let self else {
                        if case let .success(child) = result {
                            child.close(promise: nil)
                        }
                        return
                    }
                    switch result {
                    case let .success(child):
                        let shouldKeep = lock.withLock { () -> Bool in
                            guard !didFinish else { return false }
                            childChannel = child
                            return true
                        }
                        if !shouldKeep {
                            child.close(promise: nil)
                        }
                    case let .failure(error):
                        finish(error.localizedDescription)
                    }
                }
            case let .failure(error):
                finish(error.localizedDescription)
            }
        }
    }

    private func finish(_ message: String) {
        let result = lock.withLock { () -> (didStop: Bool, channel: Channel?) in
            guard !didFinish else { return (false, nil) }
            didFinish = true
            let channel = parentChannel
            parentChannel = nil
            childChannel = nil
            return (true, channel)
        }
        guard result.didStop else { return }
        result.channel?.close(promise: nil)
        emit(.closed(message))
        shutdownGroup()
    }

    private func shutdownGroup() {
        group.shutdownGracefully { _ in }
    }
}

private final class SSHParentErrorHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    let receiveError: @Sendable (Error) -> Void

    init(receiveError: @escaping @Sendable (Error) -> Void) {
        self.receiveError = receiveError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        receiveError(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        receiveError(SSHTransportClosedError())
        context.fireChannelInactive()
    }
}

private struct SSHTransportClosedError: LocalizedError {
    var errorDescription: String? { "The SSH connection closed." }
}

private final class SSHTmuxChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private enum Stage {
        case waitingForPTY
        case waitingForCommand
        case running
    }

    let command: String
    let geometry: TerminalGeometry
    let emit: @Sendable (SSHTransportEvent) -> Void
    let close: @Sendable (String) -> Void
    private var stage = Stage.waitingForPTY

    init(
        command: String,
        geometry: TerminalGeometry,
        emit: @escaping @Sendable (SSHTransportEvent) -> Void,
        close: @escaping @Sendable (String) -> Void
    ) {
        self.command = command
        self.geometry = geometry
        self.emit = emit
        self.close = close
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenFailure { [close] error in
                close(error.localizedDescription)
            }
    }

    func channelActive(context: ChannelHandlerContext) {
        emit(.stage(.openingSession))
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: geometry.columns,
            terminalRowHeight: geometry.rows,
            terminalPixelWidth: geometry.pixelWidth,
            terminalPixelHeight: geometry.pixelHeight,
            terminalModes: .init([:])
        )
        context.triggerUserOutboundEvent(request, promise: nil)
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = message.data else { return }
        emit(.output(Data(buffer.readableBytesView)))
    }

    func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        let buffer = unwrapOutboundIn(data)
        context.write(
            wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
            promise: promise
        )
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent where stage == .waitingForPTY:
            stage = .waitingForCommand
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                promise: nil
            )
        case is ChannelSuccessEvent where stage == .waitingForCommand:
            stage = .running
            emit(.connected)
        case is ChannelFailureEvent where stage == .waitingForPTY:
            close(SSHTransportError.ptyRejected.localizedDescription)
        case is ChannelFailureEvent where stage == .waitingForCommand:
            close(SSHTransportError.commandRejected.localizedDescription)
        case let status as SSHChannelRequestEvent.ExitStatus:
            close("The remote tmux client exited with status \(status.exitStatus).")
        case ChannelEvent.inputClosed:
            close("The remote tmux stream closed.")
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        close(error.localizedDescription)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        close("The remote tmux channel closed.")
        context.fireChannelInactive()
    }
}
