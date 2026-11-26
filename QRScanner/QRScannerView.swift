//
//  QRScannerView.swift
//  QRScanner
//
//  Created by 史冬亮 on 2026/8/14.
//

import UIKit
import AVFoundation
import AudioToolbox
import Vision

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let torchStateDidChangeNotification = Notification.Name("QRScannerViewController.torchStateDidChange")
    var onScan: ((String, String) -> Void)?
    var onPhotoCaptured: ((UIImage) -> Void)?
    var onPhotoCaptureFailed: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var photoOutput: AVCapturePhotoOutput?
    private var hasScanned = false
    private var lastScanTime: Date?
    private let scanCooldown: TimeInterval = 1.5
    private var device: AVCaptureDevice?
    private var pendingWatermarkContent: String?
    /// 用户当前想要的手电筒状态（用于停工/换镜头/拍照后把状态与 UI 对齐）
    private var desiredTorchOn = false

    // MARK: - Vision 条形码兜底识别
    /// 条形码（尤其细窄、弯曲、反光的一维码）用系统元数据输出经常读不出，
    /// 这里额外挂一路视频帧，用 Vision 在帧上找码，作为第二道识别通道
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private let frameQueue = DispatchQueue(label: "com.shidongliang.qrscanner.frames", qos: .userInitiated)
    private var lastVisionDate = Date.distantPast
    private let visionInterval: TimeInterval = 0.35

    // MARK: - 镜头切换相关
    /// 当前生效的相机输入（切换镜头时用于移除旧输入）
    private var currentVideoInput: AVCaptureDeviceInput?
    /// 后置镜头组：标题（0.5x/1x/3x…）、设备、相对广角的倍率，按倍率升序
    private var rearLenses: [(title: String, device: AVCaptureDevice, zoom: CGFloat)] = []
    private var currentRearIndex = 0
    /// 镜头列表/选中项发生变化时回调给 SwiftUI
    var onLensesChanged: (([String], Int) -> Void)?
    /// 串行化会话重配置，避免多次快速切换互相打断
    private let sessionQueue = DispatchQueue(label: "com.shidongliang.qrscanner.session", qos: .userInitiated)

    // MARK: - 手动对焦
    /// 是否处于手动对焦模式（true 时点按对焦失效，由滑杆控制）
    private var isManualFocus = false
    /// 手动焦距 0（最近）~ 1（无穷远）
    private var manualFocusPosition: Float = 0.5
    private var focusApplyWorkItem: DispatchWorkItem?

    /// 当前设备是否支持自定义焦距锁定（绝大多数 iPhone 支持，少数外接/老设备不支持）
    var supportsManualFocus: Bool {
        device?.isLockingFocusWithCustomLensPositionSupported ?? false
    }

    // MARK: - 微距
    /// 是否处于微距模式（占用超广角，焦距锁到最近，放大到接近 1x 视野）
    private var isMacroMode = false
    private var macroReturnIndex = 0
    private var macroReturnManualFocus = false
    private var macroReturnFocusPosition: Float = 0.5
    /// 微距状态变化：(是否微距, 是否手动对焦, 手动焦距)
    var onMacroStateChanged: ((Bool, Bool, Float) -> Void)?

    /// 是否有超广角可以拍微距（超广角最近对焦距离约 2cm，主摄一般 10–15cm）
    var hasMacroLens: Bool {
        rearLenses.contains { $0.zoom < 0.9 }
    }

    private let allSymbologies: [AVMetadataObject.ObjectType] = {
        var types: [AVMetadataObject.ObjectType] = [
            .qr, .aztec, .pdf417, .dataMatrix,
            .ean8, .ean13, .upce,
            .code39, .code39Mod43, .code93, .code128,
            .interleaved2of5, .itf14
        ]
        if #available(iOS 15.0, *) {
            types.append(contentsOf: [.gs1DataBar, .gs1DataBarLimited, .gs1DataBarExpanded])
        }
        return types
    }()

    private let scanLock = NSLock()

    /// 扫码回调队列：旧实现把元数据回调放在主线程，连续识别时会占满主线程，
    /// 导致点按对焦手势响应延迟甚至“点了没反应”，这里改为独立串行队列
    private let videoQueue = DispatchQueue(label: "com.shidongliang.qrscanner.metadata", qos: .userInitiated)

    /// 点按对焦时显示的黄色对焦框（也是用户判断“点按是否生效”的唯一视觉反馈）
    private lazy var focusReticle: UIView = {
        let v = UIView()
        v.layer.borderColor = UIColor.systemYellow.cgColor
        v.layer.borderWidth = 1.5
        v.layer.cornerRadius = 6
        v.isUserInteractionEnabled = false
        v.alpha = 0
        return v
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        checkPermission()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appDidEnterBackground() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.stopRunning()
        }
        setTorch(on: false)
    }

    @objc private func appWillEnterForeground() {
        scanLock.lock()
        let shouldStart = !hasScanned
        scanLock.unlock()

        if shouldStart {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession?.startRunning()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        scanLock.lock()
        hasScanned = false
        scanLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if self?.captureSession?.isRunning == false {
                self?.captureSession?.startRunning()
                // Session 重启会把灯关掉，用户此前开着灯则补回来
                if self?.desiredTorchOn == true {
                    self?.setTorch(on: true)
                }
            }
        }
    }

    /// 手动拍照时调用：暂停扫码识别，但相机继续运行（拍照需要 Session 处于运行状态）。
    /// 与 pauseCapture 的区别：后者停掉取景，用于预览期间省电；前者只锁定识别标记。
    func pauseScanning() {
        scanLock.lock()
        hasScanned = true
        scanLock.unlock()
    }

    // MARK: - 暂停取景（用于照片预览期间省电、降温）
    func pauseCapture() {
        // 停掉 Session 时系统会强制把手电筒关掉，这里同步状态并通知 UI，
        // 否则按钮会一直停留在“关闭”字样，而灯其实已经灭了
        if desiredTorchOn {
            setTorch(on: false)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.stopRunning()
        }
    }

    func resetScan() {
        scanLock.lock()
        hasScanned = false
        scanLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if self?.captureSession?.isRunning == false {
                self?.captureSession?.startRunning()
            }
        }
    }

    func updateSessionPreset() {
        guard let session = captureSession else { return }
        let newPreset = SettingsManager.shared.photoQuality.sessionPreset
        guard session.sessionPreset != newPreset else { return }
        guard session.canSetSessionPreset(newPreset) else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            session.stopRunning()
            session.beginConfiguration()
            session.sessionPreset = newPreset
            session.commitConfiguration()
            // 预设改变后同一台设备支持的码制会变（低分辨率流往往不支持 GS1 DataBar 等），
            // 必须重算交集，否则会残留无效类型导致整批码制设置失败
            if let metadata = session.outputs.compactMap({ $0 as? AVCaptureMetadataOutput }).first,
               let self = self {
                let supported = metadata.availableMetadataObjectTypes
                metadata.metadataObjectTypes = self.allSymbologies.filter { supported.contains($0) }
            }
            self?.scanLock.lock()
            let shouldStart = !(self?.hasScanned ?? true)
            self?.scanLock.unlock()
            if shouldStart {
                session.startRunning()
            }
        }
    }

    // MARK: - 重新初始化（启动失败兜底）
    func restartCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if captureSession == nil {
                setupCamera()
            } else if let session = captureSession, !session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
            }
        default:
            checkPermission()
        }
    }

    // MARK: - 镜头切换（后置多档）
    /// 选择某个后置档位（0.5x / 1x / 2x / 3x）
    func selectRearLens(index: Int) {
        guard index >= 0, index < rearLenses.count else { return }
        let target = rearLenses[index].device
        // 手动选档位视为退出微距（微距会占用超广角并放大）
        if isMacroMode {
            isMacroMode = false
            DispatchQueue.main.async { [weak self] in
                self?.onMacroStateChanged?(false, self?.isManualFocus ?? false, self?.manualFocusPosition ?? 0.5)
            }
        }
        currentRearIndex = index
        if target != device {
            switchCamera(to: target)
        } else {
            // 已经在该档位，只需同步 UI 选中态
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onLensesChanged?(self.rearLenses.map { $0.title }, index)
            }
        }
    }

    /// 重建相机输入：移除旧 input → 添加新 input → 重新求可用码制交集
    /// completion 在会话配置完成后回调，参数为真正生效的设备（失败时可能是回滚的原设备）
    private func switchCamera(to newDevice: AVCaptureDevice, completion: ((AVCaptureDevice) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self = self, let session = self.captureSession else { return }
            let previousDevice = self.device

            session.beginConfiguration()
            if let oldInput = self.currentVideoInput {
                session.removeInput(oldInput)
                self.currentVideoInput = nil
            }

            var applied = false
            do {
                let input = try AVCaptureDeviceInput(device: newDevice)
                if session.canAddInput(input) {
                    session.addInput(input)
                    self.currentVideoInput = input
                    applied = true
                }
            } catch {
                print("切换镜头失败: \(error.localizedDescription)")
            }

            // 新镜头加不进去时回滚到原设备，避免出现黑屏
            if !applied, let previous = previousDevice,
               let fallback = try? AVCaptureDeviceInput(device: previous),
               session.canAddInput(fallback) {
                session.addInput(fallback)
                self.currentVideoInput = fallback
            }

            // 换设备后支持的码制可能变化（前置常缺一维码），重新求交集
            if let metadata = session.outputs.compactMap({ $0 as? AVCaptureMetadataOutput }).first {
                let supported = metadata.availableMetadataObjectTypes
                metadata.metadataObjectTypes = self.allSymbologies.filter { supported.contains($0) }
            }
            session.commitConfiguration()

            if applied {
                self.device = newDevice
                self.scanLock.lock()
                self.hasScanned = false
                self.scanLock.unlock()
                // 换镜头后统一回到 1x 变焦，避免上一颗镜头的放大倍数残留
                self.applyZoom(1.0, on: newDevice)
                // 换了镜头后沿用当前对焦方式（手动焦距保持不变）
                self.applyFocusMode(on: newDevice)
                // 新镜头的手电筒默认是关的，按用户意图补开；不支持则把 UI 同步为关
                if self.desiredTorchOn {
                    if !self.setTorch(on: true) {
                        self.desiredTorchOn = false
                        NotificationCenter.default.post(name: Self.torchStateDidChangeNotification, object: nil, userInfo: ["isOn": false])
                    }
                } else {
                    NotificationCenter.default.post(name: Self.torchStateDidChangeNotification, object: nil, userInfo: ["isOn": false])
                }
            }

            DispatchQueue.main.async {
                self.onLensesChanged?(self.rearLenses.map { $0.title }, self.currentRearIndex)
            }
            completion?(self.device ?? newDevice)
        }
    }

    // MARK: - 手动对焦
    /// 切换对焦方式：true = 锁定手动焦距，false = 回到连续自动对焦
    func setManualFocus(enabled: Bool) {
        guard let device = device else { return }
        if enabled && !device.isLockingFocusWithCustomLensPositionSupported {
            // 设备不支持自定义焦距，保持自动，避免 UI 状态与实际不符
            isManualFocus = false
            applyFocusMode(on: device)
            return
        }
        isManualFocus = enabled
        applyFocusMode(on: device)
    }

    /// 滑杆拖动：0 = 最近（微距）… 1 = 无穷远
    func setManualFocusPosition(_ position: Float) {
        manualFocusPosition = min(max(position, 0), 1)
        guard isManualFocus, let device = device,
              device.isLockingFocusWithCustomLensPositionSupported else { return }
        // 60ms 去抖：拖动会连续触发，避免高频 lockForConfiguration 卡顿
        focusApplyWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self, weak device] in
            guard let self = self, let device = device else { return }
            do {
                try device.lockForConfiguration()
                device.setFocusModeLocked(lensPosition: self.manualFocusPosition, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {}
        }
        focusApplyWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func applyFocusMode(on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if isManualFocus, device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: manualFocusPosition, completionHandler: nil)
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            // 连续自动曝光：条码黑条与白底反差是解码前提，曝光漂移会直接把条码“糊”掉
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            print("设置对焦模式失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 微距控制
    /// 开启：切超广角 + 焦距锁最近 + 放大到接近 1x 视野
    /// 关闭：切回原镜头 + 变焦复位 + 恢复原来的对焦方式
    func setMacroMode(enabled: Bool) {
        guard enabled != isMacroMode else { return }

        if enabled {
            guard let index = rearLenses.firstIndex(where: { $0.zoom < 0.9 }) else {
                // 没有超广角的机型（单摄/双摄无超广角）
                DispatchQueue.main.async { [weak self] in
                    self?.onMacroStateChanged?(false, self?.isManualFocus ?? false, self?.manualFocusPosition ?? 0.5)
                }
                return
            }
            let macro = rearLenses[index]
            macroReturnIndex = currentRearIndex
            macroReturnManualFocus = isManualFocus
            macroReturnFocusPosition = manualFocusPosition
            currentRearIndex = index
            isMacroMode = true
            // 焦距锁到最近段（超广角的最近对焦距离约 2cm）
            manualFocusPosition = 0
            isManualFocus = true
            // 放大到接近 1x 视野：系统相机微距也是超广角裁切取景
            let zoom = 1.0 / max(macro.zoom, 0.1)
            switchCamera(to: macro.device) { [weak self] applied in
                guard let self = self else { return }
                self.applyZoom(zoom, on: applied)
                self.applyFocusMode(on: applied)
                DispatchQueue.main.async {
                    self.onMacroStateChanged?(true, true, 0)
                }
            }
        } else {
            isMacroMode = false
            guard macroReturnIndex >= 0, macroReturnIndex < rearLenses.count else { return }
            let target = rearLenses[macroReturnIndex]
            currentRearIndex = macroReturnIndex
            manualFocusPosition = macroReturnFocusPosition
            isManualFocus = macroReturnManualFocus
            switchCamera(to: target.device) { [weak self] applied in
                guard let self = self else { return }
                self.resetZoom(on: applied)
                self.applyFocusMode(on: applied)
                DispatchQueue.main.async {
                    self.onMacroStateChanged?(false, self.isManualFocus, self.manualFocusPosition)
                }
            }
        }
    }

    /// 设置数码变焦（单次应用，不做动画；超广角放大 2x 即接近 1x 视野）
    private func applyZoom(_ factor: CGFloat, on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 8)
            let minZoom = device.minAvailableVideoZoomFactor
            device.videoZoomFactor = min(max(factor, minZoom), maxZoom)
            device.unlockForConfiguration()
        } catch {
            print("设置变焦失败: \(error.localizedDescription)")
        }
    }

    private func resetZoom(on device: AVCaptureDevice) {
        applyZoom(1.0, on: device)
    }

    // MARK: - 手电筒控制
    @discardableResult
    func setTorch(on: Bool) -> Bool {
        guard let device = device, device.hasTorch else { return false }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = on ? .on : .off
            if on {
                try device.setTorchModeOn(level: 1.0)
            }
            // 以设备真实状态回传，避免 UI 与硬件不一致
            let actualOn = device.torchMode != .off
            desiredTorchOn = actualOn
            NotificationCenter.default.post(name: Self.torchStateDidChangeNotification, object: nil, userInfo: ["isOn": actualOn])
            return true
        } catch {
            return false
        }
    }

    // MARK: - 快门声音
    /// 使用系统相机快门音（ID 1108）。工程内并未附带自定义 shutter.wav，
    /// 原先“优先读 bundle 音频、失败再回落系统音”的分支永远走不到自定义音，已移除。
    func playShutterSound() {
        AudioServicesPlaySystemSound(1108)
    }

    // MARK: - 权限检查
    private func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.setupCamera() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.setupCamera() : self?.showPermissionAlert()
                }
            }
        default:
            showPermissionAlert()
        }
    }

    // MARK: - 相机设置
    /// 相机配置全部放到 sessionQueue 上做：设备枚举、输入输出装配、startRunning 都可能耗时，
    /// 放在主线程会让启动画面卡住（表现就是一直白屏）。主线程只负责建预览层和回调 UI。
    private func setupCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            let session = AVCaptureSession()
            // 能力判断：并非所有设备都支持 .photo 预设，直接赋值会抛异常
            let preset = SettingsManager.shared.photoQuality.sessionPreset
            if session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
            }

            // 后置镜头组：按设备真实拥有的镜头动态生成 0.5x / 1x / 2x / 3x
            let rear = self.discoverRearLenses()
            guard let defaultLens = rear.first(where: { abs($0.zoom - 1) < 0.01 }) ?? rear.first else {
                self.showError("无法访问后置摄像头")
                return
            }
            self.rearLenses = rear

            do {
                let input = try AVCaptureDeviceInput(device: defaultLens.device)
                guard session.canAddInput(input) else {
                    self.showError("无法添加相机输入")
                    return
                }
                session.addInput(input)
                self.currentVideoInput = input
            } catch {
                self.showError("相机初始化失败: \(error.localizedDescription)")
                return
            }

            let metadataOutput = AVCaptureMetadataOutput()
            guard session.canAddOutput(metadataOutput) else {
                self.showError("无法添加扫码输出")
                return
            }
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: self.videoQueue)
            // 只启用当前设备 + 当前分辨率预设下真正支持的码制，
            // 直接整体赋值会导致一维码识别能力静默失效
            let supported = metadataOutput.availableMetadataObjectTypes
            metadataOutput.metadataObjectTypes = self.allSymbologies.filter { supported.contains($0) }

            // 视频帧输出：给 Vision 兜底识别用（一维码识别率明显高于纯元数据输出）
            let videoDataOutput = AVCaptureVideoDataOutput()
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            if session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
                videoDataOutput.setSampleBufferDelegate(self, queue: self.frameQueue)
                // 竖屏取景：把帧旋转到正向，否则 Vision 会在横向坐标系里找码
                if let connection = videoDataOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
                self.videoDataOutput = videoDataOutput
            }

            let photoOutput = AVCapturePhotoOutput()
            guard session.canAddOutput(photoOutput) else {
                self.showError("无法添加照片输出")
                return
            }
            session.addOutput(photoOutput)
            self.photoOutput = photoOutput

            self.device = defaultLens.device
            self.currentRearIndex = rear.firstIndex(where: { $0.device == defaultLens.device }) ?? 0
            self.captureSession = session

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let layer = AVCaptureVideoPreviewLayer(session: session)
                layer.videoGravity = .resizeAspectFill
                layer.frame = self.view.bounds
                layer.backgroundColor = UIColor.black.cgColor
                self.view.layer.insertSublayer(layer, at: 0)
                self.previewLayer = layer

                // 初始化对焦/曝光基线：连续自动对焦 + 连续自动曝光，中心区域优先
                self.applyFocusMode(on: defaultLens.device)
                self.addTapToFocus()

                // 告诉 UI：当前设备支持哪些档位
                self.onLensesChanged?(self.rearLenses.map { $0.title }, self.currentRearIndex)
            }

            session.startRunning()
        }
    }

    /// 枚举后置摄像头，用「相对广角的视野比」换算成 0.5x / 1x / 2x / 3x 档位。
    /// 这样不依赖机型硬编码，iPhone 13/15/16 各代超广角、长焦倍率都能得到正确标签。
    private func discoverRearLenses() -> [(title: String, device: AVCaptureDevice, zoom: CGFloat)] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        )
        let devices = discovery.devices
        guard let wide = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) else {
            // 兜底：老设备只有广角一颗
            if let single = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                return [("1x", single, 1.0)]
            }
            return []
        }

        let wideFOV = Double(wide.activeFormat.videoFieldOfView)
        var result: [(title: String, device: AVCaptureDevice, zoom: CGFloat)] = []
        for device in devices {
            let fov = Double(max(device.activeFormat.videoFieldOfView, 1))
            let rawZoom = wideFOV / fov
            let rounded = max(0.5, (rawZoom * 2).rounded() / 2)
            let title: String
            if abs(rounded - 1) < 0.01 {
                title = "1x"
            } else if rounded < 1 {
                title = String(format: "%.1fx", rounded)
            } else {
                title = String(format: "%.0fx", rounded)
            }
            result.append((title, device, CGFloat(rounded)))
        }
        return result.sorted { $0.zoom < $1.zoom }
    }

    // MARK: - 视频帧回调：Vision 兜底识别（一维码优先）
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === videoDataOutput else { return }

        // 正在处理一次识别、或还在冷却期，就跳过这一帧
        scanLock.lock()
        let busy = hasScanned
        let cooling = lastScanTime.map { Date().timeIntervalSince($0) < scanCooldown } ?? false
        scanLock.unlock()
        if busy || cooling { return }

        let now = Date()
        if now.timeIntervalSince(lastVisionDate) < visionInterval { return }
        lastVisionDate = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectBarcodesRequest()
        // 只看取景框中间区域：更快，也避免把远处背景里的码误识别
        request.regionOfInterest = CGRect(x: 0.04, y: 0.22, width: 0.92, height: 0.56)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let observations = request.results, !observations.isEmpty else { return }

        // 一维码优先，其次取置信度最高、码面面积最大的
        let candidates = observations.compactMap { obs -> (VNBarcodeObservation, String)? in
            guard let value = obs.payloadStringValue, !value.isEmpty else { return nil }
            if obs.confidence < 0.3 { return nil }
            return (obs, value)
        }
        guard let best = candidates.sorted(by: { a, b in
            let a1D = self.isOneDimensional(a.0.symbology)
            let b1D = self.isOneDimensional(b.0.symbology)
            if a1D != b1D { return a1D }
            return a.0.boundingBox.width * a.0.boundingBox.height > b.0.boundingBox.width * b.0.boundingBox.height
        }).first else { return }

        scanLock.lock()
        if hasScanned {
            scanLock.unlock()
            return
        }
        hasScanned = true
        lastScanTime = Date()
        scanLock.unlock()

        let name = self.visionSymbologyName(best.0.symbology)
        DispatchQueue.main.async { [weak self] in
            self?.onScan?(best.1, name)
        }
    }

    /// 是否为一维（条形）码
    private func isOneDimensional(_ symbology: VNBarcodeSymbology) -> Bool {
        let raw = symbology.rawValue
        // 二维码的 Vision 标识里带这些关键字，其余按一维码处理
        let twoD = ["QR", "DataMatrix", "PDF417", "Aztec", "MicroQR", "MicroPDF"]
        return !twoD.contains { raw.contains($0) }
    }

    /// Vision 码制名映射成中文/常见叫法，和元数据通道的名称保持一致
    private func visionSymbologyName(_ symbology: VNBarcodeSymbology) -> String {
        let raw = symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
        switch raw {
        case "Code128": return "Code 128"
        case "Code39", "Code39Checksum", "Code39FullASCII", "Code39FullASCIIChecksum": return "Code 39"
        case "Code93", "Code93i": return "Code 93"
        case "Codabar": return "Codabar"
        case "EAN8": return "EAN-8"
        case "EAN13": return "EAN-13"
        case "UPCE": return "UPC-E"
        case "ITF14": return "ITF-14"
        case "I2of5", "I2of5Checksum": return "Interleaved 2 of 5"
        case "GS1DataBar": return "GS1 DataBar"
        case "GS1DataBarExpanded": return "GS1 DataBar Expanded"
        case "GS1DataBarLimited": return "GS1 DataBar Limited"
        case "QR": return "QR Code"
        case "DataMatrix": return "Data Matrix"
        case "PDF417", "MicroPDF417": return "PDF417"
        case "Aztec": return "Aztec"
        default: return "条形码"
        }
    }

    // MARK: - 扫码回调
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        scanLock.lock()
        defer { scanLock.unlock() }

        guard !hasScanned else { return }

        // 冷却时间检查：两次扫描间隔至少 1.5 秒
        if let lastTime = lastScanTime, Date().timeIntervalSince(lastTime) < scanCooldown {
            return
        }

        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }

        hasScanned = true
        lastScanTime = Date()

        let name = symbologyName(object.type)
        // 回调本身在 videoQueue 上，回到主线程再交给 SwiftUI
        DispatchQueue.main.async { [weak self] in
            self?.onScan?(value, name)
        }
    }

    // MARK: - 拍照（扫描后自动调用，生成预览图）
    func capturePhoto(playSound: Bool = true, watermarkContent: String? = nil) {
        guard let photoOutput = photoOutput else {
            DispatchQueue.main.async { [weak self] in
                self?.onPhotoCaptureFailed?("相机尚未就绪，请稍后重试")
            }
            return
        }

        if playSound {
            playShutterSound()
        }

        self.pendingWatermarkContent = watermarkContent

        let settings = AVCapturePhotoSettings()
        // 无闪光灯的机型/前置镜头直接赋 .auto 会抛异常，必须先判断能力
        if photoOutput.supportedFlashModes.contains(.auto) {
            settings.flashMode = .auto
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - AVCapturePhotoCaptureDelegate
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // 修复：拍照失败时通过回调通知 SwiftUI 恢复界面，避免永久卡在"正在生成预览..."
        if let error = error {
            print("拍照失败: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.onPhotoCaptureFailed?("拍照失败: \(error.localizedDescription)")
            }
            return
        }

        guard let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            DispatchQueue.main.async { [weak self] in
                self?.onPhotoCaptureFailed?("照片数据处理失败，请重试")
            }
            return
        }

        // 按“照片清晰度”档位缩放 + 锐化：保持原始宽高比，不再把画面硬拉伸成固定尺寸
        let processedImage = SettingsManager.shared.processPhoto(image)

        let watermarkedImage = addWatermark(to: processedImage, content: pendingWatermarkContent)

        // 将带水印的照片传回 SwiftUI 进行预览
        DispatchQueue.main.async { [weak self] in
            self?.onPhotoCaptured?(watermarkedImage)
        }
    }

    // MARK: - 添加水印（时间 + 扫码内容 + 可选位置信息）
    private func addWatermark(to image: UIImage, content: String?) -> UIImage {
        let size = image.size
        let scale = image.scale

        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        defer { UIGraphicsEndImageContext() }

        image.draw(in: CGRect(origin: .zero, size: size))

        let context = UIGraphicsGetCurrentContext()!

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "zh_CN")
        let timeString = formatter.string(from: Date())

        let displayContent = content ?? ""
        let maxContentLength = 30
        let truncatedContent = displayContent.count > maxContentLength
            ? String(displayContent.prefix(maxContentLength)) + "..."
            : displayContent

        // 水印字号支持在设置中调整（小/中/大）+ 精细倍率，
        // 以 1280 宽为设计基准等比放大字号与内边距，保证“最高清晰度”下大图上的水印观感一致、不显得过小
        let fontSizeSetting = SettingsManager.shared.watermarkFontSize
        let layoutScale = max(size.width / SettingsManager.watermarkDesignWidth, 1.0)
        // 用户可调的额外倍率（1.0 为档位原始大小）
        let userScale = CGFloat(SettingsManager.shared.watermarkFontScale)
        // 字号与文本框内边距随倍率一起变，保证背景框始终贴合文字
        let textScale = layoutScale * userScale
        let timeFont = UIFont.systemFont(ofSize: fontSizeSetting.timeFontSize * textScale, weight: .semibold)
        let contentFont = UIFont.systemFont(ofSize: fontSizeSetting.contentFontSize * textScale, weight: .medium)
        let textColor = SettingsManager.shared.resolvedWatermarkColor
        let shadowColor = UIColor.black.withAlphaComponent(0.8)

        let timeAttributes: [NSAttributedString.Key: Any] = [
            .font: timeFont,
            .foregroundColor: textColor,
            .strokeColor: shadowColor,
            .strokeWidth: -2.0
        ]

        let contentAttributes: [NSAttributedString.Key: Any] = [
            .font: contentFont,
            .foregroundColor: textColor.withAlphaComponent(0.9),
            .strokeColor: shadowColor,
            .strokeWidth: -1.5
        ]

        let timeText = NSAttributedString(string: timeString, attributes: timeAttributes)
        let contentText = NSAttributedString(string: truncatedContent, attributes: contentAttributes)

        // 可选：位置信息水印（与内容水印同字号、同色）
        var locationText: NSAttributedString? = nil
        if SettingsManager.shared.showLocationInWatermark,
           let address = LocationManager.shared.currentAddress,
           !address.isEmpty {
            let truncatedAddress = address.count > maxContentLength
                ? String(address.prefix(maxContentLength)) + "..."
                : address
            locationText = NSAttributedString(string: truncatedAddress, attributes: contentAttributes)
        }

        let maxTextWidth = size.width - 40 * layoutScale
        let timeSize = timeText.boundingRect(with: CGSize(width: maxTextWidth, height: 40 * textScale), options: .usesLineFragmentOrigin, context: nil).size
        let contentSize = contentText.boundingRect(with: CGSize(width: maxTextWidth, height: 30 * textScale), options: .usesLineFragmentOrigin, context: nil).size
        let locationSize = locationText?.boundingRect(with: CGSize(width: maxTextWidth, height: 30 * textScale), options: .usesLineFragmentOrigin, context: nil).size ?? .zero

        let padding: CGFloat = 12 * textScale
        let interItemSpacing: CGFloat = 4 * textScale
        var watermarkHeight = timeSize.height + padding * 2
        if !truncatedContent.isEmpty {
            watermarkHeight += contentSize.height + interItemSpacing
        }
        if locationText != nil {
            watermarkHeight += locationSize.height + interItemSpacing
        }
        let watermarkWidth = max(timeSize.width, max(contentSize.width, locationSize.width)) + padding * 2

        let leftMargin: CGFloat = 16 * layoutScale
        let bottomMargin: CGFloat = 30 * layoutScale
        let watermarkX = leftMargin
        let watermarkY = size.height - watermarkHeight - bottomMargin
        let watermarkRect = CGRect(x: watermarkX, y: watermarkY, width: watermarkWidth, height: watermarkHeight)

        context.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        let path = UIBezierPath(roundedRect: watermarkRect, cornerRadius: 10 * textScale)
        context.addPath(path.cgPath)
        context.fillPath()

        var drawY = watermarkRect.minY + padding
        timeText.draw(at: CGPoint(x: watermarkRect.minX + padding, y: drawY))
        drawY += timeSize.height + interItemSpacing

        if !truncatedContent.isEmpty {
            contentText.draw(at: CGPoint(x: watermarkRect.minX + padding, y: drawY))
            drawY += contentSize.height + interItemSpacing
        }

        if let locationText = locationText {
            locationText.draw(at: CGPoint(x: watermarkRect.minX + padding, y: drawY))
        }

        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }

    // MARK: - 码制名称
    private func symbologyName(_ type: AVMetadataObject.ObjectType) -> String {
        // GS1 DataBar 系列（iOS 15+）：相机端已启用，但之前的 switch 没有对应分支，
        // 会落到 default 显示“未知”，这里补上名称映射
        if #available(iOS 15.0, *) {
            switch type {
            case .gs1DataBar: return "GS1 DataBar"
            case .gs1DataBarLimited: return "GS1 DataBar Limited"
            case .gs1DataBarExpanded: return "GS1 DataBar Expanded"
            default: break
            }
        }
        switch type {
        case .qr: return "QR Code"
        case .aztec: return "Aztec"
        case .pdf417: return "PDF417"
        case .dataMatrix: return "Data Matrix"
        case .ean8: return "EAN-8"
        case .ean13: return "EAN-13"
        case .upce: return "UPC-E"
        case .code39, .code39Mod43: return "Code 39"
        case .code93: return "Code 93"
        case .code128: return "Code 128"
        case .interleaved2of5: return "Interleaved 2 of 5"
        case .itf14: return "ITF14"
        default: return "未知"
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - 点按对焦 / 曝光
    private func addTapToFocus() {
        // 允许同时识别（不影响 SwiftUI 层按钮，这些按钮在宿主视图之上）
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = true
        tap.delaysTouchesEnded = false
        view.addGestureRecognizer(tap)
    }

    @objc private func handleTapToFocus(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        // 手动对焦模式下由滑杆控制焦距，点按不再改焦
        guard !isManualFocus else { return }
        guard let device = device, let previewLayer = previewLayer else { return }

        let point = gesture.location(in: view)

        // 先给视觉与触感反馈：旧实现只设了焦点、屏幕上没有任何提示，
        // 用户无法判断点按是否生效，表现为“点了没反应”
        showFocusReticle(at: point)
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.prepare()
        feedback.impactOccurred()

        // 预览层是 resizeAspectFill，坐标必须先换算成设备坐标，再裁到合法范围
        let converted = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        let focusPoint = CGPoint(
            x: min(max(converted.x, 0.05), 0.95),
            y: min(max(converted.y, 0.05), 0.95)
        )

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // 单次对焦，0.5 秒后回落连续自动对焦，避免条码再次入框时对不上
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = focusPoint
                device.focusMode = .autoFocus

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak device] in
                    guard let device = device else { return }
                    do {
                        try device.lockForConfiguration()
                        if device.isFocusModeSupported(.continuousAutoFocus) {
                            device.focusMode = .continuousAutoFocus
                        }
                        device.unlockForConfiguration()
                    } catch {}
                }
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                // 设备不支持指定点对焦（例如部分固定焦点机型）时至少触发一次连续对焦
                device.focusMode = .continuousAutoFocus
            }

            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = focusPoint
                device.exposureMode = .autoExpose
            }
        } catch {
            print("对焦失败: \(error.localizedDescription)")
        }
    }

    /// 在点按位置绘制对焦框：放大弹出 → 停留 → 淡出
    private func showFocusReticle(at point: CGPoint) {
        let side: CGFloat = 84
        focusReticle.removeFromSuperview()
        focusReticle.frame = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        focusReticle.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
        focusReticle.alpha = 1
        view.addSubview(focusReticle)

        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.focusReticle.transform = .identity
        } completion: { _ in
            UIView.animate(
                withDuration: 0.25,
                delay: 0.55,
                options: [.curveEaseIn, .beginFromCurrentState]
            ) {
                self.focusReticle.alpha = 0
            }
        }
    }

    private func showPermissionAlert() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            self.presentPermissionAlert()
        }
    }

    private func presentPermissionAlert() {
        let alert = UIAlertController(title: "需要相机权限", message: "请在设置中允许此应用访问相机", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "去设置", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        // setupCamera 在后台队列上跑，弹窗必须回主线程
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            self.presentErrorAlert(message)
        }
    }

    private func presentErrorAlert(_ message: String) {
        let alert = UIAlertController(title: "错误", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    }
