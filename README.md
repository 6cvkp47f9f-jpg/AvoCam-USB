# AvoCam USB — English edition

Fork of [HESHAOJU/AvoCam-USB](https://github.com/HESHAOJU/AvoCam-USB), with an English interface and a fix for the RTSP timestamp overflow crash.

## Build

The build workflow applies `english-camera.patch` to the original source before generating the Xcode project. The patch is readable and contains the interface translation, permission descriptions, saved-orientation migration, version 1.5.1 (build 7), and the RTP timestamp fix. It uses only source code; no camera footage, credentials, or crash reports are included.

Open **Actions → Build English iOS App → Run workflow**. Download the `AvoCamUSB-English-v1.5.1-b7` artifact after the build succeeds. Extract its IPA and sign/install it using your own sideloading tool. The unsigned artifact cannot be installed directly without signing.

## Use

Connect the iPhone and computer to the same Wi-Fi. Open AvoCam, allow camera and local-network access, and tap **Start streaming**. Open the displayed **Wi-Fi stream URL** in VLC or ffplay. The URL is normally `rtsp://<iPhone-IP>:8554/live`, with H.264 video over RTSP/TCP.

Stop streaming to change resolution, orientation, bitrate, microphone capture, or minimal mode. **Dim** lowers screen brightness; double-tap the center to wake it. Camera capture may stop when iOS backgrounds or locks the app; keep it open for unattended streaming.

USB streaming uses the OBS iOS Camera plugin and port 2345. Bonjour advertises `_avocamusb._tcp` on the local network. Wi-Fi RTSP uses port 8554. Microphone audio is optional.

## Changes

The original app converted camera presentation timestamps multiplied by 90,000 directly to UInt32. Values at or above 2^32 caused a Swift trap when a client connected. This fork wraps valid timestamps modulo 2^32 and handles invalid input without a conversion trap. Source arithmetic checks cover rollover and invalid values; on-device reconnection and long-running tests are still required.

## License and attribution

The upstream project identifies its license as GPL-2.0 and describes its basis as obs-ios-camera-source. Original attribution and source history are retained. This fork is not an official upstream release.
