# -*- coding: utf-8 -*-
"""
无线扩展屏 - macOS 发射端（投屏到安卓接收端 / 网页桥）
与 Windows 版同一协议（WXESMIRROR / TCP 9000），截屏用 ffmpeg avfoundation。
用法：
  python3 sender_mac.py --ip <安卓IP> [--fps 15] [--bitrate 4000] [--frames 秒]
依赖：python3 -m pip install imageio-ffmpeg pillow
"""
import argparse
import os
import re
import socket
import struct
import subprocess
import threading
import time
try:
    import pyautogui
    pyautogui.FAILSAFE = False
except Exception:
    pyautogui = None

MAGIC = b"WXESMIRROR"
TYPE_CONFIG = 1
TYPE_FRAME = 2
TYPE_HEARTBEAT = 3
TYPE_MOUSE = 4   # 反向控制：鼠标（接收端→发射端）
TYPE_KEY = 5     # 反向控制：键盘（接收端→发射端）
HEARTBEAT_S = 5
NAL_SPS = 7
NAL_PPS = 8
NAL_IDR = 5
VCL_TYPES = {1, 2, 3, 4, 5}


def extract_nals(buf: bytearray):
    out = []
    n = len(buf)
    i = 0
    starts = []
    while i < n - 3:
        if buf[i] == 0 and buf[i + 1] == 0:
            if buf[i + 2] == 1:
                starts.append((i, 3)); i += 3; continue
            if buf[i + 2] == 0 and i + 3 < n and buf[i + 3] == 1:
                starts.append((i, 4)); i += 4; continue
        i += 1
    if not starts:
        return out, 0
    for k in range(len(starts) - 1):
        s = starts[k][0] + starts[k][1]
        e = starts[k + 1][0]
        out.append(bytes(buf[s:e]))
    return out, starts[-1][0]


def probe_resolution(proc, timeout=3.0):
    """从 ffmpeg stderr 解析 '1920x1080'（avfoundation 探测输出）"""
    import select
    end = time.time() + timeout
    pat = re.compile(r"(\d{3,5})x(\d{3,5})")
    got = None
    while time.time() < end:
        r, _, _ = select.select([proc.stderr], [], [], 0.2)
        if r:
            line = proc.stderr.readline().decode("utf-8", "ignore")
            if not line:
                continue
            m = pat.search(line)
            if m:
                got = (int(m.group(1)), int(m.group(2)))
                if got[0] >= 640 and got[1] >= 480:
                    return got
    return got or (1920, 1080)


# ---- 反向控制（接收端发来鼠标/键盘事件，本机执行）----
ANDROID_TO_PYKEY = {
    7: '0', 8: '1', 9: '2', 10: '3', 11: '4', 12: '5',
    13: '6', 14: '7', 15: '8', 16: '9',
    29: 'a', 30: 'b', 31: 'c', 32: 'd', 33: 'e', 34: 'f',
    35: 'g', 36: 'h', 37: 'i', 38: 'j', 39: 'k', 40: 'l',
    41: 'm', 42: 'n', 43: 'o', 44: 'p', 45: 'q', 46: 'r',
    47: 's', 48: 't', 49: 'u', 50: 'v', 51: 'w', 52: 'x',
    53: 'y', 54: 'z',
    131: 'f1', 132: 'f2', 133: 'f3', 134: 'f4', 135: 'f5', 136: 'f6',
    137: 'f7', 138: 'f8', 139: 'f9', 140: 'f10', 141: 'f11', 142: 'f12',
    66: 'enter', 67: 'backspace', 111: 'esc', 62: 'space', 61: 'tab',
    19: 'up', 20: 'down', 21: 'left', 22: 'right',
    59: 'shift', 60: 'shift', 113: 'ctrl', 114: 'ctrl', 57: 'alt', 58: 'alt',
    115: 'capslock', 122: 'home', 123: 'end', 92: 'pageup', 93: 'pagedown',
}

def drain_control(sock, cbuf):
    if pyautogui is None or sock is None:
        return
    try:
        r, _, _ = select.select([sock], [], [], 0)
        if not r:
            return
        chunk = sock.recv(4096)
        if not chunk:
            return
        cbuf += chunk
    except Exception:
        return
    while len(cbuf) >= 5:
        (mlen,) = struct.unpack(">I", bytes(cbuf[0:4]))
        if mlen > 4096 or mlen < 0:
            del cbuf[:1]
            continue
        if len(cbuf) < 5 + mlen:
            break
        typ = cbuf[4]
        payload = bytes(cbuf[5:5 + mlen])
        del cbuf[:5 + mlen]
        try:
            if typ == TYPE_MOUSE and len(payload) >= 7:
                action, x, y, wheel = struct.unpack(">BHHh", payload[:7])
                sw, sh = pyautogui.size()
                px, py = int(x / 1000.0 * sw), int(y / 1000.0 * sh)
                if action == 0:
                    pyautogui.moveTo(px, py, duration=0)
                elif action == 1:
                    pyautogui.moveTo(px, py, duration=0)
                    pyautogui.mouseDown(button="left")
                elif action == 2:
                    pyautogui.mouseUp(button="left")
                elif action == 3:
                    pyautogui.scroll(wheel, x=px, y=py)
            elif typ == TYPE_KEY and len(payload) >= 5:
                action, code = struct.unpack(">BI", payload[:5])
                key = ANDROID_TO_PYKEY.get(code)
                if key:
                    if action == 0:
                        pyautogui.keyDown(key)
                    else:
                        pyautogui.keyUp(key)
        except Exception:
            pass


def run(ip, port, fps, bitrate_kbps, frames):
    import imageio_ffmpeg
    exe = imageio_ffmpeg.get_ffmpeg_exe()
    print(f"启动：{ip}:{port}，{fps} fps（ffmpeg avfoundation 截屏）", flush=True)
    cmd = [
        exe, "-hide_banner", "-loglevel", "info",
        "-fflags", "+flush_packets", "-flush_packets", "1",
        "-f", "avfoundation", "-framerate", str(fps), "-capture_cursor", "1",
        "-i", "1:none",
        "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-profile:v", "baseline", "-level", "4.0",
        "-pix_fmt", "yuv420p", "-g", str(fps), "-sc_threshold", "0",
        "-b:v", str(bitrate_kbps) + "k",
        "-f", "h264", "pipe:1",
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    sw, sh = probe_resolution(proc)
    print(f"桌面分辨率 {sw}x{sh}", flush=True)

    running = True
    sock = None
    cbuf = bytearray()

    def heartbeat():
        while running:
            time.sleep(HEARTBEAT_S)
            if sock:
                try:
                    sock.sendall(struct.pack(">I", 0) + bytes([TYPE_HEARTBEAT]))
                except Exception:
                    pass
    threading.Thread(target=heartbeat, daemon=True).start()

    def send(typ, payload):
        nonlocal sock
        if sock is None:
            return
        try:
            sock.sendall(struct.pack(">I", len(payload)) + bytes([typ]) + payload)
        except Exception:
            try:
                sock.close()
            except Exception:
                pass
            sock = None

    sps_pps = b""
    au = bytearray()
    buf = bytearray()
    start_t = time.time()
    try:
        while running:
            drain_control(sock, cbuf)
            if sock is None:
                try:
                    s = socket.create_connection((ip, port), timeout=5)
                    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    s.settimeout(2.0)
                    sock = s
                    s.sendall(MAGIC + bytes([1]) + struct.pack(">HH", sw, sh) + bytes([fps]))
                    print(f"已连接 {ip}:{port}，握手 {sw}x{sh}@{fps}", flush=True)
                except Exception as e:
                    print(f"连接失败：{e}，3 秒后重试…", flush=True)
                    time.sleep(3)
                    continue
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                if proc.poll() is not None:
                    err = proc.stderr.read(4096).decode("utf-8", "ignore")
                    print(f"ffmpeg 已退出：{err.strip()[:200]}", flush=True)
                    break
                time.sleep(0.05)
                continue
            buf += chunk
            nals, consumed = extract_nals(buf)
            del buf[:consumed]
            for nal in nals:
                typ = nal[0] & 0x1F if nal else 0
                if typ == NAL_SPS or typ == NAL_PPS:
                    sps_pps = sps_pps + b"\x00\x00\x00\x01" + nal
                elif typ == NAL_IDR:
                    if au:
                        send(TYPE_FRAME, bytes(au)); au.clear()
                    au += b"\x00\x00\x00\x01" + nal
                    if sps_pps:
                        send(TYPE_CONFIG, sps_pps)
                    send(TYPE_FRAME, bytes(au)); au.clear()
                elif typ in VCL_TYPES:
                    if au:
                        send(TYPE_FRAME, bytes(au)); au.clear()
                    au += b"\x00\x00\x00\x01" + nal
                else:
                    au += b"\x00\x00\x00\x01" + nal
            if frames and (time.time() - start_t) >= frames:
                break
    except KeyboardInterrupt:
        pass
    finally:
        running = False
        try:
            proc.terminate()
        except Exception:
            pass
        try:
            if sock:
                sock.close()
        except Exception:
            pass
        print("已停止", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", required=True)
    ap.add_argument("--port", type=int, default=9000)
    ap.add_argument("--fps", type=int, default=15)
    ap.add_argument("--bitrate", type=int, default=4000)
    ap.add_argument("--frames", type=float, default=0, help="发送秒数（0=直到 Ctrl+C）")
    args = ap.parse_args()
    run(args.ip, args.port, args.fps, args.bitrate, args.frames)


if __name__ == "__main__":
    main()
