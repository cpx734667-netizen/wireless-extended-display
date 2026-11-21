import Foundation
import Darwin
import AppKit

// MARK: - 入口：CLI 测试模式 / GUI 模式

let cliArgs = CommandLine.arguments

// ---------- CLI: 设备探测诊断 ----------
if cliArgs.count > 1 && cliArgs[1] == "--detect-device" {
    let s = ScreenSender()
    s.onStatus = { _ in }
    let idx = s.detectScreenIndexForDiagnostics()
    print("DETECT: 屏幕设备索引 = \(idx)")
    exit(0)
}

// ---------- CLI: 文件发送测试（无需屏幕录制权限，验证接收端协议） ----------
// 用法: WXES --send-file-test <ip> <port> <h264文件> <宽> <高> <fps> [秒数]
func runFileSendTest(ip: String, port: Int, path: String, w: Int, h: Int, fps: Int, seconds: Int) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        print("FILE-SEND: 无法读取文件 \(path)")
        exit(1)
    }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { print("FILE-SEND: socket 失败"); exit(1) }
    var one: Int32 = 1
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else {
        print("FILE-SEND: IP 无效"); exit(1)
    }
    var ok = false
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            ok = (connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0)
        }
    }
    guard ok else { print("FILE-SEND: 连接失败"); exit(1) }

    func rawSend(_ d: Data) {
        var sent = 0
        while sent < d.count {
            let n = d.withUnsafeBytes { ptr -> Int in
                write(fd, ptr.baseAddress!.advanced(by: sent), d.count - sent)
            }
            if n <= 0 { return }
            sent += n
        }
    }
    func packet(_ type: UInt8, _ payload: Data) {
        var header = Data()
        var len = UInt32(payload.count).bigEndian
        header.append(contentsOf: withUnsafeBytes(of: &len) { Data($0) })
        header.append(type)
        header.append(payload)
        rawSend(header)
    }

    var hs = Data(H264.MAGIC)
    hs.append(1)
    hs.append(UInt8((w >> 8) & 0xFF)); hs.append(UInt8(w & 0xFF))
    hs.append(UInt8((h >> 8) & 0xFF)); hs.append(UInt8(h & 0xFF))
    hs.append(UInt8(fps))
    rawSend(hs)
    print("FILE-SEND: 已连接，握手 \(w)x\(h)@\(fps)")

    var spsPps = Data()
    var au = Data()
    var count = 0
    let start = Date()
    while Date().timeIntervalSince(start) < Double(seconds) {
        let nals = H264.splitNALs(data)
        for nal in nals {
            let typ = H264.nalType(nal)
            if typ == 7 || typ == 8 {
                spsPps.append(Data([0, 0, 0, 1])); spsPps.append(nal)
            } else if typ == 5 {
                if !au.isEmpty { packet(2, au); au = Data() }
                au.append(Data([0, 0, 0, 1])); au.append(nal)
                if !spsPps.isEmpty { packet(1, spsPps) }
                packet(2, au); au = Data()
                count += 1
            } else if [1, 2, 3, 4].contains(typ) {
                if !au.isEmpty { packet(2, au); au = Data() }
                au.append(Data([0, 0, 0, 1])); au.append(nal)
                count += 1
            } else {
                au.append(Data([0, 0, 0, 1])); au.append(nal)
            }
        }
        if count > 0 {
            // 持续循环发送直到时间到（模拟连续直播流）
            if Date().timeIntervalSince(start) >= Double(seconds) { break }
            Thread.sleep(forTimeInterval: 0.08)
            count = 0
            continue
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    close(fd)
    print("FILE-SEND: 完成（连续推流 \(seconds) 秒）")
    exit(0)
}

// ---------- CLI: 真实发送测试（ffmpeg 截屏，需要屏幕录制权限） ----------
// 用法: WXES --send-test <ip> <port> <fps> <bitrate> <宽> <高> [屏幕名] [秒数]（屏幕名如 "Capture screen 0"，默认主屏）
func runSendTest(ip: String, port: Int, fps: Int, bitrate: Int, w: Int, h: Int, screen: String, seconds: Int) {
    let sender = ScreenSender()
    sender.onStatus = { text in
        print("SEND-TEST: \(text)")
    }
    let wv = w > 0 ? w : nil
    let hv = h > 0 ? h : nil
    sender.start(ip: ip, port: port, fps: fps, bitrateKbps: bitrate, width: wv, height: hv, screenName: screen)
    print("SEND-TEST: 启动，运行 \(seconds) 秒")
    Thread.sleep(forTimeInterval: Double(seconds))
    sender.stop()
    print("SEND-TEST: 完成")
    exit(0)
}

if cliArgs.count > 1 {
    switch cliArgs[1] {
    case "--send-file-test":
        guard cliArgs.count >= 8 else {
            print("用法: --send-file-test <ip> <port> <h264文件> <宽> <高> <fps> [秒]")
            exit(1)
        }
        let ip = cliArgs[2]
        let port = Int(cliArgs[3]) ?? 9000
        let path = cliArgs[4]
        let w = Int(cliArgs[5]) ?? 1920
        let h = Int(cliArgs[6]) ?? 1080
        let fps = Int(cliArgs[7]) ?? 15
        let secs = cliArgs.count > 8 ? (Int(cliArgs[8]) ?? 5) : 5
        runFileSendTest(ip: ip, port: port, path: path, w: w, h: h, fps: fps, seconds: secs)

    case "--send-test":
        guard cliArgs.count >= 7 else {
            print("用法: --send-test <ip> <port> <fps> <bitrate> <宽> <高> [屏幕] [秒]")
            exit(1)
        }
        let ip = cliArgs[2]
        let port = Int(cliArgs[3]) ?? 9000
        let fps = Int(cliArgs[4]) ?? 15
        let bitrate = Int(cliArgs[5]) ?? 4000
        let w = Int(cliArgs[6]) ?? 0
        let h = Int(cliArgs[7]) ?? 0
        let screen = cliArgs.count > 8 ? cliArgs[8] : "Capture screen 0"
        let secs = cliArgs.count > 9 ? (Int(cliArgs[9]) ?? 8) : 8
        runSendTest(ip: ip, port: port, fps: fps, bitrate: bitrate, w: w, h: h, screen: screen, seconds: secs)

    case "--send-test-src":
        // 自测模式：lavfi testsrc2 恒定动画源，验证限速与协议
        guard cliArgs.count >= 7 else {
            print("用法: --send-test-src <ip> <port> <fps> <bitrate> <宽> <高> [秒]")
            exit(1)
        }
        let ip = cliArgs[2]
        let port = Int(cliArgs[3]) ?? 9000
        let fps = Int(cliArgs[4]) ?? 15
        let bitrate = Int(cliArgs[5]) ?? 4000
        let w = Int(cliArgs[6]) ?? 1280
        let h = Int(cliArgs[7]) ?? 720
        let secs = cliArgs.count > 8 ? (Int(cliArgs[8]) ?? 8) : 8
        let sender = ScreenSender()
        sender.onStatus = { text in print("SEND-TEST: \(text)") }
        sender.start(ip: ip, port: port, fps: fps, bitrateKbps: bitrate,
                     width: w, height: h, screenName: "", testSource: true)
        print("SEND-TEST-SRC: 启动，运行 \(secs) 秒")
        Thread.sleep(forTimeInterval: Double(secs))
        sender.stop()
        print("SEND-TEST-SRC: 完成")
        exit(0)

    default:
        break
    }
}

// ---------- GUI 模式 ----------
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "关于 无线扩展屏", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "退出 无线扩展屏", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

app.run()
