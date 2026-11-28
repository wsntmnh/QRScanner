//
//  ContentView.swift
//  QRScanner
//
//  Created by 史冬亮 on 2026/8/14.
//

import SwiftUI
import Photos
import Vision
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var settings = SettingsManager.shared
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showImagePicker = false
    @State private var showSuccess = false
    @State private var successMessage = ""
    @State private var resetScanFlag = false
    @State private var isTorchOn = false
    @State private var scannerController: QRScannerViewController?
    @State private var showSettings = false
    @State private var lastScanSource: ScanRecord.ScanSource = .camera

    // 照片预览
    @State private var previewImage: UIImage?
    @State private var showPreview = false
    @State private var isSavingPhoto = false

    // 镜头切换：后置档位列表、当前档位
    @State private var lensTitles: [String] = []
    @State private var selectedLensIndex = 0

    // 对焦方式：自动 / 手动（0 = 最近，1 = 无穷远）
    @State private var manualFocus = false
    @State private var focusPosition: Double = 0.5

    // 微距：占用超广角 + 焦距锁最近
    @State private var isMacro = false

    // 启动兜底：相机长时间没起来时给出可操作的提示，而不是停在空白画面
    @State private var showBootFallback = false

    // 出入库：记录先落库，等照片拍完再让用户选择方向（未拍照时直接弹）
    @State private var pendingDirectionRecordID: UUID?
    @State private var pendingDirectionText: String?
    @State private var pendingPhoto: UIImage?
    @State private var showDirectionPicker = false
    /// 识别成功后立刻展示的照片（成功遮罩 / 方向选择里都显示）
    @State private var scanThumb: UIImage?
    /// 只为在结果里显示照片而拍的这一张：不进预览、不保存
    @State private var captureForThumbOnly = false

    var body: some View {
        ZStack {
            ScannerWrapperView(onScan: { result, symbology in
                handleScanResult(result: result, symbology: symbology)
            }, onPhotoCaptured: { image in
                handlePhotoCaptured(image: image)
            }, onPhotoCaptureFailed: { message in
                handlePhotoCaptureFailed(message)
            }, resetFlag: $resetScanFlag, controller: $scannerController,
               lensTitles: $lensTitles, selectedLensIndex: $selectedLensIndex,
               isMacroOn: $isMacro, manualFocusOn: $manualFocus, focusPosition: $focusPosition)
            .ignoresSafeArea()

            // 上下移动的动态扫描线（不含遮罩与四角框）
            // 不参与触摸命中，否则扫描线扫过的区域会吞掉点按对焦手势
            ScanLineOverlay()
                .allowsHitTesting(false)

            // 顶部按钮栏（统计入口已移入设置页，这里只留设置）
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        showSettings = true
                    }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                }
                Spacer()
            }

            // 底部工具栏
            VStack {
                Spacer()

                // 对焦方式：自动 / 手动（手动时用滑杆控制焦距）
                HStack(spacing: 10) {
                    Button {
                        if manualFocus {
                            manualFocus = false
                            scannerController?.setManualFocus(enabled: false)
                        } else {
                            guard let controller = scannerController, controller.supportsManualFocus else {
                                showError(message: "当前设备不支持手动对焦")
                                return
                            }
                            manualFocus = true
                            controller.setManualFocus(enabled: true)
                            controller.setManualFocusPosition(Float(focusPosition))
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: manualFocus ? "hand.point.up.left.fill" : "viewfinder")
                                .font(.system(size: 11))
                            Text(manualFocus ? "手动" : "自动")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(manualFocus ? .yellow : .white)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Capsule().fill(Color.black.opacity(0.4)))
                    }

                    if manualFocus {
                        HStack(spacing: 6) {
                            Text("近")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.65))
                            Slider(value: $focusPosition, in: 0...1)
                                .frame(width: 160)
                                .tint(.yellow)
                                .onChange(of: focusPosition) { _, newValue in
                                    scannerController?.setManualFocusPosition(Float(newValue))
                                }
                            Text("远")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.65))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(Capsule().fill(Color.black.opacity(0.4)))
                    }
                }
                .padding(.bottom, 10)

                // 镜头切换：后置 0.5x / 1x / 3x 档位
                if !lensTitles.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(Array(lensTitles.enumerated()), id: \.offset) { index, title in
                            Button {
                                scannerController?.selectRearLens(index: index)
                            } label: {
                                Text(title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(selectedLensIndex == index ? .yellow : .white)
                                    .frame(width: 38, height: 38)
                                    .background(
                                        Circle().fill(Color.black.opacity(selectedLensIndex == index ? 0.6 : 0.3))
                                    )
                            }
                        }

                        // 微距：切超广角 + 焦距锁最近（离得很近的码用这个）
                        Button {
                            if isMacro {
                                isMacro = false
                                scannerController?.setMacroMode(enabled: false)
                            } else {
                                guard let controller = scannerController, controller.hasMacroLens else {
                                    showError(message: "该设备没有超广角镜头，不支持微距")
                                    return
                                }
                                isMacro = true
                                controller.setMacroMode(enabled: true)
                            }
                        } label: {
                            Text("微距")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(isMacro ? .yellow : .white)
                                .padding(.horizontal, 12)
                                .frame(height: 38)
                                .background(Capsule().fill(Color.black.opacity(isMacro ? 0.6 : 0.3)))
                        }
                    }
                    .padding(.bottom, 14)
                }

                // 「历史」已移到设置页，底部只保留相册 / 拍照 / 手电筒三个高频操作
                HStack(spacing: 44) {
                    Button(action: {
                        showImagePicker = true
                    }) {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 22))
                            Text("相册")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                    }

                    Button(action: {
                        capturePhotoManually()
                    }) {
                        VStack(spacing: 6) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 22))
                            Text("拍照")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                    }

                    Button(action: {
                        toggleTorch()
                    }) {
                        VStack(spacing: 6) {
                            Image(systemName: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.system(size: 22))
                            Text(isTorchOn ? "关闭" : "手电筒")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(isTorchOn ? .yellow : .white)
                        .frame(width: 60, height: 60)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                    }

                }
                .padding(.bottom, 50)
            }

            // 复制成功遮罩
            if showSuccess {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 70))
                        .foregroundColor(.green)

                    Text("已复制到剪贴板")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white)

                    if let thumb = scanThumb {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 150, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.25), lineWidth: 1))
                    } else if settings.autoSavePhoto && lastScanSource == .camera {
                        Text("正在拍照...")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.8))
                    }

                    Text(successMessage)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.8))
                .ignoresSafeArea()
                .transition(.opacity)
            }

            // 车架号出入库选择
            if showDirectionPicker, let content = pendingDirectionText {
                let vin = ScanRecord.vinInText(content)
                VStack(spacing: 18) {
                    if let thumb = scanThumb {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 170, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.25), lineWidth: 1))
                    }
                    VStack(spacing: 6) {
                        Text(vin != nil ? "识别到车架号" : "识别到扫码内容")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.7))
                        Text(vin ?? content)
                            .font(.system(size: vin != nil ? 17 : 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }

                    HStack(spacing: 14) {
                        Button {
                            confirmVINDirection(.inbound)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.to.line")
                                Text("入库")
                            }
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 130, height: 52)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.85)))
                        }

                        Button {
                            confirmVINDirection(.outbound)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.to.line")
                                Text("出库")
                            }
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 130, height: 52)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.9)))
                        }
                    }

                    Button {
                        confirmVINDirection(nil)
                    } label: {
                        Text("跳过，不记录方向")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.65))
                    }
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.85)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .transition(.opacity)
            }

            // 启动兜底：相机没起来时给出明确原因与「重新初始化」按钮
            if showBootFallback {
                VStack(spacing: 16) {
                    Image(systemName: "camera.badge.ellipsis")
                        .font(.system(size: 46))
                        .foregroundColor(.white)

                    Text("相机没有启动")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    Text("请确认「设置 → QRScanner → 相机」已允许访问；\n也可以点下面按钮重新初始化相机。")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)

                    Button {
                        showBootFallback = false
                        scannerController?.restartCamera()
                        scheduleBootCheck()
                    } label: {
                        Text("重新初始化相机")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .frame(height: 42)
                            .background(Capsule().fill(Color.blue))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.82))
                .ignoresSafeArea()
            }

            // 照片预览弹窗
            if showPreview, let image = previewImage {
                PhotoPreviewView(
                    image: image,
                    content: successMessage,
                    isSaving: isSavingPhoto,
                    onSave: { savePreviewPhoto(image: image) },
                    onCancel: { dismissPreview() }
                )
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(sourceType: .photoLibrary) { image in
                if let image = image {
                    processImage(image)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("提示", isPresented: $showError) {
            Button("确定") {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            // 手电筒状态完全由相机层通知驱动，保证与设备实际状态一致
            NotificationCenter.default.addObserver(forName: QRScannerViewController.torchStateDidChangeNotification, object: nil, queue: .main) { notification in
                if let isOn = notification.userInfo?["isOn"] as? Bool {
                    isTorchOn = isOn
                }
            }
            // 若开启位置水印，进入应用即开始定位，保证扫码拍照时地址已就绪
            if settings.showLocationInWatermark {
                LocationManager.shared.startUpdating()
            }
            scheduleBootCheck()
        }
        .onChange(of: settings.showLocationInWatermark) { _, isOn in
            if isOn {
                LocationManager.shared.startUpdating()
            } else {
                LocationManager.shared.stopUpdating()
            }
        }
        .onChange(of: settings.photoQuality) { _, _ in
            scannerController?.updateSessionPreset()
        }
    }

    // MARK: - 启动自检
    /// 相机初始化是异步的，等 4 秒还没拿到控制器/镜头列表就认为启动失败，弹出兜底提示。
    private func scheduleBootCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if scannerController == nil || lensTitles.isEmpty {
                withAnimation { showBootFallback = true }
            }
        }
    }

    // MARK: - 扫描结果处理
    private func handleScanResult(result: String, symbology: String, source: ScanRecord.ScanSource = .camera) {
        scanThumb = nil
        // 内容里能找出 17 位车架号就只存车架号，导出一份干净的车架号清单
        let normalized = ScanRecord.vinInText(result) ?? result

        // 同样的数据只记一次：相机几秒内反复上报同一条 → 直接跳过
        if source == .camera, HistoryManager.shared.hasRecentRecord(content: normalized, within: 5) {
            // 不重复入库，但把内容照旧复制到剪贴板，方便直接粘贴使用
            UIPasteboard.general.string = normalized
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showError(message: "刚记录过，未重复添加（已复制到剪贴板）")
            scannerController?.resetScan()
            return
        }
        // 相册导入：历史里已有完全相同的内容就不再新增
        if source == .photoLibrary, HistoryManager.shared.hasAnyRecord(content: normalized) {
            UIPasteboard.general.string = normalized
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showError(message: "该内容已存在，未重复记录（已复制到剪贴板）")
            resetScanFlag = true
            return
        }

        finishScan(result: normalized, symbology: symbology, source: source, direction: nil)
    }

    /// 选定入库/出库后回填到已保存的记录上，再看照片预览
    private func confirmVINDirection(_ direction: ScanRecord.VINDirection?) {
        var duplicateSkipped = false
        if let id = pendingDirectionRecordID {
            if let direction = direction {
                // 同一车架号 + 同一方向已经记过：把刚记的这条撤掉，不产生重复行
                if HistoryManager.shared.hasRecord(content: pendingDirectionText.flatMap { ScanRecord.vinInText($0) } ?? "",
                                                   direction: direction, excluding: id) {
                    HistoryManager.shared.removeRecord(id: id)
                    duplicateSkipped = true
                } else {
                    HistoryManager.shared.updateDirection(recordID: id, direction: direction)
                }
            }
        }
        if duplicateSkipped {
            pendingPhoto = nil
            scannerController?.resetScan()
            if let text = pendingDirectionText {
                UIPasteboard.general.string = ScanRecord.vinInText(text) ?? text
            }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showError(message: "该车架号已有\(direction?.rawValue ?? "")记录，未重复添加（已复制到剪贴板）")
        }
        withAnimation { showDirectionPicker = false }
        pendingDirectionRecordID = nil
        pendingDirectionText = nil
        captureForThumbOnly = false

        // 自动拍照模式下照片已拍好，选完方向再进预览
        if let image = pendingPhoto {
            pendingPhoto = nil
            showPreviewPhoto(image)
        }
    }

    private func finishScan(result: String, symbology: String, source: ScanRecord.ScanSource, direction: ScanRecord.VINDirection?) {
        lastScanSource = source
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        let recordID = HistoryManager.shared.addRecord(content: result, source: source, symbology: symbology, direction: direction)
        UIPasteboard.general.string = result

        successMessage = result

        // 相册识别不触发拍照
        if source == .photoLibrary {
            withAnimation {
                showSuccess = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation {
                    showSuccess = false
                }
                resetScanFlag = true
            }
            return
        }

        if settings.autoSavePhoto {
            withAnimation {
                showSuccess = true
            }
            // 照片拍完后再弹入库/出库选择（见 handlePhotoCaptured）
            pendingDirectionRecordID = recordID
            pendingDirectionText = result
            scannerController?.capturePhoto(playSound: settings.playShutterSound, watermarkContent: result)
        } else {
            withAnimation {
                showSuccess = true
            }
            // 没开「拍照预览」：仍然拍一张，仅用于在识别结果里和车架号一起显示
            pendingDirectionRecordID = recordID
            pendingDirectionText = result
            captureForThumbOnly = true
            withAnimation { showDirectionPicker = true }
            scannerController?.capturePhoto(playSound: false, watermarkContent: result)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation {
                    showSuccess = false
                }
                resetScanFlag = true
            }
        }
    }

    // MARK: - 照片拍摄完成，显示预览
    private func handlePhotoCaptured(image: UIImage) {
        scanThumb = image
        // 只为展示拍的一张：不弹预览
        if captureForThumbOnly {
            captureForThumbOnly = false
            return
        }
        // 还没选入库/出库：先弹出选择，选完再显示预览
        if pendingDirectionRecordID != nil {
            pendingPhoto = image
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            withAnimation {
                showSuccess = false
                showDirectionPicker = true
            }
            return
        }
        showPreviewPhoto(image)
    }

    /// 进入照片预览
    private func showPreviewPhoto(_ image: UIImage) {
        previewImage = image
        // 预览期间暂停取景，省电降温；关闭预览时通过 resetScan 恢复
        scannerController?.pauseCapture()
        withAnimation {
            showSuccess = false
            showPreview = true
        }
    }

    // MARK: - 拍照失败：恢复界面并允许重新扫描，避免死锁
    private func handlePhotoCaptureFailed(_ message: String) {
        // 只为展示拍的一张失败：静默忽略，不打断识别流程
        if captureForThumbOnly {
            captureForThumbOnly = false
            return
        }
        withAnimation {
            showSuccess = false
        }
        // 拍照失败不能让入库/出库选择丢在路上
        if pendingDirectionRecordID != nil {
            pendingPhoto = nil
            withAnimation { showDirectionPicker = true }
        }
        showError(message: message)
        resetScanFlag = true
    }

    // MARK: - 保存预览照片
    private func savePreviewPhoto(image: UIImage) {
        isSavingPhoto = true

        PHPhotoLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    isSavingPhoto = false
                    errorMessage = "没有相册写入权限"
                    showError = true
                    return
                }

                // 按“照片清晰度”档位对应的 JPEG 质量写文件后再入库，
                // 这样档位不仅影响分辨率，也真正控制了最终文件的体积（原先直接写 UIImage，质量参数被忽略）
                let jpegData = image.jpegData(compressionQuality: SettingsManager.shared.photoQuality.jpegQuality)
                var tempURL: URL?
                if let data = jpegData {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("QRScanner-\(UUID().uuidString).jpg")
                    if (try? data.write(to: url)) != nil {
                        tempURL = url
                    }
                }

                PHPhotoLibrary.shared().performChanges({
                    if let url = tempURL {
                        _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    } else {
                        _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }
                }) { success, error in
                    if let url = tempURL {
                        try? FileManager.default.removeItem(at: url)
                    }
                    DispatchQueue.main.async {
                        isSavingPhoto = false
                        if success {
                            dismissPreview()
                        } else if let error = error {
                            errorMessage = "保存失败: \(error.localizedDescription)"
                            showError = true
                        }
                    }
                }
            }
        }
    }

    // MARK: - 关闭预览，恢复扫描
    private func dismissPreview() {
        withAnimation {
            showPreview = false
            previewImage = nil
        }
        resetScanFlag = true
    }

    // MARK: - 手动拍照（无需扫码，直接拍摄水印照片）
    private func capturePhotoManually() {
        guard let controller = scannerController else { return }

        // 触感反馈
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()

        // 拍照期间暂停扫码识别（相机保持运行），预览关闭后由 resetScan 恢复
        controller.pauseScanning()
        controller.capturePhoto(playSound: settings.playShutterSound, watermarkContent: nil)
    }

    // MARK: - 手电筒
    private func toggleTorch() {
        guard let controller = scannerController else { return }
        // 状态翻转完全由 setTorch 的结果和通知驱动，避免与实际状态不一致
        let success = controller.setTorch(on: !isTorchOn)
        if !success {
            showError(message: "当前设备不支持手电筒")
        }
    }

    private func processImage(_ image: UIImage) {
        guard let cgImage = image.cgImage else {
            showError(message: "无法读取图片")
            return
        }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [
            .qr, .ean8, .ean13, .upce, .code39, .code93, .code128,
            .pdf417, .aztec, .i2of5, .itf14, .dataMatrix
        ]
        // 与相机端的码制列表对齐：iOS 15+ 补充 GS1 DataBar 三种
        if #available(iOS 15.0, *) {
            request.symbologies.append(contentsOf: [.gs1DataBar, .gs1DataBarLimited, .gs1DataBarExpanded])
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
                DispatchQueue.main.async {
                    let observations = (request.results ?? [])
                        .compactMap { $0 as? VNBarcodeObservation }
                        .filter { $0.payloadStringValue != nil }
                    // 一张图可能有多处码（货架、包装照常见）：优先取识别框面积最大的那个，
                    // 面积相同再看置信度。相比原先直接取 results.first，能避开角落的小码和误检
                    let best = observations.max { lhs, rhs in
                        let lhsArea = lhs.boundingBox.width * lhs.boundingBox.height
                        let rhsArea = rhs.boundingBox.width * rhs.boundingBox.height
                        if lhsArea == rhsArea { return lhs.confidence < rhs.confidence }
                        return lhsArea < rhsArea
                    }

                    if let result = best, let payload = result.payloadStringValue {
                        let symbology = self.visionSymbologyName(result.symbology)
                        self.handleScanResult(result: payload, symbology: symbology, source: .photoLibrary)
                    } else {
                        self.showError(message: "未在图片中识别到二维码或条形码")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.showError(message: "识别失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func visionSymbologyName(_ symbology: VNBarcodeSymbology) -> String {
        // 与相机端 symbologyName 保持一致：iOS 15+ 的 GS1 DataBar 系列
        if #available(iOS 15.0, *) {
            switch symbology {
            case .gs1DataBar: return "GS1 DataBar"
            case .gs1DataBarLimited: return "GS1 DataBar Limited"
            case .gs1DataBarExpanded: return "GS1 DataBar Expanded"
            default: break
            }
        }
        switch symbology {
        case .qr: return "QR Code"
        case .aztec: return "Aztec"
        case .pdf417: return "PDF417"
        case .dataMatrix: return "Data Matrix"
        case .ean8: return "EAN-8"
        case .ean13: return "EAN-13"
        case .upce: return "UPC-E"
        case .code39: return "Code 39"
        case .code93: return "Code 93"
        case .code128: return "Code 128"
        case .i2of5: return "Interleaved 2 of 5"
        case .itf14: return "ITF14"
        default: return "未知"
        }
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}

// MARK: - 照片预览弹窗
struct PhotoPreviewView: View {
    let image: UIImage
    let content: String
    let isSaving: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部标题栏
                HStack {
                    Text("照片预览")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // 照片
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(12)
                    .padding(.horizontal, 16)

                // 二维码内容
                Text(content)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)

                Spacer()

                // 底部按钮
                HStack(spacing: 20) {
                    Button(action: onCancel) {
                        Text("重新扫描")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(12)
                    }

                    Button(action: onSave) {
                        HStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.8)
                            }
                            Text(isSaving ? "保存中..." : "保存到相册")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.blue)
                        .cornerRadius(12)
                    }
                    .disabled(isSaving)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - 设置页面
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsManager.shared
    @State private var showHistory = false
    @State private var showImporter = false
    @State private var importMessage = ""
    @State private var showImportAlert = false
    @State private var showCopiedTip = false
    @ObservedObject private var historyManager = HistoryManager.shared

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("扫描记录")) {
                    Button {
                        showHistory = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(.blue)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("历史记录")
                                    .font(.system(size: 16))
                                    .foregroundColor(.primary)
                                Text(historyManager.records.isEmpty
                                     ? "暂无扫描记录"
                                     : "共 \(historyManager.records.count) 条，可搜索、复制、删除")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                    }

                }

                Section(header: Text("拍照设置")) {
                    Toggle(isOn: $settings.autoSavePhoto) {
                        HStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .foregroundColor(.blue)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("扫描后拍照预览")
                                    .font(.system(size: 16))
                                Text("识别成功后拍照并预览，手动保存")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Toggle(isOn: $settings.playShutterSound) {
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundColor(.orange)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("快门声音")
                                    .font(.system(size: 16))
                                Text("拍照时播放快门音效")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    NavigationLink {
                        PhotoQualitySelectionView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .foregroundColor(.green)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("照片清晰度")
                                    .font(.system(size: 16))
                                Text(settings.photoQuality.description)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                Section(header: Text("水印设置")) {
                    NavigationLink {
                        WatermarkFontSizeSelectionView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size")
                                .foregroundColor(.purple)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("水印文字大小")
                                    .font(.system(size: 16))
                                Text("\(settings.watermarkFontSize.rawValue) · ×\(String(format: "%.2f", settings.watermarkFontScale))")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }

                    NavigationLink {
                        WatermarkColorSelectionView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "paintpalette.fill")
                                .foregroundColor(.pink)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("水印文字颜色")
                                    .font(.system(size: 16))
                                Text(settings.watermarkColorSummary)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(Color(uiColor: settings.resolvedWatermarkColor))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color(UIColor.separator), lineWidth: 1))
                        }
                    }

                    Toggle(isOn: $settings.showLocationInWatermark) {
                        HStack(spacing: 12) {
                            Image(systemName: "location.fill")
                                .foregroundColor(.red)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("水印显示位置信息")
                                    .font(.system(size: 16))
                                Text("拍照水印中附加当前位置（需定位权限）")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Section(header: Text("关于")) {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("作者")
                        Spacer()
                        Text("史冬亮")
                            .foregroundColor(.secondary)
                    }

                    Button {
                        if let url = URL(string: "mailto:36882323@qq.com") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Text("邮箱")
                            Spacer()
                            Text("36882323@qq.com")
                                .foregroundColor(.secondary)
                            Image(systemName: "envelope")
                                .foregroundColor(.blue)
                                .font(.system(size: 14))
                        }
                    }
                }

                Section(header: Text("数据"),
                        footer: Text("导入支持 TXT / CSV / JSON，重复记录（内容与方向都相同）自动跳过；导出可按时间、方向、车架号前缀筛选，复制或分享文件；复制到剪贴板会把当前全部记录一行一条写入剪贴板。")) {
                    Button {
                        showImporter = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.arrow.down")
                                .foregroundColor(.teal)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("导入数据")
                                    .font(.system(size: 16))
                                    .foregroundColor(.primary)
                                Text("从「文件」选择 TXT / CSV / JSON")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }

                    NavigationLink {
                        DataExportView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.indigo)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("导出数据")
                                    .font(.system(size: 16))
                                    .foregroundColor(.primary)
                                Text("按时间范围与类别整理，导出 CSV / JSON / TXT")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }

                    Button {
                        copyAllToClipboard()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.blue)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("复制到剪贴板")
                                    .font(.system(size: 16))
                                    .foregroundColor(.primary)
                                Text(historyManager.records.isEmpty
                                     ? "暂无可复制的记录"
                                     : "复制全部 \(historyManager.records.count) 条记录")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .disabled(historyManager.records.isEmpty)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            // 历史记录从设置页进入（设置本身是 sheet，这里再叠一层 sheet）
            .sheet(isPresented: $showHistory) {
                HistoryView()
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.plainText, .commaSeparatedText, .json, .text],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert("导入结果", isPresented: $showImportAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importMessage)
            }
            .overlay(alignment: .bottom) {
                if showCopiedTip {
                    Text("已复制 \(historyManager.records.count) 条记录到剪贴板")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .padding(.bottom, 30)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - 导入 / 复制

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importMessage = "导入失败：\(error.localizedDescription)"
            showImportAlert = true
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                    importMessage = "文件编码无法识别，请另存为 UTF-8"
                    showImportAlert = true
                    return
                }
                let parsed = ImportParser.parse(text: text, fileName: url.lastPathComponent)
                guard !parsed.isEmpty else {
                    importMessage = "没有解析到可导入的记录，请检查文件格式"
                    showImportAlert = true
                    return
                }
                let outcome = HistoryManager.shared.importRecords(parsed)
                importMessage = "导入完成：新增 \(outcome.added) 条，跳过重复 \(outcome.duplicates) 条"
                showImportAlert = true
            } catch {
                importMessage = "读取文件失败：\(error.localizedDescription)"
                showImportAlert = true
            }
        }
    }

    private func copyAllToClipboard() {
        let records = historyManager.records
        guard !records.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["# QRScanner 扫描记录（共 \(records.count) 条）", "# 车架号\t扫描时间\t入库/出库"]
        for record in records {
            lines.append("\(record.content)\t\(formatter.string(from: record.timestamp))\t\(record.direction?.rawValue ?? "未标记")")
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { showCopiedTip = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { showCopiedTip = false }
        }
    }
}

// MARK: - 照片清晰度选择页面
struct PhotoQualitySelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        List {
            ForEach(SettingsManager.PhotoQuality.allCases) { quality in
                Button {
                    settings.photoQuality = quality
                } label: {
                    HStack {
                        Text(quality.description)
                            .font(.system(size: 16))
                            .foregroundColor(.primary)
                        Spacer()
                        if settings.photoQuality == quality {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("照片清晰度")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 水印文字大小选择页面
struct WatermarkFontSizeSelectionView: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        List {
            Section(header: Text("预设档位")) {
                ForEach(SettingsManager.WatermarkFontSize.allCases) { size in
                    Button {
                        settings.watermarkFontSize = size
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                // 选项文字本身按档位大小渲染，直观预览效果
                                Text(size.rawValue)
                                    .font(.system(size: previewFontSize(for: size), weight: .medium))
                                    .foregroundColor(.primary)
                                Text(size.description)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if settings.watermarkFontSize == size {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                    }
                }
            }

            Section(header: Text("精细调节"),
                    footer: Text("在所选档位基础上整体缩放，水印背景框会跟着文字一起放大或缩小。")) {
                HStack {
                    Text("字号倍率")
                    Spacer()
                    Text(String(format: "×%.2f", settings.watermarkFontScale))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.watermarkFontScale, in: 0.6...2.0, step: 0.05)
                HStack {
                    Text("更小").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("默认 ×1.00").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("更大").font(.caption).foregroundColor(.secondary)
                }
            }

            Section(header: Text("效果预览")) {
                WatermarkPreview()
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            Section {
                Button("恢复默认（中号 · ×1.00）") {
                    settings.watermarkFontSize = .medium
                    settings.watermarkFontScale = 1.0
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("水印文字大小")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func previewFontSize(for size: SettingsManager.WatermarkFontSize) -> CGFloat {
        switch size {
        case .small: return 14
        case .medium: return 17
        case .large: return 20
        }
    }
}

// MARK: - 水印文字颜色选择页面
struct WatermarkColorSelectionView: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        List {
            Section(header: Text("预设颜色")) {
                ForEach(SettingsManager.WatermarkColor.allCases) { color in
                    Button {
                        settings.watermarkColor = color
                        settings.watermarkCustomColorHex = nil
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(uiColor: color.uiColor))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color(UIColor.separator), lineWidth: 1))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(color.rawValue)
                                    .font(.system(size: 16))
                                    .foregroundColor(.primary)
                                Text(color.description)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if settings.watermarkCustomColorHex == nil && settings.watermarkColor == color {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                    }
                }
            }

            Section(header: Text("自定义颜色"),
                    footer: Text("选好任意颜色后水印立即生效；点按上方任一预设即可恢复。")) {
                ColorPicker("选择水印颜色", selection: customColorBinding, supportsOpacity: false)
                if settings.watermarkCustomColorHex != nil {
                    Button("恢复为预设颜色") {
                        settings.watermarkCustomColorHex = nil
                    }
                }
            }

            Section(header: Text("效果预览")) {
                WatermarkPreview()
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("水印文字颜色")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// ColorPicker 需要 Color 绑定，这里与存储的 16 进制互相转换
    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(uiColor: SettingsManager.shared.resolvedWatermarkColor) },
            set: { newValue in
                settings.watermarkCustomColorHex = UIColor(newValue).hexRGBString
            }
        )
    }
}

// MARK: - 水印效果预览（模拟照片上的水印条）
struct WatermarkPreview: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(white: 0.42), Color(white: 0.16)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("2026-11-22 10:30:00")
                    .font(.system(size: 16 * CGFloat(settings.watermarkFontScale), weight: .semibold))
                Text("https://example.com/product/12345")
                    .font(.system(size: 13 * CGFloat(settings.watermarkFontScale), weight: .medium))
                    .opacity(0.9)
            }
            .foregroundColor(Color(uiColor: settings.resolvedWatermarkColor))
            .shadow(color: .black.opacity(0.8), radius: 1)
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.55))
            )
            .padding(12)
        }
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 4)
    }
}

// MARK: - 扫描器包装视图
struct ScannerWrapperView: UIViewControllerRepresentable {
    var onScan: (String, String) -> Void
    var onPhotoCaptured: ((UIImage) -> Void)?
    var onPhotoCaptureFailed: ((String) -> Void)?
    @Binding var resetFlag: Bool
    @Binding var controller: QRScannerViewController?
    /// 镜头列表（0.5x / 1x / 3x…）、当前选中档位
    @Binding var lensTitles: [String]
    @Binding var selectedLensIndex: Int
    /// 微距开关 / 对焦方式 / 手动焦距（微距会改动这三项，由控制器同步回来）
    @Binding var isMacroOn: Bool
    @Binding var manualFocusOn: Bool
    @Binding var focusPosition: Double

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScan = onScan
        vc.onPhotoCaptured = onPhotoCaptured
        vc.onPhotoCaptureFailed = onPhotoCaptureFailed
        vc.onLensesChanged = { titles, index in
            lensTitles = titles
            selectedLensIndex = index
        }
        vc.onMacroStateChanged = { macro, manual, pos in
            isMacroOn = macro
            manualFocusOn = manual
            focusPosition = Double(pos)
        }
        DispatchQueue.main.async {
            controller = vc
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        uiViewController.onScan = onScan
        uiViewController.onPhotoCaptured = onPhotoCaptured
        uiViewController.onPhotoCaptureFailed = onPhotoCaptureFailed
        if resetFlag {
            uiViewController.resetScan()
            DispatchQueue.main.async {
                resetFlag = false
            }
        }
    }
}

// MARK: - 动态扫描线（上下往返移动）
struct ScanLineOverlay: View {
    @State private var scanLineOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let travelRange = min(geometry.size.width, geometry.size.height) * 0.36

            ScanLine(barWidth: travelRange * 2.4)
                .position(
                    x: geometry.size.width / 2,
                    y: geometry.size.height / 2 + scanLineOffset
                )
                .onAppear {
                    scanLineOffset = -travelRange
                    withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: true)) {
                        scanLineOffset = travelRange
                    }
                }
        }
    }
}

// MARK: - 扫描线
struct ScanLine: View {
    let barWidth: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(
                LinearGradient(
                    colors: [
                        Color.green.opacity(0),
                        Color.green.opacity(0.9),
                        Color.green.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: barWidth, height: 2)
            .shadow(color: .green.opacity(0.8), radius: 6, x: 0, y: 0)
    }
}
