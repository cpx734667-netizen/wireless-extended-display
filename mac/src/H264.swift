import Foundation
import Darwin
import CoreGraphics

// MARK: - H.264 AnnexB / AVCC 工具

enum H264 {
    static let MAGIC = Data("WXESMIRROR".utf8)
    static let TYPE_CONFIG: UInt8 = 1
    static let TYPE_FRAME: UInt8 = 2
    static let TYPE_HEARTBEAT: UInt8 = 3
    static let TYPE_MOUSE: UInt8 = 4
    static let TYPE_KEY: UInt8 = 5
    static let NAL_SPS = 7
    static let NAL_PPS = 8
    static let NAL_IDR = 5
    static let VCL_TYPES: Set<Int> = [1, 2, 3, 4, 5]

    /// 找出所有 AnnexB 起始码位置 (offset, 起始码长度 3 或 4)
    static func startCodePositions(_ data: Data) -> [(offset: Int, length: Int)] {
        var positions: [(Int, Int)] = []
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count - 3 {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    positions.append((i, 3))
                    i += 3
                    continue
                }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    positions.append((i, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }
        return positions
    }

    /// 在字节数组中查找起始码（支持从指定偏移开始扫描，返回绝对偏移）
    static func startCodePositions(_ bytes: [UInt8], from start: Int) -> [(offset: Int, length: Int)] {
        var positions: [(offset: Int, length: Int)] = []
        var i = max(start, 0)
        let n = bytes.count
        while i < n - 3 {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                positions.append((i, 3))
                i += 3
            } else if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                positions.append((i, 4))
                i += 4
            } else {
                i += 1
            }
        }
        return positions
    }

    /// 将 AnnexB 数据切分为 NAL（不含起始码）
    static func splitNALs(_ data: Data) -> [Data] {
        let positions = startCodePositions(data)
        guard !positions.isEmpty else { return [] }
        var nals: [Data] = []
        for k in 0..<(positions.count - 1) {
            let s = positions[k].offset + positions[k].length
            let e = positions[k + 1].offset
            if e > s {
                nals.append(data.subdata(in: s..<e))
            }
        }
        // 最后一个起始码之后的内容（单 NAL 帧也在这里返回）
        let last = positions[positions.count - 1]
        let s = last.offset + last.length
        if s < data.count {
            nals.append(data.subdata(in: s..<data.count))
        }
        return nals
    }

    /// AnnexB -> AVCC（每个 NAL 前加 4 字节大端长度）
    static func annexbToAvcc(_ annexb: Data) -> Data {
        var out = Data()
        for nal in splitNALs(annexb) {
            var len = UInt32(nal.count).bigEndian
            out.append(contentsOf: withUnsafeBytes(of: &len) { Data($0) })
            out.append(nal)
        }
        return out
    }

    static func nalType(_ nal: Data) -> Int {
        guard let first = nal.first else { return 0 }
        return Int(first & 0x1F)
    }
}

// MARK: - 帧率统计

final class FPSCounter {
    private var timestamps: [TimeInterval] = []
    private let lock = NSLock()

    func tick() {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        timestamps.append(now)
        timestamps = timestamps.filter { now - $0 < 2.0 }
    }

    func fps() -> Double {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        timestamps = timestamps.filter { now - $0 < 2.0 }
        guard timestamps.count > 1, let first = timestamps.first else { return 0 }
        let span = now - first
        return span > 0 ? Double(timestamps.count - 1) / span : 0
    }

    func reset() {
        lock.lock()
        timestamps.removeAll()
        lock.unlock()
    }
}

// MARK: - 本机 IP

func localIPv4Addresses() -> [String] {
    var result: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return result }
    var ptr = ifaddr
    while ptr != nil {
        let interface = ptr!.pointee
        let family = interface.ifa_addr.pointee.sa_family
        if family == UInt8(AF_INET) {
            let name = String(cString: interface.ifa_name)
            if name.hasPrefix("en") || name.hasPrefix("bridge") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let saLen = socklen_t(interface.ifa_addr.pointee.sa_len)
                if getnameinfo(interface.ifa_addr, saLen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254") && !ip.hasPrefix("0.") {
                        result.append("\(name): \(ip)")
                    }
                }
            }
        }
        ptr = ptr!.pointee.ifa_next
    }
    freeifaddrs(ifaddr)
    return result
}

// MARK: - 屏幕录制权限

func screenCapturePermissionGranted() -> Bool {
    return CGPreflightScreenCaptureAccess()
}
