# AvoCamUSB - iPhone USB / WiFi 虚拟摄像头

通过 USB 数据线或 WiFi 将 iPhone 摄像头作为电脑虚拟摄像头，用于直播。无水印、支持最高分辨率和帧率、支持音频传输。

## 功能特性

- ✅ USB 有线连接，低延迟高带宽（OBS iOS Camera 插件）
- ✅ **WiFi 无线连接（RTSP 推流，OBS 媒体源 / VLC 直接拉流，无需数据线）**
- ✅ **Bonjour 局域网广播**（`_avocamusb._tcp`，同 WiFi 下可被发现）
- ✅ 自动检测 iPhone 摄像头最高规格（4K 60fps）
- ✅ 自动对焦、光学防抖、自动曝光、自动白平衡（原生功能自动生效）
- ✅ H.264 硬编码（VideoToolbox）
- ✅ AAC 音频编码（麦克风同步传输，USB 与 WiFi 均支持）
- ✅ 前后摄像头切换、闪光灯、数码变焦、息屏省电
- ✅ 纯中文界面
- ✅ 无水印

## 系统要求

- iPhone：iOS 15.0+
- 电脑：Windows 10/11 或 macOS
- USB 方式：OBS Studio + obs-ios-camera-source 插件 + iTunes / Apple Devices（usbmuxd 服务）
- WiFi 方式：OBS Studio（媒体源）或 VLC，无需任何插件

## 通信协议

### 1. USB 方式（Portal 协议，端口 2345）

iPhone 端监听 **2345 端口**，OBS 插件通过 usbmuxd 隧道连接。

数据包格式（Portal Protocol，16字节头+载荷）：
```
version(4) + type(4) + tag(4) + payloadSize(4) + payload
```
- type=101：视频包（H.264 Annex-B 格式）
- type=102：音频包（AAC ADTS 格式）

### 2. WiFi 方式（RTSP 协议，端口 8554）

iPhone 端监听 **8554 端口**，推流地址：`rtsp://<iPhone局域网IP>:8554/live`

- 视频轨：H.264，RTP/AVP 96（RFC 6184，TCP interleaved 传输）
- 音频轨：AAC-LC 48kHz 单声道，RTP/AVP 97（RFC 3640）
- 同时通过 Bonjour（`_avocamusb._tcp`）广播 2345 端口服务

## 编译（GitHub Actions 云编译，无需 Mac）

### 1. 推送代码到 GitHub

```bash
cd AvoCamUSB-WiFi
git init
git add .
git commit -m "Add WiFi RTSP streaming"
git branch -M main
git remote add origin https://github.com/你的用户名/AvoCamUSB.git
git push -u origin main
```

### 2. 触发编译

推送后 GitHub Actions 会自动开始编译（约 5-10 分钟）。

也可以手动触发：仓库页面 → Actions → Build iOS App → Run workflow

### 3. 下载 ipa

编译完成后：
- 仓库页面 → Actions → 最新的 build 任务
- 页面底部 Artifacts → 下载 `AvoCamUSB.ipa`

## 安装到 iPhone

使用 SideStore 或 AltStore 安装 ipa：

1. 电脑端安装 SideStore（推荐，无需电脑常驻）
2. iPhone 安装 SideStore
3. 在 SideStore 中导入下载的 ipa 文件
4. 点击安装，7天后需要刷新签名（免费 Apple ID）

## 使用方法

### USB 有线连接（推荐，低延迟）

1. 用 USB 数据线连接 iPhone 到电脑
2. iPhone 上点"信任此电脑"
3. 打开 AvoCamUSB App，点"开始推流"
4. 电脑上打开 OBS，来源 → + → iOS Camera
5. 启动 OBS 虚拟摄像头
6. 在抖音直播伴侣中选择 OBS Virtual Camera 作为摄像头

### WiFi 无线连接（无需数据线）

1. iPhone 与电脑连接到**同一个 WiFi**
2. 打开 App，点"开始推流"，在「设备信息」卡片查看「WiFi 推流地址」（形如 `rtsp://192.168.x.x:8554/live`）
3. 电脑 OBS：来源 → + → 媒体源 → 取消勾选"本地文件" → 输入该 rtsp 地址 → 播放
4. 也可用 VLC：媒体 → 打开网络串流 → 输入同一地址

> 提示：
> - 首次使用 WiFi 时，iOS 会弹出「本地网络」权限请求，请允许。
> - WiFi 画质与延迟取决于路由器性能和信号强度；直播建议使用 5GHz WiFi。
> - USB 与 WiFi 可同时使用（互不影响）。

## 项目结构

```
AvoCamUSB/
├── AvoCamUSBApp.swift          # App 入口
├── Models/
│   └── PortalProtocol.swift     # Portal 协议封装
├── Services/
│   ├── CameraCapabilities.swift # 设备能力检测
│   ├── CaptureManager.swift     # 摄像头+麦克风采集
│   ├── VideoEncoder.swift       # H.264 硬编码
│   ├── AudioManager.swift       # AAC 音频编码
│   ├── NetworkServer.swift      # TCP 监听 2345 端口 + Bonjour 广播
│   ├── RtspServer.swift         # RTSP 推流服务器（WiFi，端口 8554）
│   ├── NetworkInfo.swift        # 局域网 IP 获取
│   └── StreamController.swift   # 流控制器
├── Views/
│   └── ContentView.swift        # SwiftUI 界面
└── Resources/
    └── Info.plist               # 权限配置
```

## 许可证

GPL-2.0（基于 obs-ios-camera-source 二次开发）
