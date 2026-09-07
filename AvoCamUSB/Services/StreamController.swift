//
//  StreamController.swift
//  AvoCamUSB
//
//  流控制器 - 协调采集、编码、网络发送
//

import Foundation
import AVFoundation
import CoreVideo
import UIKit

/// 日志输出（Release 版关闭）
func avoPrint(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    #if DEBUG
    print(items, separator: separator, terminator: terminator)
    #endif
}

/// 视频方向
enum VideoOrientation: String, CaseIterable, Identifiable {
    case landscape = "横屏"
    case portrait = "竖屏"
    var id: String { rawValue }
}

/// 码率选项
struct BitrateOption: Identifiable {
    let id = UUID()
    let label: String
    let value: Int // bps
}

/// 流控制器 - 协调所有模块
class StreamController: ObservableObject {

    // 模块
    private let captureManager = CaptureManager()
    private let videoEncoder = VideoEncoder()
    private let audioManager = AudioManager()
    private let networkServer = NetworkServer()
    private let rtspServer = RtspServer()

    // 状态锁，防止并发 start/stop 导致闪退
    private let stateLock = NSLock()

    // 状态
    @Published var isStreaming: Bool = false
    @Published var isConnected: Bool = false

    /// WiFi 推流地址列表（rtsp://<IP>:8554/live），供界面显示
    var rtspAddresses: [String] {
        NetworkInfo.ipv4Addresses().map { "rtsp://\($0):\(RtspServer.defaultPort)/live" }
    }
    @Published var currentFormat: String = "检测中..."
    @Published var deviceName: String = ""
    @Published var videoFramesSent: Int = 0
    @Published var audioFramesSent: Int = 0
    @Published var isScreenDimmed: Bool = false
    @Published var isTorchOn: Bool = false
    @Published var zoomFactor: Double = 1.0

    // 统计信息（每秒刷新一次）
    @Published var streamDuration: String = "00:00"
    @Published var currentFps: Int = 0
    @Published var currentBitrate: Int = 0 // bps

    // 可用格式列表
    @Published var availableFormats: [CameraFormatInfo] = []
    @Published var selectedFormatIndex: Int = 0

    // 方向选择
    @Published var selectedOrientation: VideoOrientation = .landscape {
        didSet { saveSettings() }
    }

    // 码率选择
    @Published var selectedBitrateIndex: Int = 2 { // 默认 6Mbps
        didSet { saveSettings() }
    }

    let bitrateOptions: [BitrateOption] = [
        BitrateOption(label: "2 Mbps", value: 2_000_000),
        BitrateOption(label: "4 Mbps", value: 4_000_000),
        BitrateOption(label: "6 Mbps", value: 6_000_000),
        BitrateOption(label: "8 Mbps", value: 8_000_000),
        BitrateOption(label: "10 Mbps", value: 10_000_000),
        BitrateOption(label: "12 Mbps", value: 12_000_000),
        BitrateOption(label: "15 Mbps", value: 15_000_000),
        BitrateOption(label: "20 Mbps", value: 20_000_000),
        BitrateOption(label: "30 Mbps", value: 30_000_000),
        BitrateOption(label: "50 Mbps", value: 50_000_000),
        BitrateOption(label: "80 Mbps", value: 80_000_000),
        BitrateOption(label: "100 Mbps", value: 100_000_000)
    ]

    // 摄像头位置
    private var currentPosition: AVCaptureDevice.Position = .back

    // UserDefaults 键
    private let kFormatIndex = "avocam_format_index"
    private let kOrientation = "avocam_orientation"
    private let kBitrateIndex = "avocam_bitrate_index"
    private let kAutoStart = "avocam_auto_start"
    private let kAudioEnabled = "avocam_audio_enabled"
    private let kMinimalMode = "avocam_minimal_mode"
    private let kWiFiEnabled = "avocam_wifi_enabled"

    // 自动启动
    @Published var autoStartOnLaunch: Bool = true {
        didSet { saveSettings() }
    }

    // 音频开关（默认关闭，省电）
    @Published var audioEnabled: Bool = false {
        didSet { saveSettings() }
    }

    // 极简模式（关闭统计刷新，更省电）
    @Published var minimalMode: Bool = false {
        didSet { saveSettings() }
    }
    @Published var wifiEnabled: Bool = true

    // 统计用变量
    private var streamStartTime: Date?
    private var statsTimer: Timer?
    private var framesInLastSecond: Int = 0
    private var bytesInLastSecond: Int = 0

    // 记录上次推流状态（用于切回前台自动恢复）
    private var wasStreamingBeforeBackground: Bool = false

    init() {
        setupCallbacks()
        deviceName = CameraCapabilities.getDeviceName()
        loadAvailableFormats()
        loadSettings()
        setupForegroundObserver()
    }

    deinit {
        statsTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 前后台监听

    private func setupForegroundObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func handleDidEnterBackground() {
        // 进入后台时记录是否在推流
        wasStreamingBeforeBackground = isStreaming
        avoPrint("[StreamController] 进入后台，推流状态: \(isStreaming)")
    }

    @objc private func handleWillEnterForeground() {
        // 切回前台时，如果之前在推流但现在停止了，自动恢复
        if wasStreamingBeforeBackground && !isStreaming {
            avoPrint("[StreamController] 切回前台，自动恢复推流")
            start()
        }
    }

    // MARK: - 配置持久化

    private func loadSettings() {
        let defaults = UserDefaults.standard
        let savedFormat = defaults.integer(forKey: kFormatIndex)
        if savedFormat >= 0 && savedFormat < availableFormats.count {
            selectedFormatIndex = savedFormat
            currentFormat = availableFormats[savedFormat].description
        }
        if let orientationRaw = defaults.string(forKey: kOrientation),
           let orientation = VideoOrientation(rawValue: orientationRaw) {
            selectedOrientation = orientation
        }
        let savedBitrate = defaults.integer(forKey: kBitrateIndex)
        if savedBitrate >= 0 && savedBitrate < bitrateOptions.count {
            selectedBitrateIndex = savedBitrate
        }
        if defaults.object(forKey: kAutoStart) != nil {
            autoStartOnLaunch = defaults.bool(forKey: kAutoStart)
        }
        if defaults.object(forKey: kAudioEnabled) != nil {
            audioEnabled = defaults.bool(forKey: kAudioEnabled)
        }
        if defaults.object(forKey: kMinimalMode) != nil {
            minimalMode = defaults.bool(forKey: kMinimalMode)
        }
        if defaults.object(forKey: kWiFiEnabled) != nil {
            wifiEnabled = defaults.bool(forKey: kWiFiEnabled)
        }
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(selectedFormatIndex, forKey: kFormatIndex)
        defaults.set(selectedOrientation.rawValue, forKey: kOrientation)
        defaults.set(selectedBitrateIndex, forKey: kBitrateIndex)
        defaults.set(autoStartOnLaunch, forKey: kAutoStart)
        defaults.set(audioEnabled, forKey: kAudioEnabled)
        defaults.set(minimalMode, forKey: kMinimalMode)
        defaults.set(wifiEnabled, forKey: kWiFiEnabled)
    }

    // MARK: - 格式列表

    private func loadAvailableFormats() {
        availableFormats = CameraCapabilities.getAllFormats(position: .back)
        if !availableFormats.isEmpty {
            selectedFormatIndex = 0
            currentFormat = availableFormats[0].description
        }
    }

    func selectFormat(at index: Int) {
        guard index >= 0 && index < availableFormats.count else { return }
        selectedFormatIndex = index
        let format = availableFormats[index]
        currentFormat = format.description
        saveSettings()

        if isStreaming {
            reconfigureWithFormat(format)
        }
    }

    private func reconfigureWithFormat(_ format: CameraFormatInfo) {
        captureManager.stop()
        captureManager.configure(position: currentPosition, format: format, orientation: selectedOrientation)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            let bitrate = self.bitrateOptions[self.selectedBitrateIndex].value
            self.videoEncoder.configure(
                width: self.encodingWidth(for: format),
                height: self.encodingHeight(for: format),
                frameRate: Int(format.maxFrameRate),
                bitrate: bitrate
            )
            self.captureManager.start()
        }
    }

    private func encodingWidth(for format: CameraFormatInfo) -> Int {
        selectedOrientation == .landscape ? format.width : format.height
    }

    private func encodingHeight(for format: CameraFormatInfo) -> Int {
        selectedOrientation == .landscape ? format.height : format.width
    }

    // MARK: - 设置回调

    private func setupCallbacks() {
        captureManager.onVideoFrame = { [weak self] pixelBuffer, timestamp in
            self?.videoEncoder.encode(pixelBuffer: pixelBuffer, presentationTime: timestamp)
        }

        // 编码回调直接在编码线程发送，不切主线程（减少线程切换，降低 CPU）
        videoEncoder.onEncodedFrame = { [weak self] h264Data, pts in
            guard let self = self else { return }
            self.networkServer.sendVideo(h264Data)
            // WiFi 推流：同时发往 RTSP 服务器（OBS 媒体源 / VLC 直接拉流）
            if self.wifiEnabled {
                self.rtspServer.publishVideo(h264Data, pts: pts)
            }
            self.framesInLastSecond += 1
            self.bytesInLastSecond += h264Data.count
            // 极简模式下不更新 UI 计数
            if !self.minimalMode {
                DispatchQueue.main.async {
                    self.videoFramesSent += 1
                }
            }
        }

        // 音频回调（仅在开启音频时有效）
        audioManager.onEncodedAudio = { [weak self] aacData in
            guard let self = self, self.audioEnabled else { return }
            self.networkServer.sendAudio(aacData)
            // WiFi 推流：同时发往 RTSP 服务器
            if self.wifiEnabled {
                self.rtspServer.publishAudio(aacData)
            }
            if !self.minimalMode {
                DispatchQueue.main.async {
                    self.audioFramesSent += 1
                }
            }
        }

        networkServer.onConnectionStateChanged = { [weak self] connected in
            DispatchQueue.main.async {
                self?.updateConnectedState()
            }
        }

        // WiFi（RTSP）客户端数量变化
        rtspServer.onClientCountChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateConnectedState()
            }
        }
    }

    /// 合并 USB（Portal）与 WiFi（RTSP）连接状态
    private func updateConnectedState() {
        isConnected = networkServer.isConnected || rtspServer.clientCount > 0
    }

    // MARK: - 统计

    private func startStats() {
        stopStats()
        streamStartTime = Date()
        framesInLastSecond = 0
        bytesInLastSecond = 0

        // 极简模式下统计刷新间隔 5 秒，普通模式 1 秒
        let interval: TimeInterval = minimalMode ? 5.0 : 1.0

        statsTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // 更新帧率和码率
            self.currentFps = self.framesInLastSecond / Int(interval)
            self.currentBitrate = self.bytesInLastSecond * 8 / Int(interval) // 转成 bps
            self.framesInLastSecond = 0
            self.bytesInLastSecond = 0

            // 更新推流时长
            if let startTime = self.streamStartTime {
                let elapsed = Int(Date().timeIntervalSince(startTime))
                let minutes = elapsed / 60
                let seconds = elapsed % 60
                self.streamDuration = String(format: "%02d:%02d", minutes, seconds)
            }
        }
    }

    private func stopStats() {
        statsTimer?.invalidate()
        statsTimer = nil
        streamStartTime = nil
        currentFps = 0
        currentBitrate = 0
        streamDuration = "00:00"
    }

    // MARK: - 控制

    /// 开始直播流（加锁防止并发）
    func start() {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !isStreaming else {
            avoPrint("[StreamController] 已在推流，忽略重复 start")
            return
        }

        // 选择格式
        let format: CameraFormatInfo
        if selectedFormatIndex < availableFormats.count {
            format = availableFormats[selectedFormatIndex]
        } else {
            format = CameraCapabilities.selectBestFormat(position: .back) ?? availableFormats.first!
        }
        currentFormat = format.description

        // 1. 配置摄像头（带方向）
        captureManager.configure(position: .back, format: format, orientation: selectedOrientation)

        // 2. 配置编码器
        let bitrate = bitrateOptions[selectedBitrateIndex].value
        videoEncoder.configure(
            width: encodingWidth(for: format),
            height: encodingHeight(for: format),
            frameRate: Int(format.maxFrameRate),
            bitrate: bitrate
        )

        // 3. 配置音频（仅在开启时）
        if audioEnabled {
            audioManager.configure()
        }

        // 4. 启动网络服务（Portal 2345，供 OBS 插件 USB 连接）
        networkServer.start()

        // 5. 启动 RTSP 服务（8554，供 OBS 媒体源 / VLC 通过 WiFi 连接；仅 WiFi 推流开启时）
        if wifiEnabled {
            rtspServer.start(audioEnabled: audioEnabled, frameRate: Int(format.maxFrameRate))
        }

        // 6. 延迟启动采集
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self else { return }
            self.captureManager.start(audioEnabled: self.audioEnabled)
            if self.audioEnabled {
                self.audioManager.start()
            }
            self.isStreaming = true
            self.startStats()
            avoPrint("[StreamController] 直播流已启动，码率: \(bitrate / 1_000_000)Mbps, 方向: \(self.selectedOrientation.rawValue), 音频: \(self.audioEnabled ? "开" : "关"), 极简模式: \(self.minimalMode ? "开" : "关")")
        }
    }

    /// 停止直播流（加锁防止并发）
    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard isStreaming else {
            avoPrint("[StreamController] 未在推流，忽略重复 stop")
            return
        }

        captureManager.stop()
        if audioEnabled {
            audioManager.stop()
        }
        networkServer.stop()
        rtspServer.stop()
        stopStats()

        if isScreenDimmed {
            toggleScreenDim()
        }

        isStreaming = false
        videoFramesSent = 0
        audioFramesSent = 0
        avoPrint("[StreamController] 直播流已停止")
    }

    /// 切换前后摄像头
    func switchCamera() {
        currentPosition = (currentPosition == .back) ? .front : .back
        availableFormats = CameraCapabilities.getAllFormats(position: currentPosition)
        selectedFormatIndex = 0

        if isStreaming {
            let format = availableFormats.first ?? CameraCapabilities.selectBestFormat(position: currentPosition)!
            reconfigureWithFormat(format)
        }
    }

    /// 切换息屏
    func toggleScreenDim() {
        if isScreenDimmed {
            ScreenDimmer.shared.disengage()
            isScreenDimmed = false
        } else {
            ScreenDimmer.shared.engage()
            isScreenDimmed = true
        }
    }

    /// 切换闪光灯
    /// 切换 WiFi 推流开关（推流中立即生效）
    func setWifiEnabled(_ enabled: Bool) {
        wifiEnabled = enabled
        saveSettings()
        if isStreaming {
            if enabled {
                let format = availableFormats.indices.contains(selectedFormatIndex) ? availableFormats[selectedFormatIndex] : nil
                let fps = format?.maxFrameRate ?? 30
                rtspServer.start(audioEnabled: audioEnabled, frameRate: Int(fps))
            } else {
                rtspServer.stop()
            }
        }
    }

    func toggleTorch() {
        guard isStreaming else { return }
        if captureManager.toggleTorch() {
            isTorchOn = captureManager.isTorchOn
        }
    }

    /// 设置缩放（1.0 ~ 5.0）
    func setZoom(_ factor: Double) {
        guard isStreaming else { return }
        zoomFactor = factor
        captureManager.setZoom(CGFloat(factor))
    }

    /// 应用启动时自动推流
    func autoStartIfNeeded() {
        guard autoStartOnLaunch, !isStreaming else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.start()
        }
    }
}
