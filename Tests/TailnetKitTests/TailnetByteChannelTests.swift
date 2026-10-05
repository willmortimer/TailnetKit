import NIOCore
import NIOPosix
import TailnetKitCore
import XCTest
@testable import TailnetKitNIO

final class TailnetByteChannelTests: XCTestCase {
    func testWritesStayOrderedAndHalfCloseDoesNotCloseTheReadSide() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let remote = ScriptedTailnetConnection()
            remote.delayWrites = true
            let channel = try await TailnetByteChannel.make(connection: remote, on: group.next()).get()

            var first = channel.allocator.buffer(capacity: 3)
            first.writeString("one")
            var second = channel.allocator.buffer(capacity: 3)
            second.writeString("two")
            let firstWrite = channel.eventLoop.makePromise(of: Void.self)
            let secondWrite = channel.eventLoop.makePromise(of: Void.self)
            channel.writeAndFlush(first, promise: firstWrite)
            channel.writeAndFlush(second, promise: secondWrite)
            try await firstWrite.futureResult.get()
            try await secondWrite.futureResult.get()
            try await channel.close(mode: .output).get()

            XCTAssertEqual(remote.recordedWrites(), [Data("one".utf8), Data("two".utf8)])
            XCTAssertEqual(remote.finishWritingCount(), 1)
            XCTAssertEqual(remote.closeCount(), 0)
            XCTAssertTrue(channel.isActive)

            try await channel.close().get()
            XCTAssertGreaterThanOrEqual(remote.closeCount(), 1)
            XCTAssertFalse(channel.isActive)
            try await group.shutdownGracefully()
        } catch {
            try await group.shutdownGracefully()
            throw error
        }
    }

    func testCleanEOFDeliversBytesThenInputClosed() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let remote = ScriptedTailnetConnection()
        remote.enqueueRead(Data("hello".utf8))
        remote.enqueueRead(Data())
        let loop = group.next()
        let channel = try await TailnetByteChannel.make(connection: remote, on: loop).get()
        let inputClosed = loop.makePromise(of: Void.self)
        let collector = ByteCollector(inputClosed: inputClosed)
        try await channel.pipeline.addHandler(collector).get()
        try await channel.setOption(ChannelOptions.autoRead, value: true).get()
        channel.read()

        try await inputClosed.futureResult.get()
        XCTAssertEqual(collector.bytes, Array("hello".utf8))
        XCTAssertEqual(remote.closeCount(), 0)
        XCTAssertTrue(channel.isActive)
        try await channel.close().get()
        try await group.shutdownGracefully()
    }

    func testQueuedWritesPauseWhenTheHighWaterMarkIsExceeded() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let remote = ScriptedTailnetConnection()
        remote.blockWrites = true
        let loop = group.next()
        let channel = try await TailnetByteChannel.make(connection: remote, on: loop).get()
        let becameWritable = loop.makePromise(of: Void.self)
        try await channel.pipeline.addHandler(WritabilityWatcher(becameWritable: becameWritable)).get()

        var payload = channel.allocator.buffer(capacity: 70_000)
        payload.writeRepeatingByte(1, count: 70_000)
        channel.write(payload, promise: nil)
        try await loop.submit { XCTAssertFalse(channel.isWritable) }.get()

        remote.releaseWrites()
        channel.flush()
        try await becameWritable.futureResult.get()
        XCTAssertTrue(channel.isWritable)
        try await channel.close().get()
        try await group.shutdownGracefully()
    }
}

private final class WritabilityWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let becameWritable: EventLoopPromise<Void>
    private var didSucceed = false

    init(becameWritable: EventLoopPromise<Void>) {
        self.becameWritable = becameWritable
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable, !didSucceed {
            didSucceed = true
            becameWritable.succeed(())
        }
        context.fireChannelWritabilityChanged()
    }
}

private final class ByteCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private(set) var bytes: [UInt8] = []
    let inputClosed: EventLoopPromise<Void>

    init(inputClosed: EventLoopPromise<Void>) {
        self.inputClosed = inputClosed
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        bytes.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelEvent {
            inputClosed.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }
}

private final class ScriptedTailnetConnection: TailnetConnection, @unchecked Sendable {
    var delayWrites = false
    var blockWrites = false

    private let lock = NSLock()
    private var reads: [Data] = []
    private var readWaiters: [CheckedContinuation<Data, Error>] = []
    private var writes: [Data] = []
    private var writeWaiters: [CheckedContinuation<Void, Error>] = []
    private var finished = 0
    private var closed = 0
    private var isClosed = false

    func enqueueRead(_ data: Data) {
        lock.lock()
        if readWaiters.isEmpty {
            reads.append(data)
            lock.unlock()
            return
        }
        let waiter = readWaiters.removeFirst()
        lock.unlock()
        waiter.resume(returning: data)
    }

    func recordedWrites() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func finishWritingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func closeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func releaseWrites() {
        lock.lock()
        blockWrites = false
        let waiters = writeWaiters
        writeWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func read(maxBytes: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if isClosed {
                    lock.unlock()
                    continuation.resume(returning: Data())
                    return
                }
                if !reads.isEmpty {
                    let next = reads.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: next)
                    return
                }
                readWaiters.append(continuation)
                lock.unlock()
            }
        } onCancel: {
            Task { await self.close() }
        }
    }

    func write(_ data: Data) async throws {
        if delayWrites {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let shouldBlock: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if isClosed { return false }
            return blockWrites
        }()
        if shouldBlock {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if !blockWrites || isClosed {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                writeWaiters.append(continuation)
                lock.unlock()
            }
        }
        lock.lock()
        if isClosed {
            lock.unlock()
            throw CancellationError()
        }
        writes.append(data)
        lock.unlock()
    }

    func finishWriting() async throws {
        lock.lock()
        finished += 1
        lock.unlock()
    }

    func close() async {
        lock.lock()
        closed += 1
        isClosed = true
        let readers = readWaiters
        let writers = writeWaiters
        readWaiters.removeAll()
        writeWaiters.removeAll()
        lock.unlock()
        for reader in readers {
            reader.resume(returning: Data())
        }
        for writer in writers {
            writer.resume(throwing: CancellationError())
        }
    }
}
