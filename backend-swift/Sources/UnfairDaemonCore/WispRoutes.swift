import Foundation
import NIO
import Vapor

func registerWispRoutes(_ app: Application, config: WebConfig) {
    app.webSocket("wisp") { req, ws in
        guard config.verifyAccessToken(req.query[String.self, at: "token"]) else {
            _ = ws.close(code: .policyViolation)
            return
        }
        let connection = WispConnection(webSocket: ws, eventLoop: req.eventLoop)
        connection.sendContinue(streamID: 0, remaining: WispConstants.serverBufferSize)
        ws.onBinary { _, buffer in
            connection.handle(buffer: buffer)
        }
        ws.onClose.whenComplete { _ in
            connection.closeAll()
        }
    }
}

private final class WispConnection {
    private let webSocket: WebSocket
    private let eventLoop: EventLoop
    private let lock = NSLock()
    private var streams: [UInt32: WispStream] = [:]

    init(webSocket: WebSocket, eventLoop: EventLoop) {
        self.webSocket = webSocket
        self.eventLoop = eventLoop
    }

    func handle(buffer: ByteBuffer) {
        var mutable = buffer
        guard let bytes = mutable.readBytes(length: mutable.readableBytes) else {
            return
        }

        do {
            let packet = try WispPacket(bytes: bytes)
            switch packet.type {
            case .connect:
                try connect(packet)
            case .data:
                stream(packet.streamID)?.write(packet.payload)
            case .continue:
                stream(packet.streamID)?.continueReading()
            case .close:
                removeStream(packet.streamID)?.close()
            }
        } catch {
            send(streamID: 0, type: .close, payload: [WispCloseReason.networkError.rawValue])
        }
    }

    func send(streamID: UInt32, type: WispPacketType, payload: [UInt8]) {
        let bytes = WispPacket.encode(type: type, streamID: streamID, payload: payload)
        webSocket.send(raw: bytes, opcode: .binary)
    }

    func sendContinue(streamID: UInt32, remaining: UInt32) {
        send(streamID: streamID, type: .continue, payload: [
            UInt8(remaining & 0xff),
            UInt8((remaining >> 8) & 0xff),
            UInt8((remaining >> 16) & 0xff),
            UInt8((remaining >> 24) & 0xff),
        ])
    }

    func removeClosedStream(_ id: UInt32) {
        lock.lock()
        streams.removeValue(forKey: id)
        lock.unlock()
    }

    func closeAll() {
        lock.lock()
        let current = Array(streams.values)
        streams.removeAll()
        lock.unlock()
        for stream in current {
            stream.close()
        }
    }

    private func connect(_ packet: WispPacket) throws {
        let payload = try WispConnectPayload(packet.payload)
        guard payload.streamType == WispStreamType.tcp else {
            send(streamID: packet.streamID, type: .close, payload: [WispCloseReason.hostBlocked.rawValue])
            return
        }
        guard WispHostFilter.isAllowed(host: payload.host, port: payload.port) else {
            send(streamID: packet.streamID, type: .close, payload: [WispCloseReason.hostBlocked.rawValue])
            return
        }

        let stream = WispStream(
            id: packet.streamID,
            host: payload.host,
            port: payload.port,
            connection: self,
            eventLoop: eventLoop
        )
        lock.lock()
        streams[packet.streamID] = stream
        lock.unlock()
        stream.open()
    }

    private func stream(_ id: UInt32) -> WispStream? {
        lock.lock()
        defer { lock.unlock() }
        return streams[id]
    }

    @discardableResult
    private func removeStream(_ id: UInt32) -> WispStream? {
        lock.lock()
        defer { lock.unlock() }
        return streams.removeValue(forKey: id)
    }
}

private final class WispStream {
    private let id: UInt32
    private let host: String
    private let port: UInt16
    private weak var connection: WispConnection?
    private let eventLoop: EventLoop
    private let lock = NSLock()
    private var channel: Channel?
    private var pendingData: [[UInt8]] = []
    private var closed = false

    init(id: UInt32, host: String, port: UInt16, connection: WispConnection, eventLoop: EventLoop) {
        self.id = id
        self.host = host
        self.port = port
        self.connection = connection
        self.eventLoop = eventLoop
    }

    func open() {
        let bootstrap = ClientBootstrap(group: eventLoop)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(WispTCPHandler(stream: self))
            }

        bootstrap.connect(host: host, port: Int(port)).whenComplete { result in
            switch result {
            case .success(let channel):
                self.lock.lock()
                self.channel = channel
                let pending = self.pendingData
                self.pendingData.removeAll()
                self.lock.unlock()
                for data in pending {
                    self.write(data)
                }
            case .failure:
                self.connection?.send(streamID: self.id, type: .close, payload: [WispCloseReason.networkError.rawValue])
                self.close()
            }
        }
    }

    func write(_ data: [UInt8]) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        guard let channel = channel else {
            pendingData.append(data)
            lock.unlock()
            return
        }
        lock.unlock()

        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(buffer, promise: nil)
    }

    func sendData(_ bytes: [UInt8]) {
        connection?.send(streamID: id, type: .data, payload: bytes)
        connection?.sendContinue(streamID: id, remaining: WispConstants.serverBufferSize)
    }

    func continueReading() {
        channel?.read()
    }

    func closeFromNetwork() {
        connection?.send(streamID: id, type: .close, payload: [WispCloseReason.voluntary.rawValue])
        close()
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let channel = self.channel
        self.channel = nil
        pendingData.removeAll()
        lock.unlock()
        connection?.removeClosedStream(id)
        channel?.close(promise: nil)
    }
}

private final class WispTCPHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private weak var stream: WispStream?

    init(stream: WispStream) {
        self.stream = stream
    }

    func channelActive(context: ChannelHandlerContext) {
        context.channel.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        if bytes.isEmpty == false {
            stream?.sendData(bytes)
        }
        context.channel.read()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        stream?.closeFromNetwork()
    }

    func channelInactive(context: ChannelHandlerContext) {
        stream?.closeFromNetwork()
    }
}

private enum WispPacketType: UInt8 {
    case connect = 0x01
    case data = 0x02
    case `continue` = 0x03
    case close = 0x04
}

private enum WispCloseReason: UInt8 {
    case voluntary = 0x02
    case networkError = 0x03
    case hostBlocked = 0x48
}

private enum WispStreamType {
    static let tcp: UInt8 = 0x01
}

private enum WispConstants {
    static let serverBufferSize: UInt32 = 128
}

private struct WispPacket {
    let type: WispPacketType
    let streamID: UInt32
    let payload: [UInt8]

    init(bytes: [UInt8]) throws {
        guard bytes.count >= 5,
              let type = WispPacketType(rawValue: bytes[0])
        else {
            throw Abort(.badRequest, reason: "wisp packet too small")
        }
        self.type = type
        self.streamID = UInt32(bytes[1]) |
            UInt32(bytes[2]) << 8 |
            UInt32(bytes[3]) << 16 |
            UInt32(bytes[4]) << 24
        self.payload = Array(bytes.dropFirst(5))
    }

    static func encode(type: WispPacketType, streamID: UInt32, payload: [UInt8]) -> [UInt8] {
        [
            type.rawValue,
            UInt8(streamID & 0xff),
            UInt8((streamID >> 8) & 0xff),
            UInt8((streamID >> 16) & 0xff),
            UInt8((streamID >> 24) & 0xff),
        ] + payload
    }
}

private struct WispConnectPayload {
    let streamType: UInt8
    let port: UInt16
    let host: String

    init(_ bytes: [UInt8]) throws {
        guard bytes.count >= 3 else {
            throw Abort(.badRequest, reason: "wisp connect payload too small")
        }
        streamType = bytes[0]
        port = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
        host = String(bytes: bytes.dropFirst(3), encoding: .utf8) ?? ""
    }
}

private enum WispHostFilter {
    static func isAllowed(host: String, port: UInt16) -> Bool {
        guard port == 443,
              host.isEmpty == false,
              isIPAddressHost(host) == false
        else {
            return false
        }

        let normalized = host.lowercased()
        if normalized == "auth.itunes.apple.com" ||
            normalized == "buy.itunes.apple.com" ||
            normalized == "init.itunes.apple.com" {
            return true
        }

        return normalized.range(of: #"^p[0-9]+-buy\.itunes\.apple\.com$"#, options: .regularExpression) != nil
    }
}
