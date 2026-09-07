//
//  ContentView.swift
//  AvoCamUSB
//
//  主界面 - SwiftUI 纯中文
//

import SwiftUI

/// 主界面
struct ContentView: View {

    @EnvironmentObject private var streamController: StreamController

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {

                    // 标题
                    Text("iPhone USB / WiFi 虚拟摄像头")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .padding(.top)

                    Text("通过 USB 数据线或 WiFi 将 iPhone 摄像头作为电脑虚拟摄像头")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    // 状态卡片
                    statusCard

                    // 统计卡片
                    statsCard

                    // 视频设置卡片
                    videoSettingsCard

                    // 功耗优化卡片
                    powerSavingCard

                    // 设备信息
                    deviceInfoCard

                    // 控制按钮
                    controlButtons

                    // 使用说明
                    usageGuide

                    Spacer()
                }
                .padding()
            }
            .navigationBarTitle("AvoCam USB", displayMode: .inline)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - 状态卡片

    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: streamController.isStreaming ? "video.fill" : "video.slash")
                    .font(.title2)
                    .foregroundColor(streamController.isStreaming ? .green : .red)

                Text(streamController.isStreaming ? "正在推流" : "未推流")
                    .font(.headline)

                Spacer()

                Circle()
                    .fill(streamController.isConnected ? Color.green : Color.gray)
                    .frame(width: 12, height: 12)
                Text(streamController.isConnected ? "电脑已连接" : "等待电脑连接")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("视频帧")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(streamController.videoFramesSent)")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("音频帧")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(streamController.audioFramesSent)")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - 统计卡片

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("推流统计", systemImage: "chart.bar")
                .font(.headline)

            Divider()

            HStack {
                statItem(title: "推流时长", value: streamController.streamDuration)
                Spacer()
                statItem(title: "实时帧率", value: "\(streamController.currentFps) fps")
                Spacer()
                statItem(title: "实时码率", value: formatBitrate(streamController.currentBitrate))
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }

    private func formatBitrate(_ bps: Int) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bps) / 1_000_000.0)
        } else if bps >= 1_000 {
            return "\(bps / 1_000) Kbps"
        } else {
            return "\(bps) bps"
        }
    }

    // MARK: - 视频设置卡片

    private var videoSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("视频设置", systemImage: "slider.horizontal.3")
                .font(.headline)

            Divider()

            // 分辨率和帧率选择器
            VStack(alignment: .leading, spacing: 4) {
                Text("分辨率 / 帧率")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("分辨率 / 帧率", selection: Binding(
                    get: { streamController.selectedFormatIndex },
                    set: { streamController.selectFormat(at: $0) }
                )) {
                    ForEach(0..<streamController.availableFormats.count, id: \.self) { index in
                        Text(streamController.availableFormats[index].description)
                            .tag(index)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .disabled(streamController.isStreaming)
            }

            // 方向选择器
            VStack(alignment: .leading, spacing: 4) {
                Text("视频方向")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("视频方向", selection: $streamController.selectedOrientation) {
                    ForEach(VideoOrientation.allCases) { orientation in
                        Text(orientation.rawValue).tag(orientation)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .disabled(streamController.isStreaming)
            }

            // 码率选择器
            VStack(alignment: .leading, spacing: 4) {
                Text("编码码率")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("编码码率", selection: $streamController.selectedBitrateIndex) {
                    ForEach(0..<streamController.bitrateOptions.count, id: \.self) { index in
                        Text(streamController.bitrateOptions[index].label).tag(index)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .disabled(streamController.isStreaming)
            }

            if streamController.isStreaming {
                Text("推流中无法切换设置，请先停止推流")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - 功耗优化卡片

    private var powerSavingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("功耗优化", systemImage: "bolt.fill")
                .font(.headline)

            Divider()

            // 音频开关
            Toggle(isOn: $streamController.audioEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("麦克风音频传输")
                        .font(.subheadline)
                    Text("关闭后不采集麦克风，省电约 3-5%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .disabled(streamController.isStreaming)

            // 极简模式开关
            Toggle(isOn: $streamController.minimalMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("极简模式（关闭统计刷新）")
                        .font(.subheadline)
                    Text("关闭帧率/码率/帧数统计刷新，省电约 2-3%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .disabled(streamController.isStreaming)

            if streamController.isStreaming {
                Text("推流中无法切换设置，请先停止推流")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - 设备信息

    private var deviceInfoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("设备信息", systemImage: "info.circle")
                .font(.headline)

            Divider()

            HStack {
                Text("设备型号")
                    .foregroundColor(.secondary)
                Spacer()
                Text(streamController.deviceName)
                    .fontWeight(.medium)
            }

            HStack {
                Text("当前规格")
                    .foregroundColor(.secondary)
                Spacer()
                Text(streamController.currentFormat)
                    .fontWeight(.medium)
                    .foregroundColor(.blue)
            }

            HStack {
                Text("连接方式")
                    .foregroundColor(.secondary)
                Spacer()
                Text("USB 有线 / WiFi 无线")
                    .fontWeight(.medium)
            }

            HStack {
                Text("局域网 IP")
                    .foregroundColor(.secondary)
                Spacer()
                Text(NetworkInfo.ipv4Addresses().isEmpty ? "未连接 WiFi" : NetworkInfo.ipv4Addresses().joined(separator: " "))
                    .fontWeight(.medium)
            }

            if let ip = NetworkInfo.wifiIP() {
                HStack {
                    Text("WiFi 推流地址")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("rtsp://\(ip):\(RtspServer.defaultPort)/live")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                        .multilineTextAlignment(.trailing)
                }
            }

            HStack {
                Text("监听端口")
                    .foregroundColor(.secondary)
                Spacer()
                Text("2345 (USB) / \(RtspServer.defaultPort) (WiFi)")
                    .fontWeight(.medium)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - 控制按钮

    private var controlButtons: some View {
        VStack(spacing: 12) {
            Button(action: {
                if streamController.isStreaming {
                    streamController.stop()
                } else {
                    streamController.start()
                }
            }) {
                HStack {
                    Image(systemName: streamController.isStreaming ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                    Text(streamController.isStreaming ? "停止推流" : "开始推流")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(streamController.isStreaming ? Color.red : Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
            }

            HStack(spacing: 12) {
                Button(action: {
                    streamController.switchCamera()
                }) {
                    Label("切换摄像头", systemImage: "camera.rotate")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .cornerRadius(10)
                }
                .disabled(!streamController.isStreaming)

                Button(action: {
                    streamController.toggleTorch()
                }) {
                    Label(streamController.isTorchOn ? "关灯" : "闪光灯",
                          systemImage: streamController.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(streamController.isTorchOn ? Color.yellow : Color(.systemGray5))
                        .foregroundColor(streamController.isTorchOn ? .black : .primary)
                        .cornerRadius(10)
                }
                .disabled(!streamController.isStreaming)

                Button(action: {
                    streamController.toggleScreenDim()
                }) {
                    Label(streamController.isScreenDimmed ? "恢复屏幕" : "息屏",
                          systemImage: streamController.isScreenDimmed ? "sun.max.fill" : "moon.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(streamController.isScreenDimmed ? Color.orange : Color(.systemGray5))
                        .foregroundColor(streamController.isScreenDimmed ? .white : .primary)
                        .cornerRadius(10)
                }
                .disabled(!streamController.isStreaming)
            }

            // 缩放滑块（推流中可实时调节）
            if streamController.isStreaming {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("缩放")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.1fx", streamController.zoomFactor))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                    }
                    Slider(
                        value: Binding(
                            get: { streamController.zoomFactor },
                            set: { streamController.setZoom($0) }
                        ),
                        in: 1.0...5.0,
                        step: 0.1
                    )
                    .accentColor(.blue)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - 使用说明

    private var usageGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("使用说明", systemImage: "questionmark.circle")
                .font(.headline)

            Divider()

            Text("USB 有线连接（OBS 插件）")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                stepView(number: 1, text: "用数据线将 iPhone 连接到电脑")
                stepView(number: 2, text: "在 iPhone 上点击「信任此电脑」")
                stepView(number: 3, text: "确保电脑已安装 iTunes 或 Apple Devices")
                stepView(number: 4, text: "在「视频设置」中选择分辨率、方向和码率")
                stepView(number: 5, text: "App 打开后自动开始推流")
                stepView(number: 6, text: "在电脑端 OBS 中添加「iOS Camera」来源")
                stepView(number: 7, text: "启动 OBS 虚拟摄像头，在抖音直播伴侣中选择")
                stepView(number: 8, text: "推流中可点击「息屏」降低屏幕发热，快速双击屏幕中央唤醒")
            }

            Divider()

            Text("WiFi 无线连接（OBS 媒体源 / VLC）")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                stepView(number: 1, text: "iPhone 与电脑连接到同一个 WiFi")
                stepView(number: 2, text: "打开 App 并点击「开始推流」，记下「WiFi 推流地址」（如上所示）")
                stepView(number: 3, text: "在电脑端 OBS 中添加「媒体源」，输入该 rtsp 地址")
                stepView(number: 4, text: "勾选「网络缓冲」后点击播放，无需数据线即可看到画面")
                stepView(number: 5, text: "也可用 VLC 播放器直接打开该 rtsp 地址验证")
            }

            Divider()

            Text("提示：USB 与 WiFi 两种方式可同时使用；WiFi 画质取决于路由器与信号强度。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func stepView(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue)
                .clipShape(Circle())

            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
