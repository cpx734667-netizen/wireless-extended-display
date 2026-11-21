# -*- coding: utf-8 -*-
"""
无线扩展屏 - Windows 反向控制发送模块
======================================
功能：Windows 端作为【控制端】，把本机鼠标/键盘事件实时发送给
安卓被控端（v1.6+ 的无障碍反控服务 RemoteCtrlService 执行）。
与安卓「整屏镜像」发射端共用同一条 TCP 连接（发射端 socket），
控制消息格式完全一致（WXESMIRROR type=4 MOUSE / type=5 KEY）。

消息格式（复用帧格式 u32 len BE + u8 type + payload）：
  type=4 MOUSE: >BHHh  action(0=move 1=down 2=up 3=wheel) x(0-1000) y(0-1000) wheel
  type=5 KEY  : >BI    action(0=down 1=up) androidKeyCode

原理：
  - 鼠标：SetWindowsHookExW(WH_MOUSE_LL) 低级钩子，把屏幕像素坐标
    换算为 0-1000 相对坐标（与接收端换算约定一致）
  - 键盘：SetWindowsHookExW(WH_KEYBOARD_LL)，把 Windows 虚拟键码
    映射为 Android keyCode（映射表与安卓端 RemoteCtrlService 一致）
  - 低频钩子回调里只做坐标换算和入队，后台线程负责发送（节流），
    避免钩子回调阻塞系统输入。

依赖：仅标准库 + ctypes（无第三方依赖）。
"""
import ctypes
import ctypes.wintypes as wt
import struct
import threading
import time

TYPE_MOUSE = 4
TYPE_KEY = 5

WH_MOUSE_LL = 14
WH_KEYBOARD_LL = 13

WM_MOUSEMOVE = 0x0200
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
WM_MOUSEWHEEL = 0x020A

WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
WM_SYSKEYDOWN = 0x0104
WM_SYSKEYUP = 0x0105

# Windows 虚拟键码 -> Android keyCode（与 sender_win.ANDROID_TO_VK 反向对应）
VK_TO_ANDROID = {
    # 数字 0-9
    0x30: 7, 0x31: 8, 0x32: 9, 0x33: 10, 0x34: 11,
    0x35: 12, 0x36: 13, 0x37: 14, 0x38: 15, 0x39: 16,
    # 字母 A-Z
    0x41: 29, 0x42: 30, 0x43: 31, 0x44: 32, 0x45: 33, 0x46: 34,
    0x47: 35, 0x48: 36, 0x49: 37, 0x4A: 38, 0x4B: 39, 0x4C: 40,
    0x4D: 41, 0x4E: 42, 0x4F: 43, 0x50: 44, 0x51: 45, 0x52: 46,
    0x53: 47, 0x54: 48, 0x55: 49, 0x56: 50, 0x57: 51, 0x58: 52,
    0x59: 53, 0x5A: 54,
    # 功能键 F1-F12
    0x70: 131, 0x71: 132, 0x72: 133, 0x73: 134, 0x74: 135, 0x75: 136,
    0x76: 137, 0x77: 138, 0x78: 139, 0x79: 140, 0x7A: 141, 0x7B: 142,
    # 编辑与导航
    0x0D: 66,        # ENTER
    0x08: 67,        # BACKSPACE
    0x1B: 111,       # ESC
    0x20: 62,        # SPACE
    0x09: 61,        # TAB
    0x26: 19,        # UP
    0x28: 20,        # DOWN
    0x25: 21,        # LEFT
    0x27: 22,        # RIGHT
    0x10: 59,        # SHIFT
    0x11: 113,       # CTRL
    0x12: 57,        # ALT
    0x14: 115,       # CAPS_LOCK
    0x24: 122,       # HOME
    0x23: 123,       # END
    0x21: 92,        # PAGE_UP
    0x22: 93,        # PAGE_DOWN
    0x2D: 124,       # INSERT
    0x2E: 67,        # DELETE -> 安卓 DEL
}

# 屏幕尺寸缓存（钩子回调里不能反复查屏）
_screen = {"w": 1920, "h": 1080}
_lock = threading.Lock()
_queue = []           # (type, payload) 待发送队列
_hook_thread = None
_running = False


class POINT(ctypes.Structure):
    _fields_ = [("x", wt.LONG), ("y", wt.LONG)]


class MSLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("pt", POINT), ("mouseData", wt.DWORD), ("flags", wt.DWORD),
                ("time", wt.DWORD), ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong))]


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("vkCode", wt.DWORD), ("scanCode", wt.DWORD), ("flags", wt.DWORD),
                ("time", wt.DWORD), ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong))]


def set_screen(w, h):
    """由发射端在探测到桌面分辨率后设置（0-1000 相对坐标换算基准）。"""
    if w > 0 and h > 0:
        _screen["w"] = w
        _screen["h"] = h


def _enqueue(typ, payload):
    if not _running:
        return
    with _lock:
        _queue.append((typ, payload))


def start(sender, on_state=None):
    """sender: 对象，需提供 _send(typ, payload)（复用发射端 socket）。
    启动后本模块实时发送控制消息。"""
    global _running, _hook_thread
    if _running:
        return
    _running = True
    threading.Thread(target=_sender_loop, args=(sender,), daemon=True).start()
    _hook_thread = threading.Thread(target=_hook_loop, args=(on_state,), daemon=True)
    _hook_thread.start()


def stop():
    global _running
    _running = False


def _sender_loop(sender):
    """后台发送线程：节流 + 批量取队列发送。"""
    last_send = 0.0
    while _running:
        with _lock:
            items = list(_queue)
            _queue.clear()
        if items:
            now = time.time()
            # 鼠标 move 最高 30ms 一条；其他事件立即发
            for typ, payload in items:
                if typ == TYPE_MOUSE and payload[0] == 0:  # move
                    if now - last_send < 0.03:
                        continue
                    last_send = now
                try:
                    sender._send(typ, payload)
                except Exception:
                    pass
        else:
            time.sleep(0.01)


def _hook_loop(on_state=None):
    """低级钩子线程：消息循环。"""
    try:
        user32 = ctypes.windll.user32
        user32.SetProcessDPIAware()

        mouse_cb_type = ctypes.CFUNCTYPE(ctypes.c_long, ctypes.c_int, wt.WPARAM, wt.LPARAM)
        kbd_cb_type = ctypes.CFUNCTYPE(ctypes.c_long, ctypes.c_int, wt.WPARAM, wt.LPARAM)

        def _get_screen():
            w = _screen["w"]
            h = _screen["h"]
            # 首次运行用真实屏幕
            if w <= 0:
                w = user32.GetSystemMetrics(0)
                h = user32.GetSystemMetrics(1)
                _screen["w"], _screen["h"] = w, h
            return w, h

        def mouse_cb(nCode, wParam, lParam):
            if nCode >= 0 and _running:
                try:
                    ms = ctypes.cast(lParam, ctypes.POINTER(MSLLHOOKSTRUCT)).contents
                    w, h = _get_screen()
                    x = int(ms.pt.x * 1000.0 / max(w, 1))
                    y = int(ms.pt.y * 1000.0 / max(h, 1))
                    x = max(0, min(1000, x))
                    y = max(0, min(1000, y))
                    if wParam == WM_MOUSEMOVE:
                        _enqueue(TYPE_MOUSE, struct.pack(">BHHh", 0, x, y, 0))
                    elif wParam == WM_LBUTTONDOWN:
                        _enqueue(TYPE_MOUSE, struct.pack(">BHHh", 1, x, y, 0))
                    elif wParam == WM_LBUTTONUP:
                        _enqueue(TYPE_MOUSE, struct.pack(">BHHh", 2, x, y, 0))
                    elif wParam == WM_MOUSEWHEEL:
                        # 鼠标滚轮数据：高字为增量（120 一格）
                        delta = (ms.mouseData >> 16) & 0xFFFF
                        if delta >= 0x8000:
                            delta -= 0x10000
                        _enqueue(TYPE_MOUSE, struct.pack(">BHHh", 3, x, y, delta))
                except Exception:
                    pass
            return user32.CallNextHookEx(None, nCode, wParam, lParam)

        def kbd_cb(nCode, wParam, lParam):
            if nCode >= 0 and _running:
                try:
                    kb = ctypes.cast(lParam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
                    vk = kb.vkCode & 0xFF
                    if vk in VK_TO_ANDROID:
                        code = VK_TO_ANDROID[vk]
                        if wParam in (WM_KEYDOWN, WM_SYSKEYDOWN):
                            _enqueue(TYPE_KEY, struct.pack(">BI", 0, code))
                        else:
                            _enqueue(TYPE_KEY, struct.pack(">BI", 1, code))
                except Exception:
                    pass
            return user32.CallNextHookEx(None, nCode, wParam, lParam)

        mouse_cb_ref = mouse_cb_type(mouse_cb)
        kbd_cb_ref = kbd_cb_type(kbd_cb)
        hm = user32.SetWindowsHookExW(WH_MOUSE_LL, mouse_cb_ref, None, 0)
        hk = user32.SetWindowsHookExW(WH_KEYBOARD_LL, kbd_cb_ref, None, 0)
        if not hm or not hk:
            if on_state:
                on_state("反向控制钩子安装失败（权限不足？），控制发送不可用")
            _running = False
            return
        if on_state:
            on_state("反向控制已开启：本机鼠标/键盘将实时控制安卓被控端")
        msg = wt.MSG()
        while _running and user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))
        user32.UnhookWindowsHookEx(hm)
        user32.UnhookWindowsHookEx(hk)
    except Exception as e:
        if on_state:
            on_state(f"反向控制启动失败：{e}")
        _running = False


if __name__ == "__main__":
    # 自测：打印映射表完整性
    print("VK_TO_ANDROID 映射条目：", len(VK_TO_ANDROID))
    print("已加载（无第三方依赖）")
