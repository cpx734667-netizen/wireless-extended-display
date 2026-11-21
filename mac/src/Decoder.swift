import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

// MARK: - 调试日志（写文件，便于未连接控制台时排查）
// 注意：全局锁 + 复用句柄，避免多线程（readLoop/ctrlReadLoop/Decoder）并发写互相覆盖

private let wxLogLock = NSLock()
private var wxLogHandle: FileHandle? = {
    FileManager.default.createFile(atPath: "/tmp/wxes_debug.log", contents: nil)
    return try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/wxes_debug.log"))
}()

func wxDebugLog(_ s: String) {
    let line = "[\(Date())] \(s)\n"
    guard let d = line.data(using: .utf8) else { return }
    wxLogLock.lock()
    defer { wxLogLock.unlock() }
    if let fh = wxLogHandle {
        fh.seekToEndOfFile()
        fh.write(d)
    } else {
        try? line.write(to: URL(fileURLWithPath: "/tmp/wxes_debug.log"), atomically: true, encoding: .utf8)
    }
}

// MARK: - 全局解码输出回调（C 函数指针，避免闭包转换不确定性）

private let h264OutputCallback: VTDecompressionOutputCallback = { callbackRef, _, status, _, imageBuffer, _, _ in
    guard let callbackRef, status == noErr, let imageBuffer else {
        if let callbackRef {
            wxDebugLog("h264OutputCallback: 触发但 status=\(status)")
        }
        return
    }
    let decoder = Unmanaged<H264Decoder>.fromOpaque(callbackRef).takeUnretainedValue()
    decoder.onFrame?(imageBuffer)
}

// MARK: - H.264 解码器（VideoToolbox）

final class H264Decoder {
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private let stateLock = NSLock()
    private let decodeQueue = DispatchQueue(label: "com.wxes.decode")
    private var decodedCount = 0
    private var frameIndex = 0

    /// 应用 SPS/PPS 配置（AnnexB 格式，可能包含多个 NAL）
    func applyConfig(_ annexb: Data) {
        let nals = H264.splitNALs(annexb)
        var spsData: Data?
        var ppsData: Data?
        for nal in nals {
            switch H264.nalType(nal) {
            case 7: if spsData == nil { spsData = nal }
            case 8: if ppsData == nil { ppsData = nal }
            default: break
            }
        }
        guard let sps = spsData, let pps = ppsData else {
            wxDebugLog("applyConfig: 未找到 SPS/PPS，NAL 数=\(nals.count)")
            return
        }

        stateLock.lock()
        if self.sps == sps && self.pps == pps && session != nil {
            // 配置未变化：无需重建会话（发送端每个 IDR 都会重发 config）
            stateLock.unlock()
            return
        }
        self.sps = sps
        self.pps = pps
        stateLock.unlock()

        var desc: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                var paramSetPointers: [UnsafePointer<UInt8>] = [
                    spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                var paramSetSizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &paramSetPointers,
                    parameterSetSizes: &paramSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc)
            }
        }
        guard status == noErr, let desc else {
            wxDebugLog("applyConfig: 格式描述创建失败 status=\(status)")
            return
        }

        stateLock.lock()
        self.formatDescription = desc
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        stateLock.unlock()

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: h264OutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())

        var sessionOut: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey: true
            ] as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &sessionOut)
        guard createStatus == noErr, let sessionOut else {
            wxDebugLog("applyConfig: 解码会话创建失败 status=\(createStatus)")
            return
        }
        stateLock.lock()
        self.session = sessionOut
        frameIndex = 0
        stateLock.unlock()
        wxDebugLog("applyConfig: 解码会话就绪 (SPS \(sps.count) 字节, PPS \(pps.count) 字节)")
    }

    /// 解码一个访问单元（AnnexB）
    func decode(_ accessUnit: Data) {
        let avcc = H264.annexbToAvcc(accessUnit)
        guard !avcc.isEmpty else { return }
        stateLock.lock()
        let session = self.session
        let formatDescription = self.formatDescription
        let ptsIndex = self.frameIndex
        self.frameIndex += 1
        stateLock.unlock()
        guard let session, let formatDescription else { return }

        decodeQueue.async {
            var blockBuffer: CMBlockBuffer?
            var src = CMBlockBufferCustomBlockSource(
                version: 0,
                AllocateBlock: nil,
                FreeBlock: { _, memoryBlock, _ in
                    free(memoryBlock)
                },
                refCon: nil)
            let mem = malloc(avcc.count)!
            avcc.copyBytes(to: mem.assumingMemoryBound(to: UInt8.self), count: avcc.count)
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: mem,
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: &src,
                offsetToData: 0,
                dataLength: avcc.count,
                flags: 0,
                blockBufferOut: &blockBuffer)
            guard status == kCMBlockBufferNoErr, let blockBuffer else { return }

            var sampleBuffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(value: CMTimeValue(ptsIndex), timescale: 30),
                decodeTimeStamp: .invalid)
            var sampleSizes = avcc.count
            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSizes,
                sampleBufferOut: &sampleBuffer)
            guard status == noErr, let sampleBuffer else { return }

            var flags: VTDecodeInfoFlags = []
            status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], frameRefcon: nil, infoFlagsOut: &flags)
            if status != noErr {
                wxDebugLog("decode: 失败 status=\(status) avcc=\(avcc.count)字节")
            } else {
                self.decodedCount += 1
                if self.decodedCount % 15 == 1 {
                    wxDebugLog("decode: 已提交 \(self.decodedCount) 帧")
                }
            }
        }
    }

    func reset() {
        stateLock.lock()
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        sps = nil
        pps = nil
        stateLock.unlock()
    }

    deinit {
        reset()
    }
}
