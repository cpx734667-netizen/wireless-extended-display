# 架构

「无线扩展屏」不是单一 App，而是一组可以互相组合的端：

```
┌──────────────────────┐        AirPlay / RAOP         ┌─────────────────────────┐
│ iPhone / iPad / Mac  │ ───────────────────────────▶ │ Android：AirPlay 接收   │
│ 系统「屏幕镜像」      │        H.264 / AAC           │ UxPlay → VideoRenderer  │
└──────────────────────┘                              │        → SurfaceView    │
                                                      │                         │
┌──────────────────────┐        WXESMIRROR           │ + WXESMIRROR 接收       │
│ Mac / Windows / Web  │ ────── TCP :9000 ──────────▶ │ MirrorReceiver          │
│ 发送端               │        H.264 AnnexB          │        → VideoRenderer  │
└──────────────────────┘                              └─────────────────────────┘
          ▲                                                     │
          │              type=4/5 控制消息（同一 TCP）            │
          └─────────────────────────────────────────────────────┘
```

## 1. 端与职责

| 端 | 目录 | 语言/栈 | 角色 |
|---|---|---|---|
| macOS App | `mac/` | Swift + AppKit + VideoToolbox + ffmpeg | 接收 / 发送 / 反控 / 被控 |
| Android App | `android/` | Kotlin + Compose + MediaCodec + UxPlay | AirPlay 接收 + WXES 接收/发送 + 无障碍反控 |
| Windows 发送端 | `windows/` | Python + tkinter + ffmpeg + ctypes | 发送 / 被控 |
| 网页桥 | `web/` | Python asyncio + WebSocket + WebCodecs | 浏览器接收 / 发送 |
| 协议测试 | `tools/` | Python | 假接收端，联调控制消息 |

## 2. macOS App

### 2.1 文件

| 文件 | 作用 |
|---|---|
| `src/main.swift` | 入口；CLI 自测模式 + GUI 启动 |
| `src/Receiver.swift` | TCP 9000 监听、握手、拆帧、反向控制发送 |
| `src/Sender.swift` | ffmpeg 截屏 + libx264 编码 + 发送 + 被控读取 |
| `src/Decoder.swift` | VideoToolbox H.264 解码 → CVPixelBuffer |
| `src/H264.swift` | AnnexB 起始码/NAL 工具、帧率统计、本机 IP |
| `src/Ctrl.swift` | CGEventTap 捕获本机输入 / CGEvent 注入被控 |
| `src/UI.swift` | AppKit 界面：接收页 / 发送页 / 全屏 / 状态 |

### 2.2 接收链路

```
TCP :9000
  → ReceiverService.readLoop
      → 握手（16B）
      → CONFIG  → H264Decoder.applyConfig（SPS/PPS → CMFormatDescription）
      → FRAME   → H264Decoder.decode（AnnexB → AVCC → VTDecompressionSession）
                    → CVPixelBuffer
                      → CIContext → CGImage
                        → CALayer.contents（VideoDisplayView）
```

- 解码在 `DispatchQueue(label: "com.wxes.decode")` 串行队列；
- UI 更新回主线程；
- 只保留一路发送端，新连接会替换旧连接；
- 每 1 秒统计一次实时 fps。

### 2.3 发送链路

```
ScreenCapture（ffmpeg avfoundation "Capture screen N"）
  → libx264 baseline / ultrafast / bf=0 / 1s GOP
    → stdout AnnexB
      → Sender.readLoop 切 NAL
        → SPS/PPS 缓存
        → IDR：CONFIG + FRAME
        → P 帧：FRAME
          → TCP :9000
```

- 按设备名 `Capture screen N` 采集，避免 iPhone 连续互通相机占用数字索引；
- 屏幕静止时 ffmpeg 可能不出帧，`resendLoop` 每秒重发最后一帧；
- `-tune zerolatency` 在 macOS 27 上会被 VideoToolbox 拒绝，所以用 `-bf 0` + `ultrafast`。

### 2.4 反向控制

**Mac 控制对方：**

```
CGEventTap（鼠标/键盘）
  → CtrlSender 队列（move 30ms 节流）
    → ReceiverService.sendControl(type=4/5)
      → 对端执行
```

**对方控制 Mac：**

```
接收端发来 type=4/5
  → Sender.ctrlReadLoop
    → CtrlExecutor.handle
      → CGWarpMouseCursorPosition / CGEvent.post
```

需要「辅助功能」权限；坐标按主屏实际尺寸换算。

## 3. Android App

### 3.1 AirPlay 链路

```
iPhone → mDNS(_airplay._tcp / _raop._tcp)
  → UxPlay（C/JNI）：FairPlay、RAOP、HLS
    → H.264 NAL / AAC
      → VideoRenderer（MediaCodec，Surface → VideoPipeline）
        → SurfaceView
```

- 基于 [jqssun/android-airplay-server](https://github.com/jqssun/android-airplay-server)（GPL-3.0）；
- 支持 H.264/H.265、AAC-ELD/AAC-LC/ALAC、HLS 视频、AirPlay PIN；
- 具体上游能力见 `android/README.md`。

### 3.2 WXES 链路

```
TCP :9000
  → MirrorReceiver.acceptLoop
      → handleClient：握手 → VideoRenderer.setResolution/selectDecoders/startSession
      → type=1/2 → VideoRenderer.feedFrame（MediaCodec 硬解）
      → type=4/5 → 反向控制消息（本端可执行）
  ← sendMouse/sendKey：触摸 → type=4/5 → 发送端
```

`MirrorActivity` 用经典 `SurfaceView` 承载画面，避免和上游 Compose 导航耦合。
主页右下角的「扩展屏」按钮进入。

### 3.3 无障碍反控

`RemoteCtrlService`：

- 点击/滑动：`dispatchGesture()`；
- 滚屏：`ACTION_SCROLL_FORWARD/BACKWARD`；
- 文字：对焦点 `ACTION_SET_TEXT` 追加/删除；
- 权限：设置 → 无障碍 → 无线扩展屏。

## 4. Windows 发送端

`sender_win.py`：

- `gdigrab` 抓屏 → `libx264` → AnnexB；
- `tkinter` 界面；
- `ctrl_send_win.py` 用 `WH_MOUSE_LL` / `WH_KEYBOARD_LL` 低级钩子捕获输入，
  映射成 Android keyCode，走同一条 TCP 连接。

## 5. 网页桥

`web/bridge.py`：

- `:9000` 接收 WXES 流 → WebSocket 广播；
- 浏览器 `WebCodecs` 解码 H.264 → Canvas；
- 浏览器也可以把摄像头/屏幕编码后发回桥，由桥转发到安卓。

> 需要桌面版 Chrome/Edge（WebCodecs）；iOS Safari 不支持。

## 6. 端口与权限

| 端口 | 用途 |
|---:|---|
| 9000/TCP | WXESMIRROR 视频 + 控制 |
| 8000/TCP | 网页桥 HTTP + WebSocket |
| 动态端口 | AirPlay（由 UxPlay / mDNS 协商） |

| 权限 | 端 | 用途 |
|---|---|---|
| 屏幕录制 | macOS | ffmpeg avfoundation 抓屏 |
| 辅助功能 | macOS | 反向控制注入 |
| 本地网络 | iOS/macOS | AirPlay 发现与连接 |
| 无障碍 | Android | 反向控制 |
| 录屏 | Android | 安卓作为发送端（MediaProjection） |
| 通知 | Android 13+ | 前台服务 |

## 7. 设计取舍

- **为什么不用 WebRTC？** 局域网内 TCP + H.264 足够简单，不需要 STUN/TURN/ICE；
  代价是没有丢包重传/拥塞控制，弱网下不如 WebRTC。
- **为什么用 AnnexB 而不是 AVCC？** ffmpeg 的 `-f h264` 原生输出 AnnexB，
  发送端零转封装；接收端自己做起始码切分。
- **为什么控制消息复用视频连接？** 少一个端口、少一次握手；控制包很小，
  和视频共用 TCP 的队头阻塞影响可接受。
- **为什么 Mac 端用 ffmpeg 而不是 ScreenCaptureKit？** 兼容 macOS 13+，
  且能直接拿到 H.264；代价是多了 38MB 的 ffmpeg 依赖。
- **为什么 Android 端不自己写解码器？** 复用上游 `VideoRenderer` 的
  MediaCodec 选择、Surface 管线、统计和错误恢复，代码量小很多。

## 8. 后续可做

- 协议加密 / 配对码；
- 动态码率（根据 RTT/丢帧调整）；
- Android 端接收音频（目前 WXES 只传视频）；
- macOS 虚拟显示器（真正的「扩展」而不是镜像某块屏）；
- iOS 发送端（ReplayKit）。
