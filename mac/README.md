# macOS 端

一个原生 AppKit 小工具，四合一：

1. **接收投屏**：监听 TCP 9000，显示 Android / Windows / 另一台 Mac 发来的画面；
2. **发送投屏**：用 ffmpeg 抓屏 + libx264 编码，投到安卓；
3. **反向控制**：本机鼠标/键盘 → 控制对方（需要辅助功能权限）；
4. **被控制**：对方控制本机鼠标/键盘。

## 构建

### 依赖

- macOS 13+（开发验证环境：macOS 27 / Apple Silicon）
- Xcode Command Line Tools：`xcode-select --install`
- ffmpeg：`brew install ffmpeg`（构建时会把 ffmpeg 及依赖 dylib 打包进 App）

### 一键构建

```bash
cd mac
./build.sh
# 产物：mac/build/无线扩展屏.app
open "build/无线扩展屏.app"
```

`build.sh` 做五件事：

1. `swiftc -O` 编译 `src/*.swift`；
2. 调用 `scripts/package_ffmpeg.sh`，把 Homebrew ffmpeg + 27 个 dylib 复制进
   `Contents/Resources` / `Contents/Frameworks`，并用 `install_name_tool` 重链为相对路径；
3. 从 `assets/icon_1024.png` 生成 `.icns`；
4. 写 `Info.plist`（bundle id `com.wxes.mirror`，最低 macOS 13）；
5. ad-hoc 签名（`codesign --sign -`）。

> 换 Intel Mac 时，`package_ffmpeg.sh` 会自动使用 `command -v ffmpeg` 的结果，
> 并收集 `/usr/local` 下的 dylib；但 Intel 未实测。

### 手动编译（只改代码时更快）

```bash
cd mac/src
swiftc -O -swift-version 5 \
  main.swift H264.swift Decoder.swift Receiver.swift Sender.swift Ctrl.swift UI.swift \
  -o /tmp/WXES
```

需要测试画面时，可以直接用 CLI（不需要 GUI）：

```bash
# 本机自测：发 testsrc2 到 127.0.0.1:9000
/tmp/WXES --send-test-src 127.0.0.1 9000 15 4000 1280 720 10

# 发一个 H.264 文件（循环）
/tmp/WXES --send-file-test 127.0.0.1 9000 /tmp/test.h264 1280 720 30 10

# 用 ffmpeg 真实抓屏
/tmp/WXES --send-test 192.168.3.75 9000 15 4000 1280 720 "Capture screen 0" 10
```

## 权限

| 权限 | 用途 | 触发方式 |
|---|---|---|
| 屏幕录制 | 发送端抓屏 | 第一次点「开始投屏」；或点「检查屏幕录制权限」 |
| 辅助功能 | 被控端注入鼠标/键盘；控制端 CGEventTap | 开启「被控制」/「反向控制」时请求 |

授权后**完全退出 App 再重开**。ad-hoc 签名每次重新构建都可能重置权限。

## 界面说明

### 接收投屏

- 自动监听 `TCP 9000`，显示本机 IP；
- 显示模式：原始比例 / 拉伸填充 / 自定义比例；
- 全屏：`view.window?.toggleFullScreen`；
- 反向控制：用本机鼠标/键盘控制发送端（需要辅助功能）；
- 底部显示实时 fps / 源分辨率。

### 发送投屏

| 控件 | 说明 |
|---|---|
| 目标设备 IP | 安卓「扩展屏」页显示的 IP |
| 端口 | 默认 9000 |
| 投屏屏幕 | `NSScreen.screens` 列表，可选主屏/副屏/虚拟屏 |
| 分辨率 | 原始 / 1280×720 / 640×360 / 自定义 |
| 帧率 | 5 / 10 / 15 / 24 / 30 / 60 |
| 码率 | 500–20000 kbps |
| 开始/停止 | 启动/结束 ffmpeg |
| 被控制 | 允许接收端控制本机（需要辅助功能） |

## 代码结构

```
mac/
├── build.sh                 构建入口
├── assets/icon_1024.png     图标源图
├── scripts/
│   ├── package_ffmpeg.sh    封装 ffmpeg + dylib
│   ├── gen_icon.swift       图标生成脚本（原始素材）
│   └── sender_mac.py        Python 发送端（不依赖 App，联调用）
└── src/
    ├── main.swift           入口 / CLI / NSApplication
    ├── H264.swift           AnnexB、NAL、fps、本机 IP
    ├── Receiver.swift       TCP 9000 接收 + 控制发送
    ├── Sender.swift         ffmpeg 发送 + 被控读取
    ├── Decoder.swift        VideoToolbox 解码 + 调试日志
    ├── Ctrl.swift           键码映射、CGEventTap、CGEvent 注入
    └── UI.swift             AppKit 界面
```

## 已知问题

- `-tune zerolatency` 产出的流会被 macOS VideoToolbox 拒绝（`-12909`），
  所以用 `-bf 0` + `ultrafast` + `baseline`；
- ffmpeg 屏幕采集是内容驱动的，静止画面可能不出帧；`resendLoop` 每秒重发最后一帧；
- 数字设备索引会被 iPhone 连续互通相机占用，所以按 `Capture screen N` 名称采集；
- 多显示器被控时，坐标以主屏为基准；
- 没有音频回传（WXES 只传视频）。

## 打包 DMG（可选）

```bash
cd mac
./build.sh
hdiutil create -volname "无线扩展屏" -srcfolder "build/无线扩展屏.app" \
  -ov -format UDZO "build/无线扩展屏-1.1.0.dmg"
```

## License

GPL-3.0。macOS 端原始代码版权归项目作者；ffmpeg 及其依赖按其各自许可证分发。
