# 使用指南

> 目标：5 分钟内把 Mac 或 iPhone 投到安卓设备；需要反向控制时再多花 1 分钟开权限。

---

## 0. 准备

- 安卓设备：Android 7.0+（推荐 10+），和发送端在**同一个 Wi-Fi / 局域网**；
- iPhone / iPad：iOS 12+（AirPlay 屏幕镜像）；
- Mac：macOS 13+（Apple Silicon 或 Intel 均可，仓库构建脚本在 Apple Silicon 上验证）；
- 路由器：关闭「AP 隔离 / 客户端隔离」，否则设备互相发现不了；
- 端口：TCP **9000**（WXESMIRROR）；AirPlay 使用系统协商的动态端口。

---

## 1. 安装安卓端

1. 从 [Releases](https://github.com/cpx734667-netizen/wireless-extended-display/releases/latest)
   下载 `无线扩展屏-v1.6.apk`；
2. 用文件管理器打开安装；首次会提示「允许安装未知来源应用」；
3. 打开 App，允许**通知**（前台服务需要）；
4. 记住主页显示的本机 IP，或进入「扩展屏」页查看 `本机 IP: 192.168.x.x`。

> 如果系统提示「应用未安装 / 签名不一致」，先卸载旧版本再装。
> 自己从源码构建的 APK 签名不同，不能覆盖安装官方包。

---

## 2. iPhone / iPad → 安卓（AirPlay）

这是最省事的方式，不需要在 iPhone 上装任何 App。

1. 安卓端打开「无线扩展屏」，停留在主页（AirPlay 接收服务已自动启动）；
2. iPhone 解锁，连同一个 Wi-Fi；
3. 打开**控制中心**：
   - 全面屏 iPhone：右上角向下滑；
   - 带 Home 键：底部向上滑；
4. 点 **屏幕镜像**（两个矩形叠在一起的图标）；
5. 在列表里选择 **无线扩展屏**（或类似的接收器名称，取决于 App 设置）；
6. 第一次连接可能要求在安卓端输入 **PIN 码**（如果开启了 PIN 认证）；
7. 连接成功后，iPhone 画面就出现在安卓上。

停止：再次打开控制中心 → 屏幕镜像 → **停止镜像**。

> **DRM 内容**（Apple TV、Netflix 等受保护视频）会黑屏，这是 AirPlay 协议限制，不是 App 的问题。
> 部分 App 禁止录屏/镜像，也会黑屏。

### 声音

AirPlay 会把音频一起送到安卓。安卓端音量键调节媒体音量。
如果只想投画面，在 iPhone 控制中心把音量拉到 0 不会静音 AirPlay 音频，
需要在安卓端调音量或使用 App 内的音频开关（如果版本提供）。

---

## 3. Mac → 安卓（WXESMIRROR，低延迟）

### 3.1 安装 Mac 端

**方式 A：直接下载**

1. 从 [Releases](https://github.com/cpx734667-netizen/wireless-extended-display/releases/latest)
   下载 `Wireless-Extended-Display-1.1.0-macOS.dmg`；
2. 双击打开，把「无线扩展屏」拖到「应用程序」；
3. 首次打开：右键 App → **打开**（ad-hoc 签名，未公证）；
4. 如果仍被拦截：系统设置 → 隐私与安全性 → 仍要打开。

**方式 B：从源码构建**

见 [`../mac/README.md`](../mac/README.md)。

### 3.2 第一次授权

| 权限 | 什么时候需要 | 在哪里开 |
|---|---|---|
| 屏幕录制 | Mac 作为**发送端** | 系统设置 → 隐私与安全性 → 屏幕录制 |
| 辅助功能 | Mac 作为**被控端**，或 Mac 作为控制端 | 系统设置 → 隐私与安全性 → 辅助功能 |

macOS 不会主动弹出「屏幕录制」授权框（发送端第一次点开始时会触发系统请求）。
授权后**完全退出 App 再重开**。

### 3.3 发送

1. 安卓端打开「扩展屏」接收页，确认状态是「正在监听 TCP 9000」；
2. Mac 打开 App，切到 **发送投屏**；
3. 目标设备 IP：填安卓屏幕上显示的 IP（如 `192.168.3.75`）；
4. 端口：`9000`；
5. 投屏屏幕：主显示器 / 显示器 2 / 虚拟扩展屏；
6. 分辨率：推荐 **1280×720** 或 **原始分辨率**；
7. 帧率：**15 / 30 fps**；追求流畅选 30，追求低延迟选 15；
8. 码率：**4000–8000 kbps**；画面复杂/文字多可调高；
9. 点 **开始投屏**。

Mac 画面会出现在安卓上。点 **停止** 结束。

### 3.4 把安卓当「第二块屏」

App 发送的是 Mac 上**某一块已存在的屏幕**。要获得真正的扩展桌面：

1. 在 Mac 上创建一个虚拟显示器（例如 BetterDisplay / Displays 的虚拟屏功能）；
2. 在 App 的「投屏屏幕」里选择这块虚拟屏；
3. 安卓端显示的就是扩展桌面，而不是主屏镜像。

> 不创建虚拟屏时，选择主显示器就是**镜像**，不是扩展。

### 3.5 反向控制（Mac 控制安卓）

1. 安卓端：设置 → 无障碍 → **无线扩展屏** → 开启；
2. Mac 端：接收页 / 发送页的「反向控制」开关打开（首次会请求辅助功能权限）；
3. 在安卓画面上点击、拖动，Mac 会收到 type=4 鼠标消息；
4. Mac 的键盘输入会映射成 Android keyCode，由安卓无障碍服务执行。

支持：单击、拖动、滚轮（Mac 端滚轮）、常用字母/数字/回车/退格/方向键。
复杂中文输入法、游戏手柄不在支持范围内。

### 3.6 被控制（安卓控制 Mac）

1. Mac 端：发送投屏 → 开始投屏后，打开 **被控制** 开关；
2. 首次会请求辅助功能权限，授权后**重启 App**；
3. 安卓端：在「扩展屏」画面上点击/拖动；
4. Mac 的鼠标会被移动/点击；键盘由安卓端按字符映射。

> 被控端坐标以 Mac 主屏为基准。多显示器时，控制会落在主屏坐标系。

---

## 4. Windows → 安卓

Windows 端是 Python 脚本，适合临时使用/联调：

```powershell
# Windows 10/11，安装 Python 3.10+
pip install pyautogui pillow imageio-ffmpeg

cd windows
python sender_win.py
```

1. 目标 IP 填安卓的 IP，端口 9000；
2. 选帧率/码率，点开始；
3. 需要反向控制时，保持「反向控制」勾选；Windows 端会用低级钩子捕获鼠标键盘。

> `sender_win.py` 使用 `gdigrab` 抓屏；Windows 7 可能不支持。
> 首次运行 Windows 防火墙会询问，允许专用网络即可。

Mac 上也可以用 Python 发送端（不依赖 App）：

```bash
cd mac/scripts
python3 sender_mac.py --ip <安卓IP> --fps 15 --bitrate 4000
# 依赖：pip install imageio-ffmpeg pillow pyautogui
```

---

## 5. 浏览器接收 / 发送

适合没有装 App 的电脑临时看画面。

```bash
cd web
python3 -m pip install websockets
python3 bridge.py
# 浏览器打开 http://<电脑IP>:8000/
```

- **接收投屏**：Windows/Mac/安卓发送端把目标 IP 填成运行 `bridge.py` 的电脑 IP、端口 9000；
- **发送投屏**：浏览器选择屏幕 → 编码 → 桥转发到安卓 IP:9000；
- 需要桌面版 Chrome / Edge 99+（WebCodecs）；Safari 不支持。

---

## 6. 网络与性能建议

| 场景 | 建议 |
|---|---|
| 同一房间 | 5 GHz Wi-Fi，路由器 802.11ac/ax |
| 画面卡顿 | 降到 15fps / 4Mbps；关闭其他大流量下载 |
| 延迟高 | 用 5 GHz；安卓关省电模式；Mac 插网线（如果安卓也有线） |
| 花屏 | 降低分辨率/码率；换 H.264 baseline；重启接收端 |
| 找不到 AirPlay 设备 | 检查 AP 隔离、mDNS、防火墙；两台设备是否同一子网 |
| 9000 端口被占用 | `lsof -i :9000`（macOS/Linux）或 `netstat -ano | findstr 9000`（Windows） |

### 延迟参考

在 5 GHz Wi-Fi、30fps/6Mbps、旗舰安卓机条件下，端到端约 **60–120 ms**。
2.4 GHz、弱信号、低端解码器可能到 200 ms 以上。
AirPlay 链路通常比 WXESMIRROR 多 50–150 ms（AirPlay 自身有缓冲）。

---

## 7. 常见问题

### Q: 安卓上 AirPlay 设备名不出现？

- 确认 iPhone 和安卓在同一子网（不是访客网络）；
- 路由器关闭「AP 隔离」「客户端隔离」「 multicast 优化」；
- 关闭安卓 VPN / 代理；
- 重启 App；必要时重启路由器；
- 某些路由器会屏蔽 mDNS（5353/UDP），换一个路由器试试。

### Q: 连接成功但黑屏？

- iPhone：DRM/受保护内容无法镜像；
- Mac：检查「屏幕录制」权限，完全退出 App 重开；
- 安卓：换一个解码器/降低分辨率（部分设备 baseline 硬解异常）；
- 看 Android logcat：`adb logcat -s MirrorReceiver VideoRenderer`。

### Q: 反向控制没反应？

- 安卓：设置 → 无障碍 → 无线扩展屏 → 已开启；
- Mac：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 App，重启 App；
- 确认控制开关是「开」；
- 部分 App 的输入框是自绘的，无障碍 `ACTION_SET_TEXT` 不生效。

### Q: Mac 提示「无法验证开发者」？

- 右键 App → 打开；
- 或 `xattr -dr com.apple.quarantine /Applications/无线扩展屏.app`；
- 这是 ad-hoc 签名，不是病毒；介意的话从源码构建。

### Q: 安装 APK 提示「解析包错误」？

- 确认下载完整（对比 Releases 里的 SHA256）；
- Android 版本低于 7.0 不支持；
- 部分定制系统需要关闭「纯净模式」。

### Q: 可以跨公网吗？

协议本身没有加密/认证，**不建议**直接把 9000 端口映射到公网。
需要远程时，用 Tailscale / ZeroTier 等组网，或走 SSH 隧道。

---

## 8. 卸载 / 清理

- 安卓：长按图标 → 卸载；无障碍服务会随 App 移除；
- Mac：退出 App，把「无线扩展屏」从应用程序拖到废纸篓；
- 权限残留：系统设置 → 隐私与安全性 → 屏幕录制/辅助功能，点 `−` 移除；
- 网页桥：`Ctrl+C` 停止 `bridge.py` 即可。
