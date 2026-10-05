import Foundation
import NIOCore
import TailnetKitCore

/// A SwiftNIO channel wrapped around an already-dialed tailnet TCP connection.
///
/// This path does not open a loopback socket. Callers that need a local address,
/// such as `WKWebView`, keep using `TailnetClient.openLoopbackRelay`.
public enum TailnetByteChannel {
    /// Installs `initialize` and only then registers the channel, so `channelActive`
    /// reaches handlers that must see it. Reading stays off until the caller enables
    /// `autoRead` or calls `read()`.
    public static func make(
        connection: any TailnetConnection,
        on eventLoop: EventLoop,
        initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        let channel = TailnetStreamChannel(connection: connection, eventLoop: eventLoop)
        let promise = eventLoop.makePromise(of: Channel.self)
        eventLoop.execute {
            initialize(channel).hop(to: eventLoop).whenComplete { result in
                switch result {
                case .failure(let error):
                    promise.fail(error)
                case .success:
                    channel.register().whenComplete { registered in
                        switch registered {
                        case .failure(let error):
                            promise.fail(error)
                        case .success:
                            promise.succeed(channel)
                        }
                    }
                }
            }
        }
        return promise.futureResult
    }
}

private final class TailnetStreamChannel: Channel, ChannelCore, @unchecked Sendable {
    private static let highWaterBytes = 64 * 1024
    private static let lowWaterBytes = 32 * 1024

    let allocator = ByteBufferAllocator()
    let eventLoop: EventLoop
    let closeFuture: EventLoopFuture<Void>
    let localAddress: SocketAddress? = nil
    let remoteAddress: SocketAddress? = nil
    let parent: Channel? = nil

    private(set) var isActive = false
    private var writable = true
    var isWritable: Bool { writable }

    private var pipelineStorage: ChannelPipeline!
    var pipeline: ChannelPipeline { pipelineStorage }
    var _channelCore: ChannelCore { self }

    private let connection: any TailnetConnection
    private let closePromise: EventLoopPromise<Void>
    private var autoRead = false
    private var allowRemoteHalfClosure = true
    private var pendingReads = false
    private var readInFlight = false
    private var readTask: Task<Void, Never>?
    private var pendingWrites: [PendingWrite] = []
    private var queuedWriteBytes = 0
    private var inFlightBytes = 0
    private var flushInFlight = false
    private var outboundClosed = false
    private var inboundClosed = false
    private var didClose = false
    private var outputClosePromise: EventLoopPromise<Void>?
    private var didFinishWriting = false

    init(connection: any TailnetConnection, eventLoop: EventLoop) {
        self.connection = connection
        self.eventLoop = eventLoop
        closePromise = eventLoop.makePromise(of: Void.self)
        closeFuture = closePromise.futureResult
        pipelineStorage = ChannelPipeline(channel: self)
    }

    func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        eventLoop.flatSubmit { [self] in
            if option is ChannelOptions.Types.AutoReadOption, let enabled = value as? Bool {
                autoRead = enabled
            } else if option is ChannelOptions.Types.AllowRemoteHalfClosureOption, let enabled = value as? Bool {
                allowRemoteHalfClosure = enabled
            }
            return eventLoop.makeSucceededVoidFuture()
        }
    }

    func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value> {
        eventLoop.flatSubmit { [self] in
            if option is ChannelOptions.Types.AutoReadOption, let value = autoRead as? Option.Value {
                return eventLoop.makeSucceededFuture(value)
            }
            if option is ChannelOptions.Types.AllowRemoteHalfClosureOption,
               let value = allowRemoteHalfClosure as? Option.Value {
                return eventLoop.makeSucceededFuture(value)
            }
            return eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
        }
    }

    func localAddress0() throws -> SocketAddress { throw ChannelError.unknownLocalAddress }
    func remoteAddress0() throws -> SocketAddress { throw ChannelError.unknownLocalAddress }

    func register0(promise: EventLoopPromise<Void>?) {
        guard !isActive, !didClose else {
            promise?.succeed(())
            return
        }
        isActive = true
        promise?.succeed(())
        pipeline.fireChannelActive()
        if autoRead { read0() }
    }

    func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) {
        register0(promise: promise)
    }

    func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.operationUnsupported)
    }

    func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.operationUnsupported)
    }

    func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard !didClose, !outboundClosed else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }
        guard let buffer = tryUnwrapData(data, as: ByteBuffer.self) else {
            promise?.fail(ChannelError.operationUnsupported)
            return
        }
        if buffer.readableBytes == 0 {
            promise?.succeed(())
            return
        }
        pendingWrites.append(PendingWrite(buffer: buffer, promise: promise))
        queuedWriteBytes += buffer.readableBytes
        updateWritability()
    }

    func flush0() {
        guard !flushInFlight else { return }
        drainWrites()
    }

    func read0() {
        guard !didClose, !inboundClosed else { return }
        if readInFlight {
            pendingReads = true
            return
        }
        readInFlight = true
        let connection = connection
        let loop = eventLoop
        readTask = Task { [weak self] in
            let result: Result<Data, Error>
            do {
                result = .success(try await connection.read(maxBytes: 16 * 1024))
            } catch {
                result = .failure(error)
            }
            loop.execute { self?.deliverRead(result) }
        }
    }

    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        switch mode {
        case .output:
            guard !outboundClosed else {
                promise?.succeed(())
                return
            }
            outboundClosed = true
            outputClosePromise = promise
            failPendingWrites(ChannelError.outputClosed)
            if !flushInFlight { finishOutput() }
        case .input:
            // Cancelling the blocking read closes the whole TailnetConnection.
            // Refuse input shutdown rather than killing the write side.
            promise?.fail(ChannelError.operationUnsupported)
        case .all:
            guard !didClose else {
                promise?.succeed(())
                return
            }
            didClose = true
            inboundClosed = true
            outboundClosed = true
            isActive = false
            writable = false
            readTask?.cancel()
            failPendingWrites(error)
            let outputPromise = outputClosePromise
            outputClosePromise = nil
            let connection = connection
            let loop = eventLoop
            Task {
                await connection.close()
                loop.execute { [weak self] in
                    guard let self else { return }
                    self.pipeline.fireChannelInactive()
                    outputPromise?.succeed(())
                    promise?.succeed(())
                    self.closePromise.succeed(())
                    self.removeHandlers(pipeline: self.pipeline)
                }
            }
        }
    }

    func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
    }

    func channelRead0(_ data: NIOAny) {}

    func errorCaught0(error: Error) {
        close0(error: error, mode: .all, promise: nil)
    }

    private func deliverRead(_ result: Result<Data, Error>) {
        readInFlight = false
        readTask = nil
        guard !didClose else { return }
        switch result {
        case .success(let data) where data.isEmpty:
            inboundClosed = true
            pipeline.fireChannelReadComplete()
            pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            if !allowRemoteHalfClosure {
                close0(error: ChannelError.eof, mode: .all, promise: nil)
            }
        case .success(let data):
            var buffer = allocator.buffer(capacity: data.count)
            buffer.writeBytes([UInt8](data))
            pipeline.fireChannelRead(buffer)
            pipeline.fireChannelReadComplete()
            if !didClose, !inboundClosed, (pendingReads || autoRead) {
                pendingReads = false
                read0()
            }
        case .failure(let error):
            if error is CancellationError { return }
            pipeline.fireErrorCaught(error)
        }
    }

    private func drainWrites() {
        guard !pendingWrites.isEmpty else {
            flushInFlight = false
            updateWritability()
            if outboundClosed { finishOutput() }
            return
        }
        flushInFlight = true
        let batch = pendingWrites
        pendingWrites.removeAll(keepingCapacity: true)
        let batchBytes = batch.reduce(0) { $0 + $1.buffer.readableBytes }
        queuedWriteBytes -= batchBytes
        inFlightBytes += batchBytes
        updateWritability()
        let connection = connection
        let loop = eventLoop
        Task { [weak self] in
            var outcomes: [(EventLoopPromise<Void>?, Error?)] = []
            var failed: Error?
            for write in batch {
                if let failed {
                    outcomes.append((write.promise, failed))
                    continue
                }
                var buffer = write.buffer
                let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
                do {
                    try await connection.write(Data(bytes))
                    outcomes.append((write.promise, nil))
                } catch {
                    failed = error
                    outcomes.append((write.promise, error))
                }
            }
            loop.execute {
                self?.inFlightBytes -= batchBytes
                for (promise, error) in outcomes {
                    if let error { promise?.fail(error) } else { promise?.succeed(()) }
                }
                self?.updateWritability()
                self?.drainWrites()
            }
        }
    }

    private func finishOutput() {
        guard !didFinishWriting else {
            outputClosePromise?.succeed(())
            outputClosePromise = nil
            return
        }
        didFinishWriting = true
        let connection = connection
        let loop = eventLoop
        Task { [weak self] in
            do {
                try await connection.finishWriting()
                loop.execute {
                    self?.outputClosePromise?.succeed(())
                    self?.outputClosePromise = nil
                }
            } catch {
                loop.execute {
                    self?.outputClosePromise?.fail(error)
                    self?.outputClosePromise = nil
                }
            }
        }
    }

    private func failPendingWrites(_ error: Error) {
        let writes = pendingWrites
        pendingWrites.removeAll(keepingCapacity: false)
        queuedWriteBytes = 0
        for write in writes {
            write.promise?.fail(error)
        }
        updateWritability()
    }

    private func updateWritability() {
        let outstanding = queuedWriteBytes + inFlightBytes
        let nowWritable: Bool
        if writable {
            nowWritable = outstanding < Self.highWaterBytes
        } else {
            nowWritable = outstanding <= Self.lowWaterBytes
        }
        guard nowWritable != writable else { return }
        writable = nowWritable
        pipeline.fireChannelWritabilityChanged()
    }
}

private struct PendingWrite {
    var buffer: ByteBuffer
    var promise: EventLoopPromise<Void>?
}
