# -*- coding: utf-8 -*-
"""
无线扩展屏 - 中继桥接服务（网页端 ↔ 自有协议 9000）
作用：
  1) 接收模式：本机/局域网设备可把 TCP 9000 的「整屏镜像」流连到本桥，
     桥把 H.264 帧通过 WebSocket 转发给浏览器网页解码显示。
     —— 这样 Windows 发射端 / 安卓发射端不需要任何改动，就能把画面投到浏览器。
  2) 发送模式：浏览器（网页端发送按钮）通过 WebSocket 把 H.264 帧发给桥，
     桥按自有协议转发到安卓接收端（目标 IP 由网页指定）。
用法：
  python bridge.py [--tcp 9000] [--ws 8000] [--host 0.0.0.0]
网页地址：http://<本机IP>:8000/（桥同时托管网页静态文件）
"""
import argparse
import asyncio
import os
import socket
import struct
import sys
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# PyInstaller --windowed 打包后 sys.stdout/stderr 为 None，
# http.server 内部任何日志写入都会抛 AttributeError 导致连接被关闭。
# 统一重定向到空设备，保证桥 EXE 的 8080 静态页与 8000 WebSocket 都稳定工作。
if sys.stdout is None:
    sys.stdout = open(os.devnull, "w", encoding="utf-8")
if sys.stderr is None:
    sys.stderr = open(os.devnull, "w", encoding="utf-8")

import websockets

MAGIC = b"WXESMIRROR"
TYPE_CONFIG = 1
TYPE_FRAME = 2
TYPE_MOUSE = 4   # 反向控制：鼠标（网页 -> 发射端）
TYPE_KEY = 5     # 反向控制：键盘（网页 -> 发射端）

# WS 客户端集合（接收模式的观看者）
ws_clients = set()
# 当前连接的发射端 writer（反向控制的目标）
control_writer = None
# 发送模式：网页 -> 安卓 的 TCP 客户端（每网页一条）
sender_socks = {}  # id(ws) -> socket


def parse_handshake(data):
    """解析 16 字节握手，返回 (w,h,fps) 或 None"""
    if len(data) < 16 or data[:10] != MAGIC:
        return None
    ver = data[10]
    w = (data[11] << 8) | data[12]
    h = (data[13] << 8) | data[14]
    fps = data[15]
    return (w, h, fps) if (ver == 1 and w > 0 and h > 0) else None


async def handle_tcp_client(reader, writer):
    """接收模式：TCP 9000 收整屏镜像流 -> 广播给网页 WS"""
    try:
        hs = await reader.readexactly(16)
        info = parse_handshake(hs)
        if not info:
            writer.close()
            return
        print(f"[TCP] 发射端已连接，握手 {info[0]}x{info[1]}@{info[2]}")
        global control_writer
        control_writer = writer
        while True:
            head = await reader.readexactly(5)
            (length,) = struct.unpack(">I", head[:4])
            typ = head[4]
            if length < 0 or length > 4 * 1024 * 1024:
                break
            payload = await reader.readexactly(length)
            # 原样转发帧（type 字节 + payload）
            frame = bytes([typ]) + payload
            if ws_clients:
                await asyncio.gather(
                    *(c.send(frame) for c in list(ws_clients)),
                    return_exceptions=True,
                )
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    finally:
        if control_writer is writer:
            control_writer = None
        try:
            writer.close()
        except Exception:
            pass
        print("[TCP] 发射端断开")


async def tcp_listener(port):
    server = await asyncio.start_server(handle_tcp_client, "0.0.0.0", port, reuse_address=True)
    print(f"[TCP] 整屏镜像接收端口 {port} 监听中（Windows/安卓发射端连这里）")
    async with server:
        await server.serve_forever()


async def ws_handler(ws):
    ws_clients.add(ws)
    print("[WS] 网页已连接")
    try:
        async for msg in ws:
            # 二进制消息 = 网页发送模式的视频帧（type1=config, type2=frame）
            if isinstance(msg, bytes):
                sock = sender_socks.get(id(ws))
                if sock is None:
                    continue
                try:
                    typ = msg[0]
                    payload = msg[1:]
                    sock.sendall(struct.pack(">I", len(payload)) + bytes([typ]) + payload)
                except Exception:
                    # 目标断开 -> 丢弃并提示网页
                    sender_socks.pop(id(ws), None)
                    try:
                        await ws.send(b"ERR:receiver-disconnected")
                    except Exception:
                        pass
            else:
                # JSON 控制消息
                import json
                try:
                    cmd = json.loads(msg)
                except Exception:
                    continue
                if cmd.get("cmd") == "connect":  # 发送模式：连目标安卓
                    ip = cmd.get("ip", "")
                    port = int(cmd.get("port", 9000))
                    old = sender_socks.pop(id(ws), None)
                    if old:
                        try:
                            old.close()
                        except Exception:
                            pass
                    try:
                        s = socket.create_connection((ip, port), timeout=5)
                        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                        s.settimeout(1.0)
                        sender_socks[id(ws)] = s
                        print(f"[WS] 网页发送模式 -> 连接 {ip}:{port} 成功")
                        await ws.send(b"OK:connected")
                    except Exception as e:
                        print(f"[WS] 连接 {ip}:{port} 失败：{e}")
                        await ws.send(("ERR:" + str(e)).encode("utf-8"))
                elif cmd.get("cmd") == "control":
                    w = control_writer
                    if w is None:
                        continue
                    try:
                        if cmd.get("kind") == "mouse":
                            payload = struct.pack(">BHHh", int(cmd.get("action", 0)),
                                                  int(cmd.get("x", 500)), int(cmd.get("y", 500)),
                                                  int(cmd.get("wheel", 0)))
                            head = struct.pack(">I", len(payload)) + bytes([TYPE_MOUSE])
                        else:
                            payload = struct.pack(">BI", int(cmd.get("action", 0)),
                                                  int(cmd.get("code", 0)))
                            head = struct.pack(">I", len(payload)) + bytes([TYPE_KEY])
                        w.write(head + payload)
                        await w.drain()
                    except Exception:
                        pass
                elif cmd.get("cmd") == "disconnect":
                    old = sender_socks.pop(id(ws), None)
                    if old:
                        try:
                            old.close()
                        except Exception:
                            pass
    finally:
        ws_clients.discard(ws)
        old = sender_socks.pop(id(ws), None)
        if old:
            try:
                old.close()
            except Exception:
                pass
        print("[WS] 网页断开")


async def ws_server(port):
    async with websockets.serve(ws_handler, "0.0.0.0", port, reuse_address=True):
        print(f"[WS] WebSocket/网页服务端口 {port}")
        await asyncio.Future()


async def main_async(tcp_port, ws_port):
    await asyncio.gather(tcp_listener(tcp_port), ws_server(ws_port))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tcp", type=int, default=9000, help="整屏镜像协议端口")
    ap.add_argument("--ws", type=int, default=8000, help="WebSocket 端口（网页连接用）")
    ap.add_argument("--http", type=int, default=8080, help="网页静态页端口")
    args = ap.parse_args()
    # 静态网页（独立端口，避免与 WebSocket 同端口双绑）
    web_dir = Path(__file__).parent
    handler = lambda *a, **kw: SimpleHTTPRequestHandler(*a, directory=str(web_dir), **kw)
    httpd = ThreadingHTTPServer(("0.0.0.0", args.http), handler)
    httpd.allow_reuse_address = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    print(f"[HTTP] 网页端地址：http://<本机IP>:{args.http}/（同一 Wi-Fi 内任何设备浏览器可打开）")
    asyncio.run(main_async(args.tcp, args.ws))


if __name__ == "__main__":
    main()
