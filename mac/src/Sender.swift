import Foundation
import Darwin

// MARK: - 发送服务（ffmpeg 截屏编码 + WXESMIRROR 协议发送）

final class ScreenSender {
    var onStatus: ((String) -> Void)?
    var onControl: ((_ type: UInt8, _ payload: Data) -> Void)?

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var readThread: Thread?
    private var stderrThread: Thread?
    private var heartbeatThread: Thread?
    private var connectThread: Thread?
    private var sendThread: Thread?
    private var resendThread: Thread?
    private var ctrlReadThread: Thread?

    private var sock: Int32 = -1
    private let sendLock = NSLock()
    private var running = false
    private var stopRequested = false

    private var targetIP = ""
    private var targetPort = 9000
    private var fps = 15
    private var bitrateKbps = 4000
    private var outW = 1920
    private var outH = 1080
    private var probed = false

    private var spsData = Data()
    private var ppsData = Data()
    private var auBuf = Data()
    private let frameLock = NSLock()
    private var lastFrameSent = 0.0
    private var lastConfigSent = Data()
    private var lastFrameData = Data()
    private var lastFrameAt = Date(timeIntervalSince1970: 0)
    // 调试计数：定位 NAL 类型误判
    private var dbgSps = 0, dbgPps = 0, dbgIdr = 0, dbgP = 0, dbgOther = 0
    private var iterCount = 0
    private var dbgSent = 0

    private func bundledFFmpeg() -> String? {
        if let res = Bundle.main.resourceURL {
            let p = res.appendingPathComponent("ffmpeg").path
            if FileManager.default.fileExists(atPath: p) {
                return p
            }
        }
        return nil
    }

    /// 诊断入口（CLI --detect-device）
    func detectScreenIndexForDiagnostics() -> Int {
        return detectScreenIndex(fallback: 0)
    }

    /// 运行时探测 avfoundation 屏幕采集设备索引
    /// （不同 Mac 上"Capture screen"的设备索引不同，可能被摄像头挤到 5/6/7；
    ///  网络摄像头（iPhone 连续互通相机）枚举可能很慢，需耐心等待）
    private func detectScreenIndex(fallback: Int) -> Int {
        if let cached = ScreenSender.cachedScreenIndex {
            return cached
        }
        guard let ffmpeg = bundledFFmpeg() else { return fallback }
        var result: Int?
        for attempt in 0..<2 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            result = probeScreenIndex(ffmpeg: ffmpeg)
            if result != nil { break }
        }
        let idx = result ?? fallback
        ScreenSender.cachedScreenIndex = idx
        wxDebugLog("detectScreenIndex: 结果 \(idx)（探测=\(result != nil)，回退=\(result == nil)）")
        return idx
    }

    private static var cachedScreenIndex: Int?

    private func probeScreenIndex(ffmpeg: String) -> Int? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        var collected = Data()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            collected = pipe.fileHandleForReading.readDataToEndOfFile()
            sem.signal()
        }
        do {
            try proc.run()
        } catch {
            return nil
        }
        if sem.wait(timeout: .now() + .seconds(12)) == .timedOut {
            proc.terminate()
            return nil
        }
        guard let text = String(data: collected, encoding: .utf8) else { return nil }
        let pattern = try? NSRegularExpression(pattern: #"\[(\d+)\]\s*Capture screen"#)
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = pattern?.firstMatch(in: text, options: [], range: range) {
            return Int(ns.substring(with: m.range(at: 1)))
        }
        return nil
    }

    /// 开始投屏；testSource=true 时使用 lavfi testsrc2（恒定动画）作为输入，用于链路自测
    /// - Parameter screenName: avfoundation 屏幕设备名（如 "Capture screen 0"）——比数字索引可靠，
    ///   iPhone 连续互通摄像头会动态占用数字索引导致漂移，按设备名采集不受影响
    func start(ip: String, port: Int, fps: Int, bitrateKbps: Int,
               width: Int?, height: Int?, screenName: String, testSource: Bool = false) {
        guard !running else { return }
        targetIP = ip
        targetPort = port
        self.fps = min(max(fps, 1), 255)
        self.bitrateKbps = bitrateKbps
        stopRequested = false
        running = true
        probed = false
        spsData = Data()
        ppsData = Data()
        auBuf = Data()

        guard let ffmpeg = bundledFFmpeg() else {
            onStatus?("错误：未找到内置 ffmpeg")
            running = false
            return
        }

        var args: [String]
        if testSource {
            // 自测模式：恒定动画源（lavfi 按需生成、时间戳 rate=60）
            let tw = (width ?? 1280) > 0 ? width! : 1280
            let th = (height ?? 720) > 0 ? height! : 720
            args = [
                "-hide_banner", "-loglevel", "info",
                "-f", "lavfi", "-i", "testsrc2=size=\(tw)x\(th):rate=60",
            ]
            outW = tw
            outH = th
            probed = true
            wxDebugLog("自测源: testsrc2 \(tw)x\(th) 目标帧率 \(self.fps)")
        } else {
            // avfoundation 屏幕采集：-framerate 设标称采集率（30/60），fps 滤镜按目标帧率
            // 精确抽帧——屏幕采集是真实节拍输入，fps 滤镜在此生效精确（lavfi 例外，见上）
            let captureFps = self.fps > 30 ? 60 : 30
            let devName = screenName.isEmpty ? "Capture screen 0" : screenName
            args = [
                "-hide_banner", "-loglevel", "info",
                "-f", "avfoundation", "-framerate", "\(captureFps)", "-capture_cursor", "1",
                "-i", "\(devName)"
            ]
            if let w = width, let h = height, w > 0, h > 0 {
                let ew = w % 2 == 0 ? w : w + 1
                let eh = h % 2 == 0 ? h : h + 1
                // 实时输入下 fps 滤镜精确输出目标帧率，逐帧直发保持引用链完整
                args += ["-vf", "scale=\(ew):\(eh),fps=\(self.fps)"]
                outW = ew
                outH = eh
                probed = true  // 自定义尺寸无需探测
            } else {
                // 未指定尺寸：保持原分辨率但必须走 scale+fps（单独 fps 滤镜对 avfoundation
                // 静止画面不输出帧；scale 激活帧管线后 fps 滤镜可复制帧，静止屏幕也持续出帧）
                args += ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,fps=\(self.fps)"]
            }
            // 未指定尺寸时由 stderrLoop 从 ffmpeg 日志探测源分辨率（probed=false）
            wxDebugLog("ffmpeg 采集: 设备 \(devName) 采集帧率 \(captureFps) 目标帧率 \(self.fps)")
        }
        args += [
            "-c:v", "libx264", "-preset", "ultrafast",
            // 注意：不能用 -tune zerolatency —— 其内部设置（sliced-threads/rc-lookahead 等）
            // 产出的流会被 macOS VideoToolbox 直接拒绝（实测全部 -12909）；
            // 低延迟用 -bf 0（禁 B 帧）+ ultrafast + baseline 达成
            "-bf", "0",
            "-profile:v", "baseline", "-level", "4.0",
            "-pix_fmt", "yuv420p", "-g", "\(self.fps)", "-sc_threshold", "0",
            "-b:v", "\(bitrateKbps)k",
            "-f", "h264", "pipe:1"
        ]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        stdoutPipe = outPipe
        process = proc

        onStatus?("正在启动截屏编码（\(self.fps)fps / \(bitrateKbps)kbps）…")

        // 被控端默认处理：控制消息 -> 注入本机（UI 可覆盖）
        if onControl == nil {
            onControl = { type, payload in
                CtrlExecutor.shared.handle(type, payload)
            }
        }

        connectThread = Thread { [weak self] in self?.connectLoop() }
        connectThread?.name = "wxes-connect"
        connectThread?.start()

        readThread = Thread { [weak self] in self?.readLoop() }
        readThread?.name = "wxes-send-read"
        readThread?.start()

        stderrThread = Thread { [weak self] in self?.stderrLoop(errPipe) }
        stderrThread?.name = "wxes-send-stderr"
        stderrThread?.start()

        heartbeatThread = Thread { [weak self] in self?.heartbeatLoop() }
        heartbeatThread?.name = "wxes-heartbeat"
        heartbeatThread?.start()

        resendThread = Thread { [weak self] in self?.resendLoop() }
        resendThread?.name = "wxes-resend"
        resendThread?.start()

        ctrlReadThread = Thread { [weak self] in self?.ctrlReadLoop() }
        ctrlReadThread?.name = "wxes-ctrl-read"
        ctrlReadThread?.start()

        sendThread = nil

        do {
            try proc.run()
        } catch {
            onStatus?("启动 ffmpeg 失败：\(error.localizedDescription)")
            stop()
        }
    }

    func stop() {
        guard running || stopRequested else { return }
        stopRequested = true
        running = false
        wxDebugLog("NAL 统计: SPS=\(dbgSps) PPS=\(dbgPps) IDR=\(dbgIdr) P=\(dbgP) 其他=\(dbgOther) 已发送=\(dbgSent)")
        if let proc = process, proc.isRunning {
            proc.terminate()
            // ffmpeg 在采集卡死时可能不响应 SIGTERM，加看门狗强杀
            let pid = proc.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
        process = nil
        closeSock()
        onStatus?("已停止投屏")
    }

    // MARK: 连接管理

    private func connectLoop() {
        // 等待分辨率探测完成（自定义尺寸时已置 probed）
        var waited = 0.0
        while !probed && waited < 6.0 && running && !stopRequested {
            Thread.sleep(forTimeInterval: 0.5)
            waited += 0.5
        }
        while running && !stopRequested {
            if sock < 0 {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    Thread.sleep(forTimeInterval: 3)
                    continue
                }
                var one: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(targetPort).bigEndian
                let ip = targetIP
                if inet_pton(AF_INET, ip, &addr.sin_addr) != 1 {
                    DispatchQueue.main.async { self.onStatus?("IP 格式无效：\(ip)") }
                    running = false
                    stopRequested = true
                    close(fd)
                    return
                }
                var connected = false
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connected = (connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0)
                    }
                }
                if connected {
                    sendLock.lock()
                    sock = fd
                    // 发送握手：MAGIC + ver + 宽高 + fps
                    var hs = Data(H264.MAGIC)
                    hs.append(1)
                    hs.append(UInt8((outW >> 8) & 0xFF))
                    hs.append(UInt8(outW & 0xFF))
                    hs.append(UInt8((outH >> 8) & 0xFF))
                    hs.append(UInt8(outH & 0xFF))
                    hs.append(UInt8(fps))
                    rawSendLocked(fd, hs)
                    sendLock.unlock()
                    DispatchQueue.main.async {
                        self.onStatus?("已连接接收端 \(self.targetIP):\(self.targetPort) · 握手 \(self.outW)x\(self.outH)@\(self.fps)fps · 投屏中")
                    }
                } else {
                    close(fd)
                    DispatchQueue.main.async {
                        self.onStatus?("连接 \(self.targetIP):\(self.targetPort) 失败，3 秒后重试…")
                    }
                    Thread.sleep(forTimeInterval: 3)
                }
            } else {
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    // MARK: 发送

    private func rawSendLocked(_ fd: Int32, _ data: Data) {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { ptr -> Int in
                write(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent)
            }
            if n <= 0 { return }
            sent += n
        }
    }

    private func sendPacket(type: UInt8, payload: Data) {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard sock >= 0 else { return }
        var header = Data()
        var len = UInt32(payload.count).bigEndian
        header.append(contentsOf: withUnsafeBytes(of: &len) { Data($0) })
        header.append(type)
        header.append(payload)
        var sent = 0
        while sent < header.count {
            let n = header.withUnsafeBytes { ptr -> Int in
                write(sock, ptr.baseAddress!.advanced(by: sent), header.count - sent)
            }
            if n <= 0 {
                close(sock)
                sock = -1
                DispatchQueue.main.async {
                    self.onStatus?("接收端连接断开，重新连接中…")
                }
                return
            }
            sent += n
        }
    }

    private func closeSock() {
        sendLock.lock()
        if sock >= 0 {
            close(sock)
            sock = -1
        }
        sendLock.unlock()
    }

    // MARK: 读取 ffmpeg stdout 并切分 NAL（与 Windows 版同算法）

    private func readLoop() {
        guard let outPipe = stdoutPipe else { return }
        let fh = outPipe.fileHandleForReading
        // 用 [UInt8] 数组作为流缓冲：macOS 27 上 Data 反复 removeFirst+append 会损坏内部状态导致崩溃
        var raw: [UInt8] = []
        var consumed = 0
        while running && !stopRequested {
            // 小块读取：让“最新帧”队列以亚帧间隔更新，定时器才能满额发送
            let chunk = fh.readData(ofLength: 8192)
            if chunk.isEmpty {
                if !running || stopRequested { break }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            raw.append(contentsOf: chunk)
            var nals: [Data] = []
            let positions = H264.startCodePositions(raw, from: consumed)
            iterCount += 1
            if iterCount % 200 == 1 {
                wxDebugLog("readLoop: iter=\(iterCount) raw=\(raw.count) consumed=\(consumed) 起始码=\(positions.count) 本轮nal=\(max(positions.count - 1, 0))")
            }
            if positions.count > 1 {
                for k in 0..<(positions.count - 1) {
                    let s = positions[k].offset + positions[k].length
                    let e = positions[k + 1].offset
                    if e > s {
                        nals.append(Data(raw[s..<e]))
                    }
                }
                consumed = positions[positions.count - 1].offset
            }
            // 周期性压实，避免无限增长
            if consumed > 2_000_000 {
                raw.removeFirst(consumed)
                consumed = 0
            }
            handleNals(nals)
        }
    }

    /// 逐帧直发：不做任何丢帧/定时——编码器输入（屏幕采集）本身是实时节拍，
    /// fps 已在编码器侧由 -framerate + fps 滤镜精确控制；逐帧直发保证 P 帧
    /// 引用链完整，VideoToolbox 才能正常解码（丢帧会毒化解码会话）。
    private func handleNals(_ nals: [Data]) {
        for nal in nals {
            let typ = H264.nalType(nal)
            if typ == H264.NAL_SPS {
                frameLock.lock()
                spsData = nal
                frameLock.unlock()
                dbgSps += 1
            } else if typ == H264.NAL_PPS {
                frameLock.lock()
                ppsData = nal
                frameLock.unlock()
                dbgPps += 1
            } else if typ == H264.NAL_IDR {
                dbgIdr += 1
                frameLock.lock()
                let s = spsData
                let p = ppsData
                frameLock.unlock()
                // IDR 前附 config（相同则不重发）
                if !s.isEmpty && !p.isEmpty {
                    var config = Data()
                    config.append(Data([0, 0, 0, 1]))
                    config.append(s)
                    config.append(Data([0, 0, 0, 1]))
                    config.append(p)
                    if config != lastConfigSent {
                        sendPacket(type: H264.TYPE_CONFIG, payload: config)
                        lastConfigSent = config
                    }
                }
                var au = Data([0, 0, 0, 1])
                au.append(nal)
                sendPacket(type: H264.TYPE_FRAME, payload: au)
                frameLock.lock()
                lastFrameData = au
                lastFrameAt = Date()
                frameLock.unlock()
                dbgSent += 1
            } else if H264.VCL_TYPES.contains(typ) {
                dbgP += 1
                var au = Data([0, 0, 0, 1])
                au.append(nal)
                sendPacket(type: H264.TYPE_FRAME, payload: au)
                frameLock.lock()
                lastFrameData = au
                lastFrameAt = Date()
                frameLock.unlock()
                dbgSent += 1
            } else {
                dbgOther += 1
            }
        }
    }

    /// 静止画面保持：avfoundation 屏幕采集是内容驱动的（屏幕无变化就不输出帧），
    /// 若超过 1 秒没有新帧（静止桌面），定时重发最后一帧，保证接收端画面不丢、
    /// 且静止屏幕也能看到画面（重复的完整帧解码无害）。
    private func resendLoop() {
        while running && !stopRequested {
            Thread.sleep(forTimeInterval: 1)
            guard running && !stopRequested else { break }
            guard sock >= 0 else { continue }
            frameLock.lock()
            let data = lastFrameData
            let hasFrame = lastFrameAt > Date(timeIntervalSinceNow: -1.2)
            frameLock.unlock()
            if !data.isEmpty && !hasFrame {
                // 重发 config（接收端可能刚连上/会话重置）+ 最后一帧
                frameLock.lock()
                let s = spsData
                let p = ppsData
                frameLock.unlock()
                if !s.isEmpty && !p.isEmpty {
                    var config = Data()
                    config.append(Data([0, 0, 0, 1]))
                    config.append(s)
                    config.append(Data([0, 0, 0, 1]))
                    config.append(p)
                    if config != lastConfigSent {
                        sendPacket(type: H264.TYPE_CONFIG, payload: config)
                        lastConfigSent = config
                    }
                }
                sendPacket(type: H264.TYPE_FRAME, payload: data)
            }
        }
    }

    // MARK: stderr 解析

    private func stderrLoop(_ pipe: Pipe) {
        let fh = pipe.fileHandleForReading
        let pattern = try? NSRegularExpression(pattern: #"(\d{3,5})x(\d{3,5})"#)
        while running && !stopRequested {
            let chunk = fh.readData(ofLength: 4096)
            if chunk.isEmpty {
                if !running || stopRequested { break }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            if !probed, let pattern {
                let ns = text as NSString
                let range = NSRange(location: 0, length: ns.length)
                if let m = pattern.firstMatch(in: text, options: [], range: range) {
                    let w = Int(ns.substring(with: m.range(at: 1))) ?? 0
                    let h = Int(ns.substring(with: m.range(at: 2))) ?? 0
                    if w >= 640 && h >= 480 {
                        probed = true
                        outW = w
                        outH = h
                    }
                }
            }
            if text.contains("ScreenCaptureKit") || text.contains("Could not create") ||
               text.contains("Input/output error") || text.contains("Video capture") {
                DispatchQueue.main.async {
                    self.onStatus?("⚠️ 屏幕录制失败/无权限：请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许「无线扩展屏」后重试")
                }
            }
        }
    }

    private func heartbeatLoop() {
        while running && !stopRequested {
            Thread.sleep(forTimeInterval: 5)
            if running && !stopRequested {
                sendPacket(type: H264.TYPE_HEARTBEAT, payload: Data())
            }
        }
    }

    /// 被控端：从已建立的 socket 读取反向控制消息（type=4 鼠标 / 5 键盘），
    /// 交给 CtrlExecutor 注入本机（CGEvent）。
    private func ctrlReadLoop() {
        wxDebugLog("ctrlReadLoop: 线程启动")
        while running && !stopRequested {
            // 注意：这里不持 sendLock —— recv 与 send 是 TCP 全双工独立操作；
            // 若发送线程因背压阻塞持锁，会饿死控制消息读取（lavfi 全速测试复现过）
            sendLock.lock()
            let fd = sock
            sendLock.unlock()
            guard fd >= 0 else {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            var head = [UInt8](repeating: 0, count: 5)
            var got = 0
            while got < 5 && running && !stopRequested {
                let n = recv(fd, &head[got], 5 - got, 0)
                if n <= 0 {
                    wxDebugLog("ctrlReadLoop: recv 头返回 n=\(n) errno=\(errno)")
                    break
                }
                got += n
            }
            if got < 5 {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let length = (Int(head[0]) << 24) | (Int(head[1]) << 16) | (Int(head[2]) << 8) | Int(head[3])
            let typ = head[4]
            if length < 0 || length > 64 * 1024 {
                continue
            }
            var payload = [UInt8](repeating: 0, count: length)
            var pg = 0
            while pg < length && running && !stopRequested {
                let n = recv(fd, &payload[pg], length - pg, 0)
                if n <= 0 { break }
                pg += n
            }
            if pg < length { continue }
            if typ == H264.TYPE_MOUSE || typ == H264.TYPE_KEY {
                wxDebugLog("ctrlReadLoop: 收到 type=\(typ) len=\(length)")
                onControl?(typ, Data(payload))
            }
        }
    }

    deinit {
        stopRequested = true
        running = false
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        closeSock()
    }
}
