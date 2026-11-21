import Foundation
import Darwin

// MARK: - 接收服务（TCP 9000，WXESMIRROR 协议）

final class ReceiverService {
    var onStatus: ((String) -> Void)?
    var onStreamInfo: ((_ w: Int, _ h: Int, _ fps: Int) -> Void)?
    var onConfig: ((Data) -> Void)?
    var onAccessUnit: ((Data) -> Void)?
    var onDisconnected: (() -> Void)?

    private(set) var listening = false
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var acceptThread: Thread?
    private var readThread: Thread?
    private var stopFlag = false
    private var clientLock = NSLock()
    private let fpsCounter = FPSCounter()
    private var fpsTimer: Timer?

    func start(port: Int) {
        guard !listening else { return }
        stopFlag = false

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            onStatus?("创建监听 socket 失败")
            return
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        addr.sin_port = in_port_t(port).bigEndian
        var bindResult: Int32 = -1
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bindResult = bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = String(cString: strerror(errno))
            close(fd)
            onStatus?("监听端口 \(port) 失败：\(err)")
            return
        }
        guard listen(fd, 5) == 0 else {
            close(fd)
            onStatus?("listen 失败")
            return
        }

        listenFD = fd
        listening = true
        onStatus?("正在监听 TCP \(port)，等待发射端连接…")

        acceptThread = Thread { [weak self] in
            self?.acceptLoop()
        }
        acceptThread?.name = "wxes-accept"
        acceptThread?.start()

        // 每秒刷新实时帧率
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let f = self.fpsCounter.fps()
            if f > 0.1 {
                self.onStatus?("接收中 · 实时帧率 \(String(format: "%.1f", f)) fps")
            }
        }
        RunLoop.main.add(fpsTimer!, forMode: .common)
    }

    func stop() {
        guard listening else { return }
        stopFlag = true
        listening = false
        fpsTimer?.invalidate()
        fpsTimer = nil
        closeClient()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        // 等待线程退出
        if let t = acceptThread, t.isExecuting { t.cancel() }
        acceptThread = nil
        readThread = nil
        onStatus?("已停止监听")
    }

    private func closeClient() {
        clientLock.lock()
        if clientFD >= 0 {
            close(clientFD)
            clientFD = -1
        }
        clientLock.unlock()
    }

    private func acceptLoop() {
        while !stopFlag {
            var client: Int32 = -1
            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            client = accept(listenFD, &clientAddr, &len)
            if client < 0 {
                if stopFlag { break }
                usleep(200_000)
                continue
            }
            // 只服务一路发射端：新连接替换旧连接
            closeClient()
            clientLock.lock()
            clientFD = client
            clientLock.unlock()
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let accepted = client
            DispatchQueue.main.async {
                self.onStatus?("发射端已连接，等待握手…")
            }
            readThread = Thread { [weak self] in
                self?.readLoop(accepted)
            }
            readThread?.name = "wxes-read"
            readThread?.start()
        }
    }

    /// 发送反向控制消息（操控端：本机鼠标/键盘 -> 发射端被控设备）
    func sendControl(_ type: UInt8, _ payload: Data) {
        clientLock.lock()
        let fd = clientFD
        clientLock.unlock()
        guard fd >= 0 else { return }
        var len = UInt32(payload.count).bigEndian
        var header = Data()
        withUnsafeBytes(of: &len) { header.append(contentsOf: Data($0)) }
        header.append(type)
        header.append(payload)
        var sent = 0
        while sent < header.count {
            let n = header.withUnsafeBytes { ptr -> Int in
                write(fd, ptr.baseAddress!.advanced(by: sent), header.count - sent)
            }
            if n <= 0 { return }
            sent += n
        }
    }

    private func readExact(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var got = 0
        while got < count && !stopFlag {
            let n = recv(fd, buffer.advanced(by: got), count - got, 0)
            if n <= 0 {
                return -1
            }
            got += n
        }
        return got
    }

    private func readLoop(_ fd: Int32) {
        var hs = [UInt8](repeating: 0, count: 16)
        if readExact(fd, &hs, 16) != 16 {
            handleClientClosed(fd)
            return
        }
        guard hs[0..<10].elementsEqual([UInt8](H264.MAGIC)) else {
            handleClientClosed(fd)
            return
        }
        let ver = hs[10]
        let w = (Int(hs[11]) << 8) | Int(hs[12])
        let h = (Int(hs[13]) << 8) | Int(hs[14])
        let fps = Int(hs[15])
        guard ver == 1, w > 0, h > 0 else {
            handleClientClosed(fd)
            return
        }
        fpsCounter.reset()
        DispatchQueue.main.async {
            self.onStreamInfo?(w, h, fps)
            self.onStatus?("发射端已连接：\(w)x\(h)@\(fps)fps · 接收中")
        }

        while !stopFlag {
            var head = [UInt8](repeating: 0, count: 5)
            if readExact(fd, &head, 5) != 5 {
                break
            }
            let length = (Int(head[0]) << 24) | (Int(head[1]) << 16) | (Int(head[2]) << 8) | Int(head[3])
            let typ = head[4]
            if length < 0 || length > 4 * 1024 * 1024 {
                break
            }
            var payload = [UInt8](repeating: 0, count: length)
            if length > 0 && readExact(fd, &payload, length) != length {
                break
            }
            let data = Data(payload)
            switch typ {
            case H264.TYPE_CONFIG:
                NSLog("Receiver: 收到 config %d 字节", data.count)
                DispatchQueue.main.async { self.onConfig?(data) }
            case H264.TYPE_FRAME:
                fpsCounter.tick()
                DispatchQueue.main.async { self.onAccessUnit?(data) }
            case H264.TYPE_HEARTBEAT:
                break
            default:
                break
            }
        }
        handleClientClosed(fd)
    }

    private func handleClientClosed(_ fd: Int32) {
        clientLock.lock()
        if clientFD == fd {
            clientFD = -1
        }
        clientLock.unlock()
        close(fd)
        DispatchQueue.main.async {
            self.onDisconnected?()
            self.onStatus?("发射端已断开，等待重新连接…")
        }
    }
}
