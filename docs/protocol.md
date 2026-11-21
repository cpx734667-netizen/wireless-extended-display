# WXESMIRROR 协议

> 无线扩展屏的自有投屏协议。设计目标：**局域网、低延迟、实现简单**。
> 一个 TCP 连接同时承载视频下行和控制上行，不需要额外信令服务器。

- 端口：**TCP 9000**
- 字节序：**大端（network order）**
- 视频：H.264 AnnexB，默认 `baseline`、无 B 帧、1 秒一个 IDR
- 控制：与视频复用同一条连接，type=4/5
- 加密/认证：**无**（仅建议在可信局域网使用）

---

## 1. 连接与握手

发送端（Mac / Windows / 网页桥）主动连接接收端（Android / Mac / 网页桥）的 9000 端口。
连接建立后，发送端立即发送 **16 字节握手**：

```
offset  size  field
0       10    magic = "WXESMIRROR" (ASCII)
10      1     version = 1
11      2     width  (uint16 BE，视频像素宽)
13      2     height (uint16 BE，视频像素高)
15      1     fps    (uint8，1..120)
```

示例（1280×720@30）：

```
57 58 45 53 4D 49 52 52 4F 52   W X E S M I R R O R
01                               version
05 00                            width  = 1280
02 D0                            height = 720
1E                               fps    = 30
```

接收端校验失败（magic 不对、version≠1、宽高为 0）时应直接关闭连接。

---

## 2. 数据包

握手之后，双方都按下面的格式发送数据包：

```
+----------------+----------+-------------------+
| length (4 BE)  | type (1) | payload (length)  |
+----------------+----------+-------------------+
```

- `length`：payload 字节数，不含 5 字节头；最大 **4 MiB**（4194304）。
- `type`：见下表。
- TCP 是字节流，读取时必须循环读满，不能假设一次 `recv` 就是一个包。

| type | 名称 | 方向 | payload |
|---:|---|---|---|
| 1 | CONFIG | 发送端 → 接收端 | AnnexB 的 SPS/PPS（可含多个 NAL） |
| 2 | FRAME | 发送端 → 接收端 | 一个访问单元（AnnexB，通常一个 VCL NAL） |
| 3 | HEARTBEAT | 发送端 → 接收端 | 空 |
| 4 | MOUSE | 双向 | 7 字节，见 3.1 |
| 5 | KEY | 双向 | 5 字节，见 3.2 |

### 视频包约定

- 所有 NAL 使用 **AnnexB** 起始码：`00 00 00 01` 或 `00 00 01`。
- 发送端在第一个 IDR 前发送 `CONFIG`；之后每次 IDR 前可重复发送，接收端应忽略重复的相同配置。
- 建议每个 IDR 单独发一个 `FRAME`，P 帧每帧一个 `FRAME`。
- 不应丢帧（除非接收端主动丢弃）：H.264 的 P 帧依赖前一帧，丢一帧会让解码器花屏直到下一个 IDR。
- 屏幕静止时，发送端应至少每 1 秒重发最后一帧或发送心跳，避免接收端看门狗超时。
- 接收端超过 **20 秒**没有收到任何数据，应主动关闭连接（本仓库实现如此）。

### 心跳

发送端每 **5 秒**发送一个 `type=3, length=0` 的包。接收端不需要回复。
心跳只用于保活/看门狗，不参与时钟同步。

---

## 3. 控制消息

控制消息与视频共用连接，方向可以是：

- **接收端 → 发送端**：接收端用户点击/拖动画面，控制发送端电脑（Mac/Windows）；
- **发送端 → 接收端**：发送端用户操作鼠标/键盘，控制安卓手机（需要安卓无障碍服务）。

### 3.1 MOUSE（type=4）

payload 固定 7 字节：

```
offset size field
0      1    action: 0=move, 1=down, 2=up, 3=wheel
1      2    x: 0..1000（相对发送端屏幕宽度的千分比）
3      2    y: 0..1000（相对发送端屏幕高度的千分比）
5      2    wheel: int16 BE，正=上滚，负=下滚（action=3 时有效）
```

Python 打包/解包：

```python
import struct
payload = struct.pack(">BHHh", action, x, y, wheel)
action, x, y, wheel = struct.unpack(">BHHh", payload)
```

坐标一律用 **0–1000 相对值**，由发送端按自己的屏幕尺寸换算成像素。
这样接收端不需要知道发送端的实际分辨率。

### 3.2 KEY（type=5）

payload 固定 5 字节：

```
offset size field
0      1    action: 0=down, 1=up
1      4    androidKeyCode: Android KeyEvent.KEYCODE_*（int32 BE）
```

例如：

| 按键 | Android keyCode | 十六进制 |
|---|---:|---|
| A | 29 | `00 00 00 1D` |
| 1 | 8 | `00 00 00 08` |
| Enter | 66 | `00 00 00 42` |
| Backspace | 67 | `00 00 00 43` |
| Space | 62 | `00 00 00 3E` |
| Esc | 111 | `00 00 00 6F` |
| 方向键上/下/左/右 | 19/20/21/22 | `13/14/15/16` |
| F1..F12 | 131..142 | `83..8E` |

完整映射见：

- macOS：`mac/src/Ctrl.swift`
- Windows：`windows/ctrl_send_win.py`
- Android：`android/reference/RemoteCtrlService.kt`

> 文字输入：安卓端把 keyCode 映射成字符后，通过无障碍 `ACTION_SET_TEXT` 追加到焦点输入框；
> 回车映射为点击确认，退格删除最后一个字符。复杂输入法/自绘输入框可能不生效。

---

## 4. 最小实现示例

### 4.1 发送端（Python 伪代码）

```python
import socket, struct

MAGIC = b"WXESMIRROR"
s = socket.create_connection((ip, 9000), timeout=5)
s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
s.sendall(MAGIC + bytes([1]) + struct.pack(">HH", 1280, 720) + bytes([30]))

def send_packet(typ, payload=b""):
    s.sendall(struct.pack(">I", len(payload)) + bytes([typ]) + payload)

send_packet(1, sps_pps_annexb)   # CONFIG
send_packet(2, idr_annexb)       # FRAME
send_packet(3)                   # HEARTBEAT
```

### 4.2 接收端（Python 伪代码）

```python
import socket, struct

conn, addr = server.accept()
hs = conn.recv(16)
assert hs[:10] == b"WXESMIRROR"
ver = hs[10]
w, h = struct.unpack(">HH", hs[11:15])
fps = hs[15]

def recvn(n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk: raise ConnectionError
        buf += chunk
    return buf

while True:
    length, typ = struct.unpack(">IB", recvn(5))
    payload = recvn(length)
    if typ in (1, 2):
        feed_decoder(payload)   # AnnexB -> MediaCodec / VideoToolbox
```

### 4.3 控制消息

```python
# 接收端告诉发送端：点击 (500, 900)
send_packet(4, struct.pack(">BHHh", 1, 500, 900, 0))  # down
send_packet(4, struct.pack(">BHHh", 2, 500, 900, 0))  # up

# 接收端告诉发送端：按下 A
send_packet(5, struct.pack(">BI", 0, 29))
send_packet(5, struct.pack(">BI", 1, 29))
```

---

## 5. 时序与延迟

一条典型的 Mac → Android 链路：

```
macOS 屏幕
  │  ffmpeg avfoundation 采集（30/60fps，屏幕有变化才出帧）
  ▼
libx264 ultrafast / baseline / bf=0 / 1s GOP
  │  AnnexB over TCP :9000（TCP_NODELAY）
  ▼
Android MediaCodec 硬解 → SurfaceView
```

影响延迟的主要因素：

| 环节 | 典型耗时 | 说明 |
|---|---:|---|
| 采集 + 编码 | 15–40 ms | `ultrafast` + 硬件编码器更快 |
| 网络 | 2–20 ms | 5 GHz Wi-Fi / 有线；2.4 GHz 与弱信号明显更差 |
| 解码 | 5–25 ms | 旗舰机硬解更快 |
| 显示 | 8–33 ms | 60Hz 屏幕一帧约 16.7ms |
| **合计** | **约 50–120 ms** | 不含应用层缓冲 |

降低延迟的建议：

- Mac 与安卓同一 5 GHz Wi-Fi，或安卓用 USB 网卡/有线；
- 关闭“省电模式”“智能分辨率”；
- 发送端 30fps / 4–8 Mbps 通常比 60fps / 20 Mbps 更稳；
- 不要用 2.4 GHz 拥塞信道；不要经过路由器 NAT 环回；
- 安卓端关闭其他占用硬件解码器的 App（相机、 video call）。

---

## 6. 安全说明

- 协议**没有加密、没有认证**，同一局域网内任何人都能连接 9000 端口并发送画面/控制消息；
- 仅建议在家庭/办公室可信网络使用；
- 不要把 9000 端口映射到公网；
- 公共场所建议关闭接收端，或使用系统防火墙限制来源 IP；
- 反向控制依赖安卓无障碍权限，授权前请确认连接对象可信。

后续版本可以考虑：配对码、TLS、基于公钥的会话密钥。欢迎提交 PR。
