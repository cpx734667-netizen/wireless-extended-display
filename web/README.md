# 网页桥

让浏览器也能收/发 WXESMIRROR 画面，不需要安装安卓 App 或 Mac App。

```
浏览器（Chrome/Edge） ──WebSocket──▶ bridge.py ──TCP 9000──▶ 安卓 / Mac 接收端
        ▲                              │
        └──────── H.264 ───────────────┘
```

## 运行

```bash
cd web
python3 -m pip install websockets
python3 bridge.py
```

默认端口：

| 端口 | 用途 |
|---:|---|
| 8080/TCP | 静态网页（浏览器打开） |
| 8000/TCP | WebSocket（网页内部连接） |
| 9000/TCP | WXESMIRROR（发送端/接收端） |

打开：

```
http://<运行 bridge.py 的电脑 IP>:8080/
```

同一 Wi-Fi 下的手机/电脑都能打开这个地址。

## 两种模式

### 接收投屏（浏览器显示）

1. 打开网页 → **接收投屏**；
2. 桥接地址填 `127.0.0.1`（本机）或运行桥的电脑 IP，端口 8000；
3. 点 **开始接收**；
4. 让 Windows/Mac/安卓发送端把目标 IP 填成运行桥的电脑 IP、端口 **9000**；
5. 网页用 WebCodecs 解码 H.264 到 Canvas。

> 浏览器必须支持 WebCodecs：桌面版 Chrome / Edge 99+。
> iOS Safari、Firefox 旧版不支持。

### 发送投屏（浏览器 → 安卓）

1. 打开网页 → **发送投屏**；
2. 填安卓接收端 IP，端口固定 9000；
3. 选画质、帧率；
4. 点 **选择屏幕并投屏**，在浏览器弹窗里选择要共享的屏幕/窗口；
5. 浏览器用 `MediaRecorder`/WebCodecs 编码 H.264，经 WebSocket 发给桥，桥再按 WXESMIRROR 转发。

> 浏览器共享屏幕需要 HTTPS 或 localhost；局域网 HTTP 下 Chrome 可能拒绝
> `getDisplayMedia`。解决：用 `localhost` 打开，或给 bridge 配 HTTPS 反代。

## 反向控制

网页可以开关「反向控制」：

- 接收模式下：鼠标移动/点击/滚轮/键盘 → 桥 → 发送端（Mac/Windows）执行；
- 坐标按浏览器 Canvas 的 0–1000 相对值发送。

## 依赖

- Python 3.9+
- `websockets`（`pip install websockets`）

## 常见问题

- **网页打不开**：确认 8080 没被占用；防火墙放行；
- **一直“等待发射端连入”**：发送端目标 IP 要填运行 bridge 的电脑 IP，不是安卓 IP；
- **画面黑屏**：浏览器不支持 WebCodecs，或 H.264 档次不支持（用 baseline）；
- **发送模式选不了屏幕**：需要 `localhost` 或 HTTPS；检查浏览器权限。

## License

GPL-3.0。
