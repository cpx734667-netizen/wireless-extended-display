import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - 键码映射：macOS virtual keycode <-> Android keyCode
// （与 Windows 版 ctrl_send_win.py 的 VK_TO_ANDROID 对应；安卓端 RemoteCtrlService 执行）

func macKeyCodeToAndroid(_ code: Int) -> Int? {
    switch code {
    // 数字行
    case 18: return 7    // 1
    case 19: return 8    // 2
    case 20: return 9    // 3
    case 21: return 10   // 4
    case 23: return 11   // 5
    case 22: return 12   // 6
    case 26: return 13   // 7
    case 28: return 14   // 8
    case 25: return 15   // 9
    case 29: return 16   // 0
    // 字母
    case 0: return 29    // a
    case 11: return 30   // b
    case 8: return 31    // c
    case 2: return 32    // d
    case 14: return 33   // e
    case 3: return 34    // f
    case 5: return 35    // g
    case 4: return 36    // h
    case 34: return 37   // i
    case 38: return 38   // j
    case 40: return 39   // k
    case 37: return 40   // l
    case 46: return 41   // m
    case 45: return 42   // n
    case 31: return 43   // o
    case 35: return 44   // p
    case 12: return 45   // q
    case 15: return 46   // r
    case 1: return 47    // s
    case 17: return 48   // t
    case 32: return 49   // u
    case 9: return 50    // v
    case 13: return 51   // w
    case 7: return 52    // x
    case 16: return 53   // y
    case 6: return 54    // z
    // 编辑/导航
    case 36: return 66   // return/enter
    case 51: return 67   // delete/backspace
    case 53: return 111  // esc
    case 49: return 62   // space
    case 48: return 61   // tab
    case 126: return 19  // up
    case 125: return 20  // down
    case 123: return 21  // left
    case 124: return 22  // right
    case 56: return 59   // shift
    case 59: return 113  // control
    case 58: return 57   // option/alt
    case 57: return 115  // caps lock
    case 115: return 122 // home
    case 119: return 123 // end
    case 116: return 92  // page up
    case 121: return 93  // page down
    // 功能键
    case 122: return 131 // F1
    case 120: return 132 // F2
    case 99: return 133  // F3
    case 118: return 134 // F4
    case 96: return 135  // F5
    case 97: return 136  // F6
    case 98: return 137  // F7
    case 100: return 138 // F8
    case 101: return 139 // F9
    case 109: return 140 // F10
    case 103: return 141 // F11
    case 111: return 142 // F12
    default: return nil
    }
}

func androidKeyCodeToMac(_ code: Int) -> Int? {
    // 反向映射（被控端注入用）：Android keyCode -> macOS keycode
    let pairs: [(Int, Int)] = [
        (7, 18), (8, 19), (9, 20), (10, 21), (11, 23), (12, 22), (13, 26), (14, 28), (15, 25), (16, 29),
        (29, 0), (30, 11), (31, 8), (32, 2), (33, 14), (34, 3), (35, 5), (36, 4), (37, 34), (38, 38),
        (39, 40), (40, 37), (41, 46), (42, 45), (43, 31), (44, 35), (45, 12), (46, 15), (47, 1), (48, 17),
        (49, 32), (50, 9), (51, 13), (52, 7), (53, 16), (54, 6),
        (66, 36), (67, 51), (111, 53), (62, 49), (61, 48),
        (19, 126), (20, 125), (21, 123), (22, 124),
        (59, 56), (113, 59), (57, 58), (115, 57),
        (122, 115), (123, 119), (92, 116), (93, 121),
        (131, 122), (132, 120), (133, 99), (134, 118), (135, 96), (136, 97), (137, 98), (138, 100),
        (139, 101), (140, 109), (141, 103), (142, 111)
    ]
    for (a, m) in pairs where a == code { return m }
    return nil
}

// MARK: - 辅助功能权限（CGEventTap 需要）

func accessibilityTrusted() -> Bool {
    return AXIsProcessTrusted()
}

func requestAccessibility() {
    // 触发系统授权弹窗（首次）
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
}

// MARK: - 操控端：捕获本机鼠标/键盘 -> 控制消息（type=4/5）
// 与 Windows ctrl_send_win.py 逻辑一致：事件入队 + 后台节流发送

final class CtrlSender {
    static let shared = CtrlSender()

    var onSend: ((_ type: UInt8, _ payload: Data) -> Void)?
    var onState: ((String) -> Void)?

    private var running = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private let queueLock = NSLock()
    private var queue: [(UInt8, Data)] = []
    private var lastMoveAt = 0.0

    private var mainW: CGFloat = 1920
    private var mainH: CGFloat = 1080

    func start() {
        guard !running else { return }
        guard accessibilityTrusted() else {
            onState?("⚠️ 未授予「辅助功能」权限：请在 系统设置 → 隐私与安全性 → 辅助功能 中允许「无线扩展屏」后重试")
            requestAccessibility()
            return
        }
        running = true

        // 主屏像素尺寸（0-1000 相对坐标换算基准）
        let bounds = CGDisplayBounds(CGMainDisplayID())
        mainW = bounds.width > 0 ? bounds.width : 1920
        mainH = bounds.height > 0 ? bounds.height : 1080

        // 后台发送线程（节流：move 30ms 一条，其他立即）
        let sendThread = Thread { [weak self] in
            guard let self else { return }
            while self.running {
                self.queueLock.lock()
                let items = self.queue
                self.queue.removeAll()
                self.queueLock.unlock()
                if !items.isEmpty {
                    let now = Date().timeIntervalSince1970
                    for (typ, payload) in items {
                        if typ == 4 && payload.count >= 7 && payload[0] == 0 {
                            if now - self.lastMoveAt < 0.03 { continue }
                            self.lastMoveAt = now
                        }
                        self.onSend?(typ, payload)
                    }
                } else {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
        sendThread.name = "wxes-ctrl-send"
        sendThread.start()

        // 事件源掩码
        let mask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                CtrlSender.handleEvent(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )

        guard let tap else {
            running = false
            onState?("控制钩子安装失败（权限不足？）")
            return
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        thread = Thread { [weak self] in
            guard let self else { return }
            // 保持 runloop 运行
            let runLoop = CFRunLoopGetCurrent()
            if let src = self.runLoopSource {
                CFRunLoopAddSource(runLoop, src, .commonModes)
            }
            CFRunLoopRun()
        }
        thread?.name = "wxes-ctrl-tap"
        thread?.start()

        onState?("反向控制已开启：本机鼠标/键盘将实时控制对方设备")
    }

    func stop() {
        guard running else { return }
        running = false
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        runLoopSource = nil
        tap = nil
        onState?("反向控制已关闭")
    }

    private static func handleEvent(_ type: CGEventType, _ event: CGEvent) {
        let s = CtrlSender.shared
        guard s.running else { return }
        switch type {
        case .mouseMoved:
            let p = event.location
            let (x, y) = s.norm(p)
            s.enqueueMouse(0, x, y, 0)
        case .leftMouseDown:
            let p = event.location
            let (x, y) = s.norm(p)
            s.enqueueMouse(1, x, y, 0)
        case .leftMouseUp:
            let p = event.location
            let (x, y) = s.norm(p)
            s.enqueueMouse(2, x, y, 0)
        case .scrollWheel:
            let p = event.location
            let (x, y) = s.norm(p)
            let delta = Int32(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            s.enqueueMouse(3, x, y, delta)
        case .keyDown, .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if let android = macKeyCodeToAndroid(code) {
                let action: UInt8 = type == .keyDown ? 0 : 1
                var payload = Data()
                payload.append(action)
                payload.append(UInt8((android >> 24) & 0xFF))
                payload.append(UInt8((android >> 16) & 0xFF))
                payload.append(UInt8((android >> 8) & 0xFF))
                payload.append(UInt8(android & 0xFF))
                s.enqueue(5, payload)
            }
        default:
            break
        }
    }

    private func enqueueMouse(_ action: UInt8, _ x: Int, _ y: Int, _ wheel: Int32) {
        var payload = Data()
        payload.append(action)
        payload.append(UInt8((x >> 8) & 0xFF))
        payload.append(UInt8(x & 0xFF))
        payload.append(UInt8((y >> 8) & 0xFF))
        payload.append(UInt8(y & 0xFF))
        let w = Int16(clamping: wheel)
        let uw = UInt16(bitPattern: w)
        payload.append(UInt8((Int(uw) >> 8) & 0xFF))
        payload.append(UInt8(Int(uw) & 0xFF))
        enqueue(4, payload)
    }

    private func enqueue(_ type: UInt8, _ payload: Data) {
        queueLock.lock()
        queue.append((type, payload))
        queueLock.unlock()
    }

    private func norm(_ p: CGPoint) -> (Int, Int) {
        let x = Int(max(0, min(1000, p.x * 1000 / max(mainW, 1))))
        let y = Int(max(0, min(1000, p.y * 1000 / max(mainH, 1))))
        return (x, y)
    }
}

// MARK: - 被控端：收到控制消息 -> 注入本机鼠标/键盘
// 与 sender_mac.py drain_control 等价（用 CGEvent 注入替代 pyautogui）

final class CtrlExecutor {
    static let shared = CtrlExecutor()
    var onState: ((String) -> Void)?

    private var mainW: CGFloat
    private var mainH: CGFloat

    private init() {
        // 与 sender_mac.py 的 pyautogui.size() 一致：坐标基准 = 主屏实际尺寸
        let bounds = CGDisplayBounds(CGMainDisplayID())
        mainW = bounds.width > 0 ? bounds.width : 1920
        mainH = bounds.height > 0 ? bounds.height : 1080
    }

    func setScreenSize(_ w: CGFloat, _ h: CGFloat) {
        if w > 0 && h > 0 {
            mainW = w
            mainH = h
        }
    }

    func handle(_ type: UInt8, _ payload: Data) {
        if type == 4 && payload.count >= 7 {
            let action = payload[0]
            let x = (Int(payload[1]) << 8) | Int(payload[2])
            let y = (Int(payload[3]) << 8) | Int(payload[4])
            let wheel = Int(Int16(bitPattern: UInt16((Int(payload[5]) << 8) | Int(payload[6]))))
            let px = CGFloat(x) * mainW / 1000
            let py = CGFloat(y) * mainH / 1000
            let pos = CGPoint(x: px, y: py)
            wxDebugLog("CtrlExecutor: MOUSE action=\(action) x=\(x) y=\(y) wheel=\(wheel) -> (\(Int(px)),\(Int(py)))")
            switch action {
            case 0:  // move
                CGWarpMouseCursorPosition(pos)
                postMouse(.mouseMoved, pos)
            case 1:  // down
                CGWarpMouseCursorPosition(pos)
                postMouse(.leftMouseDown, pos)
            case 2:  // up
                postMouse(.leftMouseUp, pos)
            case 3:  // wheel（正=上滚，负=下滚，与协议一致）
                if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(wheel), wheel2: 0, wheel3: 0) {
                    ev.location = CGPoint(x: px, y: py)
                    ev.post(tap: .cghidEventTap)
                }
            default:
                break
            }
        } else if type == 5 && payload.count >= 5 {
            let action = payload[0]
            let code = (Int(payload[1]) << 24) | (Int(payload[2]) << 16) | (Int(payload[3]) << 8) | Int(payload[4])
            wxDebugLog("CtrlExecutor: KEY action=\(action) androidCode=\(code)")
            if let macKey = androidKeyCodeToMac(code) {
                if let ev = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(macKey), keyDown: action == 0) {
                    // 修饰键（shift/ctrl/alt）单独事件不自动组合，这里保持简单：
                    // 普通字符按键直接注入（安卓端文本输入按字符追加）
                    ev.post(tap: .cghidEventTap)
                }
            }
        }
    }

    private func postMouse(_ type: CGEventType, _ pos: CGPoint) {
        let btn: CGMouseButton = .left
        if let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pos, mouseButton: btn) {
            ev.post(tap: .cghidEventTap)
        }
    }
}
