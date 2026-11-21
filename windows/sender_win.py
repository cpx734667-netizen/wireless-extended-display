# -*- coding: utf-8 -*-
"""
无线扩展屏 - Windows 发射端（投屏到安卓接收端 / 网页端桥）
协议兼容安卓端「整屏镜像」接收器（MirrorReceiver，TCP 9000）：
  握手 16 字节: magic "WXESMIRROR"(10) + version(1)=1 + width(2 BE) + height(2 BE) + fps(1)
  帧: u32 length(BE) + u8 type + payload
      type 1 = codec config (SPS/PPS, AnnexB)
      type 2 = 视频帧 (AnnexB)
      type 3 = 心跳
编码: ffmpeg (imageio-ffmpeg 自带) gdigrab 截屏 + libx264 -> AnnexB H.264 流,
      Python 从流中提取 SPS/PPS 作为 config 帧, 按关键帧组织视频帧。
GUI: tkinter; 命令行模式: sender_win.py --ip X --port Y --fps 15 --frames N
"""
import argparse
import ctypes
import os
import socket
import struct
import subprocess
import threading
import time
import tkinter as tk
from tkinter import ttk, messagebox
try:
    import pyautogui
    pyautogui.FAILSAFE = False  # 反向控制鼠标可能被移到角落，关闭紧急保险
except Exception:
    pyautogui = None

try:
    import ctrl_send_win  # Windows 反向控制发送（控制安卓被控端）
except Exception:
    ctrl_send_win = None

MAGIC = b"WXESMIRROR"
TYPE_CONFIG = 1
TYPE_FRAME = 2
TYPE_HEARTBEAT = 3
TYPE_MOUSE = 4   # 反向控制：鼠标（接收端→发射端）
TYPE_KEY = 5     # 反向控制：键盘（接收端→发射端）
HEARTBEAT_S = 5

# NAL 类型
NAL_SPS = 7
NAL_PPS = 8
NAL_IDR = 5
VCL_TYPES = {1, 2, 3, 4, 5}


class MirrorSender:
    def __init__(self):
        self.running = False
        self.sock = None
        self.control_buf = bytearray()
        self.control_enabled = True
        self.thread = None
        self.ffmpeg = None
        self.on_state = None

    def set_callback(self, cb):
        self.on_state = cb

    def _log(self, msg):
        if self.on_state:
            self.on_state(msg)

    def start(self, ip, port, fps, bitrate_kbps, width=0, height=0):
        if self.running:
            return
        self.running = True
        self.thread = threading.Thread(
            target=self._run, args=(ip, port, fps, bitrate_kbps, width, height), daemon=True)
        self.thread.start()

    def stop(self):
        self.running = False
        try:
            if self.ffmpeg and self.ffmpeg.poll() is None:
                self.ffmpeg.terminate()
        except Exception:
            pass
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass
        self.sock = None
        self._log("已停止")

    # ---- 反向控制（接收端发来鼠标/键盘事件，本机执行）----
    # 控制消息复用帧格式：u32 len(BE) + u8 type + payload
    #   type=4 MOUSE: u8 action(0=move/1=down/2=up/3=wheel) + u16 x(0-1000) + u16 y(0-1000) + i16 wheel
    #   type=5 KEY  : u8 action(0=down/1=up) + u32 vk(Windows 虚拟键码，Android keyCode 已映射)
    # Android keyCode -> Windows 虚拟键码（VK）
    ANDROID_TO_VK = {
        # 数字 0-9（Android KEYCODE_0=7 .. KEYCODE_9=16）
        7: 0x30, 8: 0x31, 9: 0x32, 10: 0x33, 11: 0x34, 12: 0x35,
        13: 0x36, 14: 0x37, 15: 0x38, 16: 0x39,
        # 字母 A-Z（KEYCODE_A=29 .. KEYCODE_Z=54）
        29: 0x41, 30: 0x42, 31: 0x43, 32: 0x44, 33: 0x45, 34: 0x46,
        35: 0x47, 36: 0x48, 37: 0x49, 38: 0x4A, 39: 0x4B, 40: 0x4C,
        41: 0x4D, 42: 0x4E, 43: 0x4F, 44: 0x50, 45: 0x51, 46: 0x52,
        47: 0x53, 48: 0x54, 49: 0x55, 50: 0x56, 51: 0x57, 52: 0x58,
        53: 0x59, 54: 0x5A,
        # 功能键 F1-F12（KEYCODE_F1=131..F12=142）
        131: 0x70, 132: 0x71, 133: 0x72, 134: 0x73, 135: 0x74, 136: 0x75,
        137: 0x76, 138: 0x77, 139: 0x78, 140: 0x79, 141: 0x7A, 142: 0x7B,
        # 编辑与导航
        66: 0x0D,        # ENTER
        67: 0x08,        # BACKSPACE（DEL）
        111: 0x1B,       # ESC
        62: 0x20,        # SPACE
        61: 0x09,        # TAB
        19: 0x26,        # DPAD_UP
        20: 0x28,        # DPAD_DOWN
        21: 0x25,        # DPAD_LEFT
        22: 0x27,        # DPAD_RIGHT
        59: 0x10,        # SHIFT_LEFT
        60: 0x10,        # SHIFT_RIGHT
        113: 0x11,       # CTRL_LEFT
        114: 0x11,       # CTRL_RIGHT
        57: 0x12,        # ALT_LEFT
        58: 0x12,        # ALT_RIGHT
        115: 0x14,       # CAPS_LOCK
        122: 0x24,       # MOVE_HOME / HOME
        123: 0x23,       # MOVE_END / END
        92: 0x21,        # PAGE_UP
        93: 0x22,        # PAGE_DOWN
        4: 0x1B,         # BACK（安卓返回键 -> Esc）
        168: 0x6B,       # NUMPAD_ADD
        169: 0x6D,       # NUMPAD_SUBTRACT
        170: 0x6A,       # NUMPAD_MULTIPLY
        171: 0x6F,       # NUMPAD_DIVIDE
        172: 0x0D,       # NUMPAD_ENTER
    }

    def _drain_control(self, sock):
        """非阻塞读取并执行接收端的反向控制消息。"""
        if not self.control_enabled or sock is None:
            return
        try:
            import select
            r, _, _ = select.select([sock], [], [], 0)
            if not r:
                return
            chunk = sock.recv(4096)
            if not chunk:
                return
            self.control_buf += chunk
        except Exception:
            return
        # 解析：多条 [u32 len + u8 type + payload]
        while len(self.control_buf) >= 5:
            (mlen,) = struct.unpack(">I", bytes(self.control_buf[0:4]))
            if mlen > 4096 or mlen < 0:
                del self.control_buf[:1]
                continue
            if len(self.control_buf) < 5 + mlen:
                break
            typ = self.control_buf[4]
            payload = bytes(self.control_buf[5:5 + mlen])
            del self.control_buf[:5 + mlen]
            try:
                if typ == TYPE_MOUSE and len(payload) >= 7:
                    action, x, y, wheel = struct.unpack(">BHHh", payload[:7])
                    self._exec_mouse(action, x, y, wheel)
                elif typ == TYPE_KEY and len(payload) >= 5:
                    action, vk = struct.unpack(">BI", payload[:5])
                    self._exec_key(action, vk)
            except Exception as e:
                self._log(f"控制执行异常：{e}")

    def _exec_mouse(self, action, x, y, wheel):
        if pyautogui is None:
            return
        sw, sh = pyautogui.size()
        px, py = int(x / 1000.0 * sw), int(y / 1000.0 * sh)
        if action == 0:      # move
            pyautogui.moveTo(px, py, duration=0)
        elif action == 1:    # down
            pyautogui.moveTo(px, py, duration=0)
            pyautogui.mouseDown(button="left")
        elif action == 2:    # up
            pyautogui.mouseUp(button="left")
        elif action == 3:    # wheel
            pyautogui.scroll(wheel, x=px, y=py)

    def _exec_key(self, action, vk):
        if pyautogui is None:
            return
        try:
            key = self.ANDROID_TO_VK.get(vk)
            if key is None:
                # 尝试原样当作 Windows 虚拟键码
                key = vk
            if key == 0:
                return
            # 用 ctypes 注入虚拟键码，最可靠
            user32 = ctypes.windll.user32
            if action == 0:
                user32.keybd_event(key, 0, 0, 0)
            else:
                user32.keybd_event(key, 0, 2, 0)  # KEYEVENTF_KEYUP
        except Exception:
            pass

    def _run(self, ip, port, fps, bitrate_kbps, width=0, height=0):
        import imageio_ffmpeg
        ffmpeg_exe = imageio_ffmpeg.get_ffmpeg_exe()
        self._log(f"启动：目标 {ip}:{port}，{fps} fps（ffmpeg 编码）")
        # 探测桌面实际分辨率（scale 保比例与握手都用）
        try:
            from PIL import ImageGrab
            probe = ImageGrab.grab()
            sw, sh = probe.size
        except Exception:
            sw, sh = 1920, 1080
        cmd = [
            ffmpeg_exe, "-hide_banner", "-loglevel", "error",
            "-fflags", "+flush_packets", "-flush_packets", "1",
            "-f", "gdigrab", "-framerate", str(fps), "-i", "desktop",
            "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
            "-profile:v", "baseline", "-level", "4.0",
            "-pix_fmt", "yuv420p", "-g", str(fps), "-sc_threshold", "0",
            "-b:v", str(bitrate_kbps) + "k",
            "-f", "h264", "pipe:1",
        ]
        if width > 0 and height > 0:
            # 保持宽高比缩放：按用户给的宽为基准，高按源比例自动计算（偶数对齐），
            # 避免 scale=W:H 强制拉伸导致画面变形（发送端比例错误）
            src_ar = sh / sw
            out_w = width
            out_h = int(round(width * src_ar / 2.0) * 2)
            cmd.insert(cmd.index("-pix_fmt"), "-vf")
            cmd.insert(cmd.index("-pix_fmt"), "scale=%d:%d" % (out_w, out_h))
        else:
            out_w, out_h = 0, 0
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.ffmpeg = proc
        except Exception as e:
            self._log(f"ffmpeg 启动失败：{e}")
            self.running = False
            return

        # 心跳线程
        def heartbeat():
            while self.running:
                time.sleep(HEARTBEAT_S)
                self._send(TYPE_HEARTBEAT, b"")
        threading.Thread(target=heartbeat, daemon=True).start()

        sps_pps = b""
        au = bytearray()
        sent_any = False
        if width > 0 and height > 0:
            # 握手用实际输出分辨率（与 scale 保比例后的 out_w/out_h 一致）
            src_ar = sh / sw
            out_h_calc = int(round(width * src_ar / 2.0) * 2)
            sw, sh = width, out_h_calc
        self._log(f"桌面分辨率 {sw}x{sh}")
        buf = bytearray()
        try:
            while self.running:
                # 连接（断线自动重连）
                if self.sock is None:
                    try:
                        s = socket.create_connection((ip, port), timeout=5)
                        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                        s.settimeout(2.0)
                        self.sock = s
                        # 握手：magic(10)+ver(1)+w(2BE)+h(2BE)+fps(1)
                        hs = MAGIC + bytes([1]) + struct.pack(">HH", sw, sh) + bytes([fps])
                        s.sendall(hs)
                        self._log(f"已连接 {ip}:{port}，握手 {sw}x{sh}@{fps}")
                        sent_any = False
                    except Exception as e:
                        self._log(f"连接失败：{e}，3 秒后重试…")
                        time.sleep(3)
                        continue
                # 先收反向控制（接收端鼠标/键盘）
                self._drain_control(s)
                # 读 ffmpeg 输出（os.read 立即返回当前可用数据，不凑满）
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    err = proc.stderr.read(4096).decode("utf-8", "ignore")
                    if proc.poll() is not None:
                        self._log(f"ffmpeg 已退出：{err.strip()[:200]}")
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
                            self._send_frame(bytes(au))
                            au.clear()
                        au += b"\x00\x00\x00\x01" + nal
                        if sps_pps:
                            self._send_config(sps_pps)
                        self._send_frame(bytes(au))
                        au.clear()
                        sent_any = True
                    elif typ in VCL_TYPES:
                        if au:
                            self._send_frame(bytes(au))
                            au.clear()
                        au += b"\x00\x00\x00\x01" + nal
                        sent_any = True
                    else:
                        au += b"\x00\x00\x00\x01" + nal
        except Exception as e:
            import traceback as _tb
            self._log(f"发送异常：{e}")
            try:
                self._log(_tb.format_exc())
            except Exception:
                pass
        finally:
            try:
                proc.terminate()
            except Exception:
                pass
            try:
                if self.sock:
                    self.sock.close()
            except Exception:
                pass
            self.sock = None
            self.running = False

    def _send(self, typ, payload):
        s = self.sock
        if s is None:
            return
        try:
            s.sendall(struct.pack(">I", len(payload)) + bytes([typ]) + payload)
        except Exception:
            try:
                s.close()
            except Exception:
                pass
            self.sock = None

    def _send_config(self, sps_pps):
        if sps_pps:
            self._send(TYPE_CONFIG, sps_pps)

    def _send_frame(self, frame):
        if frame:
            self._send(TYPE_FRAME, frame)


def extract_nals(buf: bytearray):
    """从 AnnexB 缓冲中提取完整 NAL 列表 + 已消费字节数（处理跨块边界）"""
    out = []
    n = len(buf)
    i = 0
    starts = []  # (start_index, start_code_len)
    while i < n - 3:
        if buf[i] == 0 and buf[i + 1] == 0:
            if buf[i + 2] == 1:
                starts.append((i, 3))
                i += 3
                continue
            if buf[i + 2] == 0 and i + 3 < n and buf[i + 3] == 1:
                starts.append((i, 4))
                i += 4
                continue
        i += 1
    if not starts:
        return out, 0
    for k in range(len(starts) - 1):
        s = starts[k][0] + starts[k][1]
        e = starts[k + 1][0]
        out.append(bytes(buf[s:e]))
    consumed = starts[-1][0]
    return out, consumed


class SenderApp:
    def __init__(self, root):
        self.root = root
        self.sender = MirrorSender()
        self.sender.set_callback(self._ui_log)
        root.title("无线扩展屏 - Windows 发射端")
        root.geometry("440x360")
        root.resizable(False, False)
        frm = ttk.Frame(root, padding=14)
        frm.pack(fill=tk.BOTH, expand=True)
        ttk.Label(frm, text="接收端 IP（安卓设备 IP / 网页桥 IP）：").grid(row=0, column=0, sticky="w")
        self.ip_var = tk.StringVar(value="192.168.1.5")
        ttk.Entry(frm, textvariable=self.ip_var, width=24).grid(row=1, column=0, sticky="w", pady=(4, 10))
        ttk.Label(frm, text="帧率：").grid(row=2, column=0, sticky="w")
        self.fps_var = tk.StringVar(value="15")
        ttk.Combobox(frm, textvariable=self.fps_var, values=("10", "15", "24", "30"), width=6, state="readonly").grid(row=2, column=1, sticky="w")
        ttk.Label(frm, text="码率：").grid(row=3, column=0, sticky="w", pady=(6, 0))
        self.br_var = tk.StringVar(value="4000")
        ttk.Combobox(frm, textvariable=self.br_var, values=("2000", "4000", "8000", "12000"), width=8, state="readonly").grid(row=3, column=1, sticky="w", pady=(6, 0))
        ttk.Label(frm, text="(kbps，分辨率越高建议越大)").grid(row=3, column=2, sticky="w", pady=(6, 0))
        self.ctrl_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(
            frm, text="启用反向控制（控制安卓被控端：本机鼠标/键盘实时控制安卓）",
            variable=self.ctrl_var).grid(row=4, column=0, columnspan=3, sticky="w", pady=(4, 0))
        self.btn = ttk.Button(frm, text="开始投屏", command=self.toggle)
        self.btn.grid(row=5, column=0, sticky="w", pady=14)
        self.status = tk.Text(frm, height=9, width=56, state="disabled")
        self.status.grid(row=6, column=0, columnspan=3, sticky="nsew")
        self._ui_log("就绪。安卓端打开「无线扩展屏」→ 确认「整屏镜像」监听中（端口 9000），填入安卓设备 IP 后点开始。")
        self._ui_log("勾选「启用反向控制」后，本机鼠标/键盘会实时控制安卓被控端（安卓需已在设置页开启无障碍反向控制）。")

    def _ui_log(self, msg):
        def _w():
            self.status.config(state="normal")
            self.status.insert(tk.END, time.strftime("[%H:%M:%S] ") + msg + "\n")
            self.status.see(tk.END)
            self.status.config(state="disabled")
        try:
            self.root.after(0, _w)
        except Exception:
            pass

    def toggle(self):
        if self.sender.running:
            if ctrl_send_win:
                ctrl_send_win.stop()
            self.sender.stop()
            self.btn.config(text="开始投屏")
            return
        ip = self.ip_var.get().strip()
        try:
            fps = int(self.fps_var.get())
            br = int(self.br_var.get())
        except ValueError:
            messagebox.showerror("参数错误", "帧率/码率需为数字")
            return
        if not ip:
            messagebox.showerror("参数错误", "请填写接收端 IP")
            return
        self.btn.config(text="停止投屏")
        self.sender.start(ip, 9000, fps, br)
        # 反向控制发送：控制安卓被控端
        if self.ctrl_var.get() and ctrl_send_win:
            # 等连接建立后设置屏幕基准并启动钩子
            def _launch_ctrl():
                for _ in range(30):
                    if self.sender.sock is not None:
                        try:
                            from PIL import ImageGrab
                            probe = ImageGrab.grab()
                            ctrl_send_win.set_screen(*probe.size)
                        except Exception:
                            pass
                        ctrl_send_win.start(self.sender, self._ui_log)
                        return
                    time.sleep(0.5)
            threading.Thread(target=_launch_ctrl, daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="")
    ap.add_argument("--port", type=int, default=9000)
    ap.add_argument("--fps", type=int, default=15)
    ap.add_argument("--bitrate", type=int, default=4000)
    ap.add_argument("--frames", type=int, default=0, help="发送 N 帧后自动停止（0=一直发）")
    ap.add_argument("--width", type=int, default=0, help="发送分辨率宽（0=桌面实际）")
    ap.add_argument("--height", type=int, default=0, help="发送分辨率高（0=桌面实际）")
    args = ap.parse_args()
    if args.ip:
        s = MirrorSender()
        s.set_callback(lambda msg: print(msg, flush=True))
        s.start(args.ip, args.port, args.fps, args.bitrate, args.width, args.height)
        if args.frames:
            try:
                time.sleep(args.frames)
            finally:
                s.stop()
        else:
            try:
                while s.running:
                    time.sleep(1)
            except KeyboardInterrupt:
                s.stop()
        return
    root = tk.Tk()
    SenderApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
