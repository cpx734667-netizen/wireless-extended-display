import AppKit
import CoreImage

// MARK: - 视频显示视图

enum DisplayMode: Int {
    case fit = 0        // 原始比例
    case stretch = 1    // 拉伸填充
    case customAspect = 2 // 自定义比例
}

final class VideoDisplayView: NSView {
    let displayLayer = CALayer()
    private let hintLayer = CATextLayer()
    private var imageAspect: CGFloat = 16.0 / 9.0
    var mode: DisplayMode = .fit
    var customAspect: CGFloat = 16.0 / 9.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(displayLayer)

        hintLayer.string = "等待发射端连接…\n\n安卓 / Windows / 另一台 Mac 的发射端\n将目标 IP 填为下方本机 IP，端口 9000"
        hintLayer.fontSize = 15
        hintLayer.alignmentMode = .center
        hintLayer.foregroundColor = NSColor(white: 0.55, alpha: 1).cgColor
        hintLayer.contentsScale = 2
        hintLayer.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        hintLayer.isHidden = false
        layer?.addSublayer(hintLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSourceAspect(_ w: Int, _ h: Int) {
        if w > 0 && h > 0 {
            imageAspect = CGFloat(w) / CGFloat(h)
        }
        updateFrame()
    }

    func showImage(_ cg: CGImage) {
        displayLayer.contents = cg
        hintLayer.isHidden = true
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func showHint() {
        displayLayer.contents = nil
        hintLayer.isHidden = false
    }

    override func layout() {
        super.layout()
        hintLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        updateFrame()
    }

    func updateFrame() {
        let b = bounds
        guard b.width > 1, b.height > 1 else { return }
        switch mode {
        case .stretch:
            displayLayer.frame = b
            displayLayer.contentsGravity = .resize
        case .fit:
            let aspect = imageAspect
            var w = b.width
            var h = w / aspect
            if h > b.height {
                h = b.height
                w = h * aspect
            }
            displayLayer.frame = NSRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
            displayLayer.contentsGravity = .resizeAspect
        case .customAspect:
            let aspect = customAspect > 0 ? customAspect : imageAspect
            var w = b.width
            var h = w / aspect
            if h > b.height {
                h = b.height
                w = h * aspect
            }
            displayLayer.frame = NSRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
            displayLayer.contentsGravity = .resizeAspect
        }
    }
}

// MARK: - 主窗口控制器

final class MainViewController: NSViewController {
    private let receiver = ReceiverService()
    private let sender = ScreenSender()
    private let decoder = H264Decoder()
    private let ciContext = CIContext()

    // 接收面板控件
    private let segControl = NSSegmentedControl(labels: ["接收投屏", "发送投屏"], trackingMode: .selectOne, target: nil, action: nil)
    private let receivePane = NSView()
    private let sendPane = NSView()
    private let ipLabel = NSTextField(labelWithString: "")
    private let recvStatusLabel = NSTextField(labelWithString: "正在启动监听…")
    private let streamInfoLabel = NSTextField(labelWithString: "无信号")
    private let videoView = VideoDisplayView(frame: .zero)
    private let modePopup = NSPopUpButton()
    private let aspectPopup = NSPopUpButton()
    private let btnFullscreen = NSButton(title: "全屏", target: nil, action: nil)
    private let btnCtrl = NSButton(title: "反向控制：关", target: nil, action: nil)
    private let ctrlStatusLabel = NSTextField(labelWithString: "")

    // 发送面板控件
    private let targetIPField = NSTextField(string: "")
    private let targetPortField = NSTextField(string: "9000")
    private let screenPopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let customWidthField = NSTextField(string: "1280")
    private let customHeightField = NSTextField(string: "720")
    private let fpsPopup = NSPopUpButton()
    private let bitrateSlider = NSSlider(value: 4000, minValue: 500, maxValue: 20000, target: nil, action: nil)
    private let bitrateLabel = NSTextField(labelWithString: "4000 kbps")
    private let btnStartSend = NSButton(title: "开始投屏", target: nil, action: nil)
    private let btnStopSend = NSButton(title: "停止", target: nil, action: nil)
    private let btnSlave = NSButton(title: "被控制：关", target: nil, action: nil)
    private let sendStatusLabel = NSTextField(labelWithString: "未投屏")
    private let permButton = NSButton(title: "检查屏幕录制权限", target: nil, action: nil)

    private var isSending = false
    private var currentStream = false
    private var renderCount = 0

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 760))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        buildUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupReceiver()
        refreshLocalIPs()
    }

    // MARK: UI 构建

    private func buildUI() {
        let seg = segControl
        seg.selectedSegment = 0
        seg.target = self
        seg.action = #selector(segmentChanged(_:))
        seg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(seg)

        receivePane.translatesAutoresizingMaskIntoConstraints = false
        sendPane.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(receivePane)
        view.addSubview(sendPane)

        NSLayoutConstraint.activate([
            seg.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            seg.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            seg.widthAnchor.constraint(equalToConstant: 300),

            receivePane.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 12),
            receivePane.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            receivePane.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            receivePane.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            sendPane.topAnchor.constraint(equalTo: seg.bottomAnchor, constant: 12),
            sendPane.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sendPane.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            sendPane.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        sendPane.isHidden = true

        buildReceivePane()
        buildSendPane()
    }

    private func buildReceivePane() {
        let infoRow = NSStackView()
        infoRow.orientation = .horizontal
        infoRow.spacing = 12
        ipLabel.font = .systemFont(ofSize: 13)
        ipLabel.textColor = .secondaryLabelColor
        recvStatusLabel.font = .systemFont(ofSize: 13)
        recvStatusLabel.textColor = .systemBlue
        infoRow.addArrangedSubview(ipLabel)
        infoRow.addArrangedSubview(recvStatusLabel)
        infoRow.addArrangedSubview(NSView())  // 弹性空间

        videoView.translatesAutoresizingMaskIntoConstraints = false

        let ctrlRow = NSStackView()
        ctrlRow.orientation = .horizontal
        ctrlRow.spacing = 10

        let modeLabel = NSTextField(labelWithString: "显示模式")
        modeLabel.font = .systemFont(ofSize: 12)
        modeLabel.textColor = .secondaryLabelColor
        modePopup.addItems(withTitles: ["原始比例", "拉伸填充", "自定义比例"])
        modePopup.selectItem(at: 0)
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))

        let aspectLabel = NSTextField(labelWithString: "画幅比例")
        aspectLabel.font = .systemFont(ofSize: 12)
        aspectLabel.textColor = .secondaryLabelColor
        aspectPopup.addItems(withTitles: ["原始", "16:9", "4:3", "21:9", "1:1"])
        aspectPopup.selectItem(at: 1)
        aspectPopup.target = self
        aspectPopup.action = #selector(aspectChanged(_:))
        aspectPopup.isEnabled = false

        btnFullscreen.target = self
        btnFullscreen.action = #selector(toggleFullscreen(_:))
        btnFullscreen.bezelStyle = .rounded

        btnCtrl.target = self
        btnCtrl.action = #selector(toggleCtrl(_:))
        btnCtrl.bezelStyle = .rounded
        btnCtrl.isEnabled = false
        ctrlStatusLabel.font = .systemFont(ofSize: 12)
        ctrlStatusLabel.textColor = .systemOrange
        ctrlStatusLabel.maximumNumberOfLines = 2
        ctrlStatusLabel.lineBreakMode = .byWordWrapping

        streamInfoLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        streamInfoLabel.textColor = .secondaryLabelColor

        ctrlRow.addArrangedSubview(modeLabel)
        ctrlRow.addArrangedSubview(modePopup)
        ctrlRow.addArrangedSubview(aspectLabel)
        ctrlRow.addArrangedSubview(aspectPopup)
        ctrlRow.addArrangedSubview(btnCtrl)
        ctrlRow.addArrangedSubview(NSView())
        ctrlRow.addArrangedSubview(streamInfoLabel)
        ctrlRow.addArrangedSubview(btnFullscreen)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .width
        stack.addArrangedSubview(infoRow)
        stack.addArrangedSubview(videoView)
        stack.addArrangedSubview(ctrlRow)
        stack.addArrangedSubview(ctrlStatusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        receivePane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: receivePane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: receivePane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: receivePane.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: receivePane.bottomAnchor),
        ])
    }

    private func buildSendPane() {
        let form = NSGridView(views: [
            [NSTextField(labelWithString: "目标设备 IP"), targetIPField],
            [NSTextField(labelWithString: "端口"), targetPortField],
            [NSTextField(labelWithString: "投屏屏幕"), screenPopup],
            [NSTextField(labelWithString: "分辨率"), resolutionPopup],
            [NSTextField(labelWithString: "自定义宽×高"), customWidthField],
            [NSTextField(labelWithString: ""), customHeightField],
            [NSTextField(labelWithString: "帧率"), fpsPopup],
            [NSTextField(labelWithString: "码率"), bitrateSlider],
            [NSTextField(labelWithString: ""), bitrateLabel],
        ])
        form.columnSpacing = 12
        form.rowSpacing = 10
        form.row(at: 4).isHidden = true   // 自定义宽
        form.row(at: 5).isHidden = true   // 自定义高

        targetIPField.placeholderString = "如 192.168.1.100"
        targetPortField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        customWidthField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        customHeightField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        // 屏幕列表
        screenPopup.removeAllItems()
        let screens = NSScreen.screens
        if screens.isEmpty {
            screenPopup.addItem(withTitle: "主显示器")
        } else {
            for (i, s) in screens.enumerated() {
                let frame = s.frame
                let name = i == 0 ? "主显示器" : "显示器 \(i + 1)"
                screenPopup.addItem(withTitle: "\(name) (\(Int(frame.width))×\(Int(frame.height)))")
            }
        }

        // 分辨率
        resolutionPopup.addItems(withTitles: ["原始分辨率", "1280×720", "640×360", "自定义"])
        resolutionPopup.selectItem(at: 0)
        resolutionPopup.target = self
        resolutionPopup.action = #selector(resolutionChanged(_:))

        // 帧率
        fpsPopup.addItems(withTitles: ["5 fps", "10 fps", "15 fps", "24 fps", "30 fps", "60 fps"])
        fpsPopup.selectItem(at: 2)

        // 码率
        bitrateSlider.isContinuous = true
        bitrateSlider.target = self
        bitrateSlider.action = #selector(bitrateChanged(_:))

        btnStartSend.target = self
        btnStartSend.action = #selector(startSend(_:))
        btnStopSend.target = self
        btnStopSend.action = #selector(stopSend(_:))
        btnStopSend.isEnabled = false
        btnSlave.target = self
        btnSlave.action = #selector(toggleSlave(_:))
        btnSlave.bezelStyle = .rounded
        btnSlave.isEnabled = false
        permButton.bezelStyle = .rounded
        permButton.target = self
        permButton.action = #selector(checkPermission(_:))

        sendStatusLabel.font = .systemFont(ofSize: 13)
        sendStatusLabel.textColor = .systemBlue
        sendStatusLabel.maximumNumberOfLines = 3
        sendStatusLabel.lineBreakMode = .byWordWrapping

        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 10
        btnRow.addArrangedSubview(btnStartSend)
        btnRow.addArrangedSubview(btnStopSend)
        btnRow.addArrangedSubview(btnSlave)
        btnRow.addArrangedSubview(permButton)

        let tip = NSTextField(wrappingLabelWithString: "说明：首次投屏会请求「屏幕录制」权限，请允许；发射端与接收端需在同一局域网。接收端（本机）地址见上方「接收投屏」页。「被控制」开启后，接收端（安卓 v1.6 反控版 / Windows / 另一台 Mac）可在看到画面的同时控制本机鼠标键盘。")
        tip.font = .systemFont(ofSize: 12)
        tip.textColor = .tertiaryLabelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        stack.addArrangedSubview(form)
        stack.addArrangedSubview(btnRow)
        stack.addArrangedSubview(sendStatusLabel)
        stack.addArrangedSubview(tip)
        stack.translatesAutoresizingMaskIntoConstraints = false
        sendPane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sendPane.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: sendPane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: sendPane.trailingAnchor),
        ])
    }

    // MARK: 接收逻辑

    private func setupReceiver() {
        receiver.onStatus = { [weak self] text in
            self?.recvStatusLabel.stringValue = text
        }
        receiver.onStreamInfo = { [weak self] w, h, fps in
            self?.currentStream = true
            self?.videoView.setSourceAspect(w, h)
            self?.streamInfoLabel.stringValue = "源 \(w)×\(h)@\(fps)fps"
            self?.btnCtrl.isEnabled = true
            self?.ctrlStatusLabel.stringValue = "已连接：可开启「反向控制」用本机鼠标/键盘操控对方"
        }
        receiver.onConfig = { [weak self] config in
            self?.decoder.applyConfig(config)
        }
        receiver.onAccessUnit = { [weak self] au in
            self?.decoder.decode(au)
        }
        receiver.onDisconnected = { [weak self] in
            self?.currentStream = false
            self?.streamInfoLabel.stringValue = "无信号"
            self?.videoView.showHint()
            self?.btnCtrl.isEnabled = false
            self?.ctrlStatusLabel.stringValue = ""
            if self?.ctrlOn == true {
                self?.ctrlOn = false
                self?.btnCtrl.title = "反向控制：关"
                CtrlSender.shared.stop()
            }
        }
        decoder.onFrame = { [weak self] pixelBuffer in
            DispatchQueue.main.async {
                guard let self else { return }
                if let cg = self.makeCGImage(from: pixelBuffer) {
                    self.videoView.showImage(cg)
                    self.renderCount += 1
                    if self.renderCount % 30 == 1 {
                        wxDebugLog("UI: 已渲染 \(self.renderCount) 帧")
                    }
                } else {
                    wxDebugLog("UI: makeCGImage 返回 nil")
                }
            }
        }
        receiver.start(port: 9000)
    }

    private func makeCGImage(from pb: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pb)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    private func refreshLocalIPs() {
        let ips = localIPv4Addresses()
        if ips.isEmpty {
            ipLabel.stringValue = "本机 IP：未连接网络"
        } else {
            ipLabel.stringValue = "本机 IP：\(ips.joined(separator: "  "))"
        }
    }

    // MARK: 发送逻辑

    @objc private func startSend(_ sender: Any?) {
        guard !isSending else { return }
        let ip = targetIPField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else {
            sendStatusLabel.stringValue = "请填写目标设备 IP"
            return
        }
        let port = Int(targetPortField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 9000

        let fps = [5, 10, 15, 24, 30, 60][max(0, min(fpsPopup.indexOfSelectedItem, 5))]
        let bitrate = Int(bitrateSlider.doubleValue)

        var width: Int? = nil
        var height: Int? = nil
        switch resolutionPopup.indexOfSelectedItem {
        case 1:
            width = 1280; height = 720
        case 2:
            width = 640; height = 360
        case 3:
            width = Int(customWidthField.stringValue) ?? 0
            height = Int(customHeightField.stringValue) ?? 0
            if width == 0 || height == 0 {
                sendStatusLabel.stringValue = "自定义分辨率宽高需为数字"
                return
            }
        default:
            break
        }

        // avfoundation 按设备名采集（数字索引会被 iPhone 连续互通相机动态占用）
        let screenName = "Capture screen \(max(0, screenPopup.indexOfSelectedItem))"

        if !screenCapturePermissionGranted() {
            sendStatusLabel.stringValue = "⚠️ 未授予屏幕录制权限：点下方「检查屏幕录制权限」授权后重试"
            CGRequestScreenCaptureAccess()
        }

        self.sender.onStatus = { [weak self] text in
            self?.sendStatusLabel.stringValue = text
        }
        self.sender.onControl = { [weak self] type, payload in
            // 被控端：控制消息 -> 注入本机（CGEvent）
            CtrlExecutor.shared.handle(type, payload)
        }
        self.sender.start(ip: ip, port: port, fps: fps, bitrateKbps: bitrate, width: width, height: height, screenName: screenName)
        isSending = true
        btnStartSend.isEnabled = false
        btnStopSend.isEnabled = true
        btnSlave.isEnabled = true
        // 被控坐标基准：本机主屏
        let b = CGDisplayBounds(CGMainDisplayID())
        CtrlExecutor.shared.setScreenSize(b.width, b.height)
    }

    @objc private func stopSend(_ sender: Any?) {
        self.sender.stop()
        isSending = false
        btnStartSend.isEnabled = true
        btnStopSend.isEnabled = false
        btnSlave.isEnabled = false
        slaveOn = false
        btnSlave.title = "被控制：关"
    }

    // MARK: 反向控制（操控端）/ 被控制

    private var ctrlOn = false
    private var slaveOn = false

    @objc private func toggleCtrl(_ sender: Any?) {
        ctrlOn.toggle()
        btnCtrl.title = ctrlOn ? "反向控制：开" : "反向控制：关"
        if ctrlOn {
            CtrlSender.shared.onSend = { [weak self] type, payload in
                self?.receiver.sendControl(type, payload)
            }
            CtrlSender.shared.onState = { [weak self] text in
                DispatchQueue.main.async { self?.ctrlStatusLabel.stringValue = text }
            }
            CtrlSender.shared.start()
        } else {
            CtrlSender.shared.stop()
            ctrlStatusLabel.stringValue = "反向控制已关闭"
        }
    }

    @objc private func toggleSlave(_ sender: Any?) {
        guard isSending else { return }
        slaveOn.toggle()
        btnSlave.title = slaveOn ? "被控制：开" : "被控制：关"
        if slaveOn {
            if !accessibilityTrusted() {
                sendStatusLabel.stringValue = "⚠️ 未授予「辅助功能」权限：请在 系统设置 → 隐私与安全性 → 辅助功能 中允许「无线扩展屏」，重启 App 后生效"
                requestAccessibility()
            } else {
                sendStatusLabel.stringValue = "被控制已开启：接收端可控制本机鼠标键盘"
            }
        } else {
            sendStatusLabel.stringValue = "被控制已关闭"
        }
    }

    @objc private func checkPermission(_ sender: Any?) {
        if screenCapturePermissionGranted() {
            sendStatusLabel.stringValue = "✓ 屏幕录制权限已授予"
        } else {
            CGRequestScreenCaptureAccess()
            if !screenCapturePermissionGranted() {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
                sendStatusLabel.stringValue = "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许「无线扩展屏」，然后重新点「开始投屏」"
            } else {
                sendStatusLabel.stringValue = "✓ 屏幕录制权限已授予"
            }
        }
    }

    // MARK: 事件

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        receivePane.isHidden = idx != 0
        sendPane.isHidden = idx == 0
        refreshLocalIPs()
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        videoView.mode = DisplayMode(rawValue: sender.indexOfSelectedItem) ?? .fit
        aspectPopup.isEnabled = (sender.indexOfSelectedItem == 2)
        videoView.updateFrame()
    }

    @objc private func aspectChanged(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 0: videoView.customAspect = 0  // 原始
        case 1: videoView.customAspect = 16.0 / 9.0
        case 2: videoView.customAspect = 4.0 / 3.0
        case 3: videoView.customAspect = 21.0 / 9.0
        case 4: videoView.customAspect = 1.0
        default: break
        }
        videoView.updateFrame()
    }

    @objc private func toggleFullscreen(_ sender: Any?) {
        view.window?.toggleFullScreen(nil)
    }

    @objc private func resolutionChanged(_ sender: NSPopUpButton) {
        let custom = sender.indexOfSelectedItem == 3
        let grid = sendPane.subviews.first?.subviews.first as? NSGridView
        grid?.row(at: 4).isHidden = !custom
        grid?.row(at: 5).isHidden = !custom
    }

    @objc private func bitrateChanged(_ sender: NSSlider) {
        bitrateLabel.stringValue = "\(Int(sender.doubleValue)) kbps"
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var mainVC: MainViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainVC = MainViewController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "无线扩展屏"
        window.minSize = NSSize(width: 820, height: 620)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = mainVC
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.setFrameAutosaveName("MainWindow")
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
