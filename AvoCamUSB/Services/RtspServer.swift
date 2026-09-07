//
//  RtspServer.swift
//  AvoCamUSB
//
//  RTSP 推流服务器 - 让 OBS / VLC 等通过 WiFi 直接拉流，无需数据线
//
//  用法：
//    1. iPhone 与电脑连接同一 WiFi
//    2. App 开始推流后，电脑 OBS 添加「媒体源」，输入：
//       rtsp://<iPhone局域网IP>:8554/live
//    3. 视频轨：H.264（RTP/AVP 96，RFC 6184）；音频轨：AAC-LC（RTP/AVP 97，RFC 3640）
//
//  传输方式：TCP interleaved（与 RTSP 同一条 TCP 连接），兼容 ffmpeg / OBS / VLC。
//

import Foundation
import Network

/// RTSP 推流服务器（H.264 视频 + AAC 音频，TCP interleaved 传输）
class RtspServer {

    /// RTSP 监听端口
    static let defaultPort: UInt16 = 8554

    /// 单个 RTP 包最大负载长度（字节）
    private let maxPayloadSize = 1200

    /// 视频 RTP 时钟频率（H.264 标准 90kHz）
    private let videoClock = 90_000
    /// 音频 RTP 时钟频率（48kHz）
    private let audioClock = 48_000
    /// AAC 每帧采样数
    private let audioSamplesPerFrame = 1024

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.avocamusb.rtsp")

    /// 已建立的 RTSP 连接
    private var connections: [RTSPConnection] = []

    /// 是否包含音频轨道
    private(set) var audioEnabled = false
    /// 编码帧率（用于 RTP 时间戳递增）
    private(set) var frameRate = 30

    /// 最近一次关键帧携带的 SPS/PPS（用于 SDP）
    private var sps: Data?
    private var pps: Data?

    /// RTP 时间戳（在 rtsp queue 上读写）
    private var videoTimestamp: UInt32 = 0
    private var audioTimestamp: UInt32 = 0

    /// 客户端数量变化回调（主线程）
    var onClientCountChanged: ((Int) -> Void)?
    /// 当前处于 PLAY 状态的拉流客户端数量
    private(set) var clientCount = 0 {
        didSet {
            if clientCount != oldValue {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.onClientCountChanged?(self.clientCount)
                }
            }
        }
    }

    // MARK: - 生命周期

    /// 启动 RTSP 服务（推流时调用）
    func start(audioEnabled: Bool, frameRate: Int) {
        self.audioEnabled = audioEnabled
        self.frameRate = max(1, frameRate)
        queue.async { [weak self] in
            self?.setupListener()
        }
    }

    /// 停止 RTSP 服务
    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.listener?.cancel()
            self.listener = nil
            let closing = self.connections
            self.connections.removeAll()
            closing.forEach { $0.close() }
            self.clientCount = 0
            self.sps = nil
            self.pps = nil
            self.videoTimestamp = 0
            self.audioTimestamp = 0
        }
    }

    private func setupListener() {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: RtspServer.defaultPort)!)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    avoPrint("[RtspServer] 正在监听端口 \(RtspServer.defaultPort)（WiFi 推流）")
                case .failed(let error):
                    avoPrint("[RtspServer] 监听失败: \(error)，2 秒后重试")
                    self?.queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self = self, self.listener != nil else { return }
                        self.listener?.cancel()
                        self.listener = nil
                        self.setupListener()
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener.start(queue: queue)
        } catch {
            avoPrint("[RtspServer] 创建监听器失败: \(error)")
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let rtspConnection = RTSPConnection(
            connection: connection,
            queue: queue,
            server: self
        )
        connections.append(rtspConnection)
        rtspConnection.start()
    }

    private func removeConnection(_ connection: RTSPConnection) {
        connections.removeAll { $0 === connection }
        refreshClientCount()
    }

    private func refreshClientCount() {
        clientCount = connections.reduce(0) { $0 + ($1.isPlaying ? 1 : 0) }
    }

    // MARK: - 发布媒体流

    /// 发布一帧 H.264（Annex-B 格式，含起始码）
    func publishVideo(_ annexB: Data) {
        guard !annexB.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let nals = Self.splitAnnexBNALs(annexB)
            guard !nals.isEmpty else { return }

            // 更新 SPS/PPS 缓存（用于 SDP）
            for nal in nals {
                let type = nal[nal.startIndex] & 0x1F
                if type == 7 {
                    self.sps = nal
                } else if type == 8 {
                    self.pps = nal
                }
            }

            let playing = self.connections.filter { $0.isPlaying }
            guard !playing.isEmpty else { return }

            let timestamp = self.videoTimestamp
            self.videoTimestamp &+= UInt32(self.videoClock / self.frameRate)

            for conn in playing {
                let packets = Self.packetizeH264(
                    nals,
                    timestamp: timestamp,
                    sequence: &conn.videoSequence,
                    ssrc: conn.videoSSRC,
                    maxPayload: self.maxPayloadSize
                )
                conn.sendInterleaved(packets, channel: 0)
            }
        }
    }

    /// 发布一帧 AAC（ADTS 格式，7 字节头会被剥离）
    func publishAudio(_ adts: Data) {
        guard audioEnabled, adts.count > 7 else { return }
        queue.async { [weak self] in
            guard let self = self else { return }

            let playing = self.connections.filter { $0.isPlaying }
            guard !playing.isEmpty else { return }

            let rawAAC = adts.subdata(in: adts.startIndex.advanced(by: 7)..<adts.endIndex)
            guard !rawAAC.isEmpty else { return }

            let timestamp = self.audioTimestamp
            self.audioTimestamp &+= UInt32(self.audioSamplesPerFrame)

            for conn in playing {
                let packet = Self.packetizeAAC(
                    rawAAC,
                    timestamp: timestamp,
                    sequence: &conn.audioSequence,
                    ssrc: conn.audioSSRC
                )
                conn.sendInterleaved([packet], channel: 1)
            }
        }
    }

    // MARK: - SDP 构建

    func makeSDP() -> String {
        var sdp = ""
        sdp += "v=0\r\n"
        sdp += "o=- \(UInt32.random(in: 0..<UInt32.max)) \(UInt32.random(in: 0..<UInt32.max)) IN IP4 0.0.0.0\r\n"
        sdp += "s=AvoCamUSB Live\r\n"
        sdp += "c=IN IP4 0.0.0.0\r\n"
        sdp += "t=0 0\r\n"

        // 视频轨：H.264
        var fmtp = "packetization-mode=1"
        if let sps = sps, let pps = pps, sps.count >= 4 {
            let profileLevelID = sps.subdata(in: sps.startIndex.advanced(by: 1)..<sps.startIndex.advanced(by: 4))
                .map { String(format: "%02X", $0) }
                .joined()
            fmtp += ";profile-level-id=\(profileLevelID)"
            fmtp += ";sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())"
        } else {
            fmtp += ";profile-level-id=42001f"
        }
        sdp += "m=video 0 RTP/AVP 96\r\n"
        sdp += "a=rtpmap:96 H264/90000\r\n"
        sdp += "a=fmtp:96 \(fmtp)\r\n"
        sdp += "a=control:trackID=0\r\n"

        // 音频轨：AAC-LC（48kHz 单声道）
        if audioEnabled {
            sdp += "m=audio 0 RTP/AVP 97\r\n"
            sdp += "a=rtpmap:97 mpeg4-generic/48000/1\r\n"
            sdp += "a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1188\r\n"
            sdp += "a=control:trackID=1\r\n"
        }

        return sdp
    }

    // MARK: - H.264 RTP 封包（RFC 6184）

    /// 将 Annex-B 数据切分为 NAL 单元（不含起始码）
    static func splitAnnexBNALs(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let count = bytes.count
        guard count > 4 else { return [] }

        // 收集所有起始码（00 00 01 或 00 00 00 01）后的数据起点
        var starts: [Int] = []
        var i = 0
        while i + 2 < count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append(i + 3)
                    i += 3
                    continue
                }
                if i + 3 < count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append(i + 4)
                    i += 4
                    continue
                }
            }
            i += 1
        }

        var nals: [Data] = []
        for (idx, s) in starts.enumerated() {
            let end = (idx + 1 < starts.count) ? starts[idx + 1] : count
            if end > s {
                nals.append(Data(bytes[s..<end]))
            }
        }
        return nals
    }

    /// 将一帧的 NAL 单元列表打包为 RTP 包序列（单 NAL / FU-A）
    static func packetizeH264(_ nals: [Data], timestamp: UInt32, sequence: inout UInt16, ssrc: UInt32, maxPayload: Int) -> [Data] {
        var packets: [Data] = []
        for (nalIndex, nal) in nals.enumerated() {
            let isLastNAL = nalIndex == nals.count - 1
            let nalBytes = [UInt8](nal)
            guard !nalBytes.isEmpty else { continue }
            let header = nalBytes[0]
            let nalType = header & 0x1F
            let nri = (header >> 5) & 0x03
            let payload = Array(nalBytes.dropFirst())

            if payload.count + 1 <= maxPayload {
                // 单 NAL 包
                var p = makeRTPHeader(sequence: &sequence, timestamp: timestamp, ssrc: ssrc, marker: isLastNAL, payloadType: 96)
                p.append(header)
                p.append(contentsOf: payload)
                packets.append(p)
            } else {
                // FU-A 分片
                let fuIndicator = UInt8((nri << 5) | 28)
                let fuHeaderBase = UInt8(nalType)
                let chunkSize = maxPayload - 2
                var offset = 0
                while offset < payload.count {
                    let chunkEnd = min(offset + chunkSize, payload.count)
                    let chunk = Array(payload[offset..<chunkEnd])
                    let isFirst = offset == 0
                    let isLast = chunkEnd >= payload.count
                    offset = chunkEnd

                    var fuHeader = fuHeaderBase
                    if isFirst { fuHeader |= 0x80 }
                    if isLast { fuHeader |= 0x40 }

                    var p = makeRTPHeader(sequence: &sequence, timestamp: timestamp, ssrc: ssrc, marker: isLastNAL && isLast, payloadType: 96)
                    p.append(fuIndicator)
                    p.append(fuHeader)
                    p.append(contentsOf: chunk)
                    packets.append(p)
                }
            }
        }
        return packets
    }

    // MARK: - AAC RTP 封包（RFC 3640）

    /// 将裸 AAC 数据打包为一个 RTP 包（mpeg4-generic，AU 头模式）
    static func packetizeAAC(_ rawAAC: Data, timestamp: UInt32, sequence: inout UInt16, ssrc: UInt32) -> Data {
        var p = makeRTPHeader(sequence: &sequence, timestamp: timestamp, ssrc: ssrc, marker: true, payloadType: 97)
        // AU-headers-length（16 位，单位：位）= 16，表示后面跟 1 个 16 位的 AU 头
        p.append(0x00)
        p.append(0x10)
        // AU-header：AU-size（13 位，单位：位）+ AU-index（3 位，=0）
        let sizeBits = UInt16(rawAAC.count * 8)
        p.append(UInt8(truncatingIfNeeded: sizeBits >> 8))
        p.append(UInt8(truncatingIfNeeded: sizeBits & 0xFF))
        p.append(rawAAC)
        return p
    }

    /// 构造 12 字节 RTP 头
    static func makeRTPHeader(sequence: inout UInt16, timestamp: UInt32, ssrc: UInt32, marker: Bool, payloadType: UInt8) -> Data {
        var h = Data(capacity: 12)
        h.append(0x80) // V=2, P=0, X=0, CC=0
        h.append((marker ? 0x80 : 0x00) | (payloadType & 0x7F))
        h.append(UInt8(truncatingIfNeeded: sequence >> 8))
        h.append(UInt8(truncatingIfNeeded: sequence & 0xFF))
        sequence &+= 1
        h.append(UInt8(truncatingIfNeeded: timestamp >> 24))
        h.append(UInt8(truncatingIfNeeded: timestamp >> 16))
        h.append(UInt8(truncatingIfNeeded: timestamp >> 8))
        h.append(UInt8(truncatingIfNeeded: timestamp & 0xFF))
        h.append(UInt8(truncatingIfNeeded: ssrc >> 24))
        h.append(UInt8(truncatingIfNeeded: ssrc >> 16))
        h.append(UInt8(truncatingIfNeeded: ssrc >> 8))
        h.append(UInt8(truncatingIfNeeded: ssrc & 0xFF))
        return h
    }
}

// MARK: - 单个 RTSP 连接

/// 一条 RTSP 客户端连接（状态机 + TCP interleaved 发送）
private class RTSPConnection {

    let connection: NWConnection
    let queue: DispatchQueue
    private weak var server: RtspServer?

    /// 是否已 PLAY（开始拉流）
    private(set) var isPlaying = false

    /// 视频/音频 RTP 序列号与 SSRC
    var videoSequence: UInt16 = UInt16.random(in: 0..<UInt16.max)
    var audioSequence: UInt16 = UInt16.random(in: 0..<UInt16.max)
    let videoSSRC: UInt32 = UInt32.random(in: 0..<UInt32.max)
    let audioSSRC: UInt32 = UInt32.random(in: 0..<UInt32.max)

    private let sessionID = String(format: "%08X", UInt32.random(in: 0..<UInt32.max))

    private var receiveBuffer = Data()
    private var pendingInterleaved: (length: Int)?
    private var lastCSeq = 0

    init(connection: NWConnection, queue: DispatchQueue, server: RtspServer) {
        self.connection = connection
        self.queue = queue
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .failed, .cancelled:
                self.server?.removeConnection(self)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop()
    }

    func close() {
        connection.cancel()
        server?.removeConnection(self)
    }

    // MARK: - 接收

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.handleIncoming(data)
            }
            if isComplete || error != nil {
                self.close()
            } else {
                self.receiveLoop()
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        receiveBuffer.append(data)
        processBuffer()
    }

    /// 解析 RTSP 请求与 interleaved（RTCP）数据
    private func processBuffer() {
        while true {
            if let pending = pendingInterleaved {
                if receiveBuffer.count >= pending.length {
                    receiveBuffer.removeFirst(pending.length)
                    pendingInterleaved = nil
                    continue
                } else {
                    return
                }
            }

            guard receiveBuffer.count >= 4 else { return }
            let first = receiveBuffer[receiveBuffer.startIndex]

            if first == 0x24 {
                // interleaved 帧：$ channel len_hi len_lo（RTCP，内容忽略）
                let length = (Int(receiveBuffer[receiveBuffer.startIndex + 2]) << 8)
                    | Int(receiveBuffer[receiveBuffer.startIndex + 3])
                receiveBuffer.removeFirst(4)
                pendingInterleaved = (length)
                continue
            }

            // RTSP 请求以 \r\n\r\n 结尾
            if let range = receiveBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let requestData = receiveBuffer.subdata(in: receiveBuffer.startIndex..<range.lowerBound)
                receiveBuffer.removeSubrange(receiveBuffer.startIndex..<range.upperBound)
                handleRequest(requestData)
            } else {
                return
            }
        }
    }

    // MARK: - 请求处理

    private func handleRequest(_ requestData: Data) {
        guard let text = String(data: requestData, encoding: .utf8) else { return }

        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let url = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        if let cseqValue = headers["cseq"], let cseq = Int(cseqValue) {
            lastCSeq = cseq
        }

        switch method {
        case "OPTIONS":
            sendResponse(status: "200 OK", extraHeaders: "Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER\r\n")

        case "DESCRIBE":
            let sdp = server?.makeSDP() ?? RtspServer().makeSDP()
            let body = Data(sdp.utf8)
            sendResponse(status: "200 OK", contentType: "application/sdp", body: body)

        case "SETUP":
            if url.contains("trackID=1") || url.hasSuffix("/1") {
                sendResponse(status: "200 OK", transport: "RTP/AVP/TCP;unicast;interleaved=1-1;ssrc=\(String(format: "%08X", audioSSRC))")
            } else {
                sendResponse(status: "200 OK", transport: "RTP/AVP/TCP;unicast;interleaved=0-0;ssrc=\(String(format: "%08X", videoSSRC))")
            }

        case "PLAY":
            isPlaying = true
            server?.refreshClientCount()
            let rtpInfo = "url=\(url)/trackID=0;seq=\(videoSequence);rtptime=\(server?.videoTimestamp ?? 0), url=\(url)/trackID=1;seq=\(audioSequence);rtptime=\(server?.audioTimestamp ?? 0)"
            sendResponse(status: "200 OK", extraHeaders: "RTP-Info: \(rtpInfo)\r\n")

        case "PAUSE":
            isPlaying = false
            server?.refreshClientCount()
            sendResponse(status: "200 OK")

        case "TEARDOWN":
            sendResponse(status: "200 OK")
            close()

        case "GET_PARAMETER", "SET_PARAMETER":
            sendResponse(status: "200 OK")

        default:
            sendResponse(status: "405 Method Not Allowed")
        }
    }

    // MARK: - 发送

    /// 发送一组 RTP 包（TCP interleaved 封装，打包为一次发送）
    func sendInterleaved(_ packets: [Data], channel: UInt8) {
        guard isPlaying, !packets.isEmpty else { return }
        var frame = Data()
        for p in packets {
            frame.append(0x24)
            frame.append(channel)
            frame.append(UInt8(truncatingIfNeeded: p.count >> 8))
            frame.append(UInt8(truncatingIfNeeded: p.count & 0xFF))
            frame.append(p)
        }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func sendResponse(status: String, transport: String? = nil, contentType: String? = nil, body: Data? = nil, extraHeaders: String? = nil) {
        var response = "RTSP/1.0 \(status)\r\n"
        response += "CSeq: \(lastCSeq)\r\n"
        response += "Server: AvoCamUSB/1.0\r\n"
        response += "Session: \(sessionID)\r\n"
        if let transport = transport {
            response += "Transport: \(transport)\r\n"
        }
        if let contentType = contentType {
            response += "Content-Type: \(contentType)\r\n"
        }
        if let extraHeaders = extraHeaders {
            response += extraHeaders
        }
        response += "Content-Length: \(body?.count ?? 0)\r\n"
        response += "\r\n"

        var data = Data(response.utf8)
        if let body = body {
            data.append(body)
        }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
