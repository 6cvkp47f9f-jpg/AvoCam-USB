//
//  VideoEncoder.swift
//  AvoCamUSB
//
//  视频硬编码 - VideoToolbox H.264
//

import AVFoundation
import CoreVideo
import VideoToolbox

/// H.264 视频编码器
class VideoEncoder {

    private var compressionSession: VTCompressionSession?
    private let encoderQueue = DispatchQueue(label: "com.avocamusb.encoder.video")

    /// 编码后的 H.264 Annex-B 数据回调
    var onEncodedFrame: ((Data, Double) -> Void)?

    /// 当前配置
    private(set) var width: Int = 1920
    private(set) var height: Int = 1080
    private(set) var frameRate: Int = 30
    private(set) var bitrate: Int = 8_000_000 // 8 Mbps

    // MARK: - 配置与创建

    /// 配置编码器
    func configure(width: Int, height: Int, frameRate: Int, bitrate: Int = 8_000_000) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitrate = bitrate

        encoderQueue.async { [weak self] in
            self?.destroySession()
            self?.createSession()
        }
    }

    private func createSession() {
        var status: OSStatus = noErr

        // 创建压缩会话（直接传入输出回调）
        var session: VTCompressionSession?
        status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: { (outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer) in
                guard let sampleBuffer = sampleBuffer, status == noErr else { return }
                guard let refCon = outputCallbackRefCon else { return }
                let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
                encoder.handleEncodedSampleBuffer(sampleBuffer, infoFlags: infoFlags)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let compressionSession = session else {
            print("[VideoEncoder] 创建压缩会话失败: \(status)")
            return
        }

        self.compressionSession = compressionSession

        // 设置编码属性（功耗优化：不降低画质，只降低编码开销）
        let properties: [NSString: Any] = [
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel, // 保持High Profile，不损失画质
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [bitrate / 8, 1] as CFArray, // CBR恒定码率，计算量更平稳
            kVTCompressionPropertyKey_MaxKeyFrameInterval: max(60, frameRate * 2), // 关键帧间隔帧数（下限60，避免实际帧率低时间隔过长）
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2.0, // 关键帧间隔真实时间 2 秒（按实际帧率插关键帧，出错后快速恢复）
            kVTCompressionPropertyKey_AllowFrameReordering: false, // 无 B 帧
            kVTCompressionPropertyKey_PixelTransferProperties: [
                "ScalingMode": "Trim"
            ],
            // BT.709 色彩空间标志（确保色彩准确）
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ]

        for (key, value) in properties {
            VTSessionSetProperty(compressionSession, key: key, value: value as CFTypeRef)
        }

        // 准备编码
        VTCompressionSessionPrepareToEncodeFrames(compressionSession)

        print("[VideoEncoder] 编码器已创建: \(width)x\(height) @ \(frameRate)fps, \(bitrate / 1_000_000)Mbps")
    }

    private func destroySession() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    // MARK: - 编码

    /// 编码一帧（CVPixelBuffer）
    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        encoderQueue.async { [weak self] in
            guard let self = self, let session = self.compressionSession else { return }

            let duration = CMTime(value: 1, timescale: CMTimeScale(self.frameRate))

            var status: OSStatus = noErr
            var flags: VTEncodeInfoFlags = []

            status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTime,
                duration: duration,
                frameProperties: nil,
                sourceFrameRefcon: nil,
                infoFlagsOut: &flags
            )

            if status != noErr {
                print("[VideoEncoder] 编码帧失败: \(status)")
            }
        }
    }

    // MARK: - 编码结果处理

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer, infoFlags: VTEncodeInfoFlags) {
        // 检查是否是关键帧（通过 NotSync 附件判断）
        let isKeyFrame = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            .flatMap { ($0 as? [[CFString: Any]])?.first }
            .map { !($0[kCMSampleAttachmentKey_NotSync] as? Bool ?? false) } ?? true

        // 获取编码数据
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            print("[VideoEncoder] 无法获取 dataBuffer")
            return
        }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let pointer = dataPointer else {
            print("[VideoEncoder] 无法获取数据指针: \(status)")
            return
        }

        // 转换为 Data
        let h264Data = Data(bytes: pointer, count: length)

        // 处理 NAL 单元（AVCC 格式 → Annex-B 格式）
        var annexBData = convertAVCCToAnnexB(h264Data)

        // 如果是关键帧，从格式描述中提取 SPS/PPS 并添加到数据前面
        if isKeyFrame {
            if let spsPpsData = extractSPSPPS(from: sampleBuffer) {
                annexBData = spsPpsData + annexBData
                print("[VideoEncoder] 关键帧: 已添加 SPS/PPS (\(spsPpsData.count) 字节), 视频数据 \(annexBData.count) 字节")
            } else {
                print("[VideoEncoder] 关键帧: 无法提取 SPS/PPS!")
            }
        }

        // 直接在编码线程调用回调，不切主线程（减少线程切换，降低 CPU）
        // 提取真实 PTS（秒），供 RTSP RTP 时间戳使用
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        self.onEncodedFrame?(annexBData, pts)
    }

    /// 从 CMSampleBuffer 的格式描述中提取 SPS/PPS（Annex-B 格式）
    private func extractSPSPPS(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        var spsData: Data?
        var ppsData: Data?

        // 获取参数集数量
        var parameterSetCount: Int = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: nil
        )

        guard status == noErr, parameterSetCount >= 2 else {
            print("[VideoEncoder] 获取参数集数量失败: \(status), count: \(parameterSetCount)")
            return nil
        }

        // 提取 SPS (index 0)
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize: Int = 0
        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        if spsStatus == noErr, let pointer = spsPointer, spsSize > 0 {
            spsData = Data(bytes: pointer, count: spsSize)
        }

        // 提取 PPS (index 1)
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize: Int = 0
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        if ppsStatus == noErr, let pointer = ppsPointer, ppsSize > 0 {
            ppsData = Data(bytes: pointer, count: ppsSize)
        }

        guard let sps = spsData, let pps = ppsData else {
            print("[VideoEncoder] SPS 或 PPS 提取失败")
            return nil
        }

        // 组合为 Annex-B 格式：起始码 + SPS + 起始码 + PPS
        var result = Data()
        result.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        result.append(sps)
        result.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        result.append(pps)

        return result
    }

    /// 将 AVCC 格式的 H.264 数据转换为 Annex-B 格式
    private func convertAVCCToAnnexB(_ data: Data) -> Data {
        var result = Data()
        var offset = 0

        while offset + 4 <= data.count {
            // 读取 4 字节的 NAL 单元长度（大端序）
            let nalLength = data.subdata(in: offset..<offset+4).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            offset += 4

            guard offset + Int(nalLength) <= data.count else { break }

            // 写入 Annex-B 起始码 0x00000001
            result.append(contentsOf: [0x00, 0x00, 0x00, 0x01])

            // 写入 NAL 单元数据
            result.append(data.subdata(in: offset..<offset+Int(nalLength)))
            offset += Int(nalLength)
        }

        return result
    }

    deinit {
        destroySession()
    }
}
