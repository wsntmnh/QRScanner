//
//  QRScannerView.swift
//  QRScanner
//
//  Created by 史冬亮 on 2026/8/14.
//

import SwiftUI
import AVFoundation
import Photos
import AudioToolbox

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate, AVCapturePhotoCaptureDelegate {
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
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 修复：不再因弹出 sheet（设置/历史/统计）而停止相机，
        // 相机只在退到后台或主动调用 pauseCapture() 时停止，避免反复启停的黑屏与延迟。
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
            self?.scanLock.lock()
            let shouldStart = !(self?.hasScanned ?? true)
            self?.scanLock.unlock()
            if shouldStart {
                session.startRunning()
            }
        }
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
            NotificationCenter.default.post(name: Self.torchStateDidChangeNotification, object: nil, userInfo: ["isOn": on])
            return true
        } catch {
            return false
        }
    }

    var isTorchAvailable: Bool {
        guard let device = device else { return false }
        return device.hasTorch
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
    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = SettingsManager.shared.photoQuality.sessionPreset

        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            showError("无法访问后置摄像头")
            return
        }
        self.device = videoDevice

        do {
            let input = try AVCaptureDeviceInput(device: videoDevice)
            guard session.canAddInput(input) else {
                showError("无法添加相机输入")
                return
            }
            session.addInput(input)
        } catch {
            showError("相机初始化失败: \(error.localizedDescription)")
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            showError("无法添加扫码输出")
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: videoQueue)
        // 关键修复：只启用当前设备 + 当前分辨率预设下真正支持的码制。
        // 旧设备或低清晰度预设下不支持 interleaved2of5 / itf14 等类型，
        // 直接整体赋值会导致一维码识别能力静默失效。
        let supported = metadataOutput.availableMetadataObjectTypes
        let enabledTypes = allSymbologies.filter { supported.contains($0) }
        metadataOutput.metadataObjectTypes = enabledTypes

        let photoOutput = AVCapturePhotoOutput()
        guard session.canAddOutput(photoOutput) else {
            showError("无法添加照片输出")
            return
        }
        session.addOutput(photoOutput)
        self.photoOutput = photoOutput

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        captureSession = session
        addTapToFocus()

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
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
        settings.flashMode = .auto
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
        let alert = UIAlertController(title: "错误", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    }
