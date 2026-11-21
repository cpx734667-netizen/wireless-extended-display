# Windows 发送端

Python + tkinter + ffmpeg 的轻量发送端，协议与 macOS/Android 完全一致
（[`docs/protocol.md`](../docs/protocol.md)）。适合：

- 临时把 Windows 屏幕投到安卓；
- 不装 Mac App 的情况下联调协议；
- 需要 Windows 端反向控制安卓时。

## 文件

| 文件 | 作用 |
|---|---|
| `sender_win.py` | 主程序：gdigrab 抓屏 + libx264 + TCP 发送 + GUI |
| `ctrl_send_win.py` | 低级鼠标/键盘钩子 → Android keyCode 控制消息 |
| `../tools/fake_receiver_ctrl.py` | 假接收端：验证安卓发送端的控制通道 |

## 依赖

- Windows 10/11
- Python 3.10+
- ffmpeg：脚本用 `imageio-ffmpeg` 自带二进制，无需单独安装
- 反向控制需要 `pyautogui`（仅被控端使用）

```powershell
pip install pyautogui pillow imageio-ffmpeg
```

> tkinter 是 Python 标准库的一部分；如果安装的是 Microsoft Store 版 Python，
> 可能需要重新安装官方 python.org 版本以包含 tkinter。

## 使用

```powershell
cd windows
python sender_win.py
```

1. **目标 IP**：安卓「扩展屏」页显示的 IP；
2. **端口**：9000；
3. **帧率 / 码率**：默认 15fps / 4000kbps；
4. 点 **开始投屏**；
5. 需要时勾选 **反向控制**（接收端操作 → 控制 Windows 本机）。

命令行模式（无 GUI，适合脚本/联调）：

```powershell
python sender_win.py --ip 192.168.3.75 --port 9000 --fps 15 --bitrate 4000 --frames 30
```

## 原理

```
gdigrab 抓屏
  → ffmpeg libx264（ultrafast, baseline, bf=0, 1s GOP）
    → stdout AnnexB
      → 切 NAL：SPS/PPS 缓存，IDR 前发 CONFIG，P/VCL 发 FRAME
        → TCP :9000
```

反向控制（Windows 作为被控端）：

```
接收端发来 type=4/5
  → sender_win.py 的 control_buf
    → pyautogui 移动/点击/滚轮/按键
```

Windows 作为控制端（可选）：

```
WH_MOUSE_LL / WH_KEYBOARD_LL
  → ctrl_send_win.py 队列（鼠标 move 节流）
    → 同一条 TCP 发 type=4/5
      → 安卓 RemoteCtrlService 执行
```

## 防火墙

首次运行 Windows 会弹出防火墙提示，勾选 **专用网络**。
如果安卓连不上：

```powershell
New-NetFirewallRule -DisplayName "WXES Mirror TCP 9000" `
  -Direction Inbound -Protocol TCP -LocalPort 9000 -Action Allow -Profile Private
```

## 常见问题

- **ffmpeg 启动失败**：确认 `pip install imageio-ffmpeg` 成功；
  或设置 `IMAGEIO_FFMPEG_EXE` 指向 ffmpeg.exe。
- **画面黑屏/花屏**：把分辨率降到 1280×720、帧率 15、码率 4000；
  Windows 的 gdigrab 在部分缩放比例（125%/150%）下会抓不到正确尺寸。
- **反向控制不生效**：需要管理员权限的窗口（UAC）无法被普通进程注入；
  以管理员身份运行 `sender_win.py` 可解决。
- **多显示器**：gdigrab 默认抓主屏；需要抓副屏时改 `-i desktop` 为
  `-i title=...` 或使用 `-offset_x/-offset_y/-video_size`。

## License

GPL-3.0。`ctrl_send_win.py` 只依赖 Python 标准库 + ctypes。
