//
//  SettingsManager.swift
//  QRScanner
//
//  Created by 史冬亮 on 2026/8/15.
//

import Foundation
import CoreGraphics
import Combine
import AVFoundation
import UIKit
import CoreImage

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    private let autoSavePhotoKey = "auto_save_photo_enabled"
    private let playShutterSoundKey = "play_shutter_sound_enabled"
    private let autoCaptureKey = "auto_capture_enabled"
    private let photoQualityKey = "photo_quality_preset"
    private let watermarkFontSizeKey = "watermark_font_size"
    private let showLocationInWatermarkKey = "show_location_in_watermark"
    private let watermarkColorKey = "watermark_color_key"
    private let watermarkFontScaleKey = "watermark_font_scale"
    private let watermarkCustomColorKey = "watermark_custom_color_hex"
    
    // MARK: 水印文字颜色选项
    enum WatermarkColor: String, CaseIterable, Identifiable {
        case white = "白色"
        case black = "黑色"
        case yellow = "黄色"
        case red = "红色"
        case green = "绿色"
        
        var id: String { rawValue }
        
        var uiColor: UIColor {
            switch self {
            case .white: return .white
            case .black: return .black
            case .yellow: return .systemYellow
            case .red: return .systemRed
            case .green: return .systemGreen
            }
        }
        
        var description: String {
            switch self {
            case .white: return "白色（照片默认，对比度高）"
            case .black: return "黑色，适合亮背景照片"
            case .yellow: return "黄色，醒目"
            case .red: return "红色"
            case .green: return "绿色"
            }
        }
    }
    
    enum PhotoQuality: String, CaseIterable, Identifiable {
        case low = "低"
        case medium = "中"
        case high = "高"
        case photo = "最高"
        
        var id: String { rawValue }
        
        /// AVCaptureSession 会话采集预设（相机预览流）
        /// 关键：一维码最窄的条只有 1–2 像素宽，采集流低于 720p 时条码基本解不出来，
        /// 所以低/中档不再使用 .low(192x144)/.medium(480x360)，统一抬到 720p / 1080p。
        /// 高档与最高档直接用 .photo（全传感器分辨率），兼顾文字细节与远距离条码。
        var sessionPreset: AVCaptureSession.Preset {
            switch self {
            case .low: return .hd1280x720
            case .medium: return .hd1920x1080
            case .high: return .photo
            case .photo: return .photo
            }
        }
        
        /// 输出图片最大像素边长（拍照后重采样缩放，真正控制文件分辨率）
        var maxOutputPixelSide: CGFloat {
            switch self {
            case .low:    return 1280
            case .medium: return 1920
            case .high:   return 3000
            case .photo:  return 0 // 0 = 不缩放，使用原始相机像素
            }
        }
        
        /// ✅ JPEG压缩质量 0~1，越大越清晰，文件越大
        var jpegQuality: CGFloat {
            switch self {
            case .low:    return 0.60
            case .medium: return 0.78
            case .high:   return 0.90
            case .photo:  return 0.98
            }
        }
        
        /// ✅ 是否开启锐化提升画面清晰度
        var enableSharpen: Bool {
            switch self {
            case .low, .medium: return false
            case .high, .photo: return true
            }
        }
        
        var description: String {
            switch self {
            case .low: return "低清晰度，最长边1280像素（采集仍保持720p，不影响扫码）"
            case .medium: return "中等清晰度，最长边1920像素，平衡画质与体积"
            case .high: return "高清晰度，最长边3000像素，开启锐化"
            case .photo: return "最高清晰度，原始相机像素，开启锐化"
            }
        }
    }

    /// 水印文字大小档位，绘制水印时映射为实际字体大小
    enum WatermarkFontSize: String, CaseIterable, Identifiable {
        case small = "小"
        case medium = "中"
        case large = "大"

        var id: String { rawValue }

        /// 时间水印字体大小
        var timeFontSize: CGFloat {
            switch self {
            case .small: return 13
            case .medium: return 20
            case .large: return 27
            }
        }

        /// 内容水印字体大小
        var contentFontSize: CGFloat {
            switch self {
            case .small: return 10
            case .medium: return 16
            case .large: return 22
            }
        }

        var description: String {
            switch self {
            case .small: return "小字号，水印更低调"
            case .medium: return "中等字号（默认）"
            case .large: return "大字号，远距离更清晰"
            }
        }
    }
    
    @Published var autoSavePhoto: Bool {
        didSet {
            UserDefaults.standard.set(autoSavePhoto, forKey: autoSavePhotoKey)
        }
    }
    
    /// 自动拍照：识别到码后不再等用户按快门，立即自动拍一张（拍完走预览，是否存相册由“扫描后拍照预览”决定）
    @Published var autoCaptureEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoCaptureEnabled, forKey: autoCaptureKey)
        }
    }

    @Published var playShutterSound: Bool {
        didSet {
            UserDefaults.standard.set(playShutterSound, forKey: playShutterSoundKey)
        }
    }
    
    @Published var photoQuality: PhotoQuality {
        didSet {
            UserDefaults.standard.set(photoQuality.rawValue, forKey: photoQualityKey)
        }
    }

    @Published var watermarkFontSize: WatermarkFontSize {
        didSet {
            UserDefaults.standard.set(watermarkFontSize.rawValue, forKey: watermarkFontSizeKey)
        }
    }

    /// 是否在水印中附加当前位置信息
    @Published var showLocationInWatermark: Bool {
        didSet {
            UserDefaults.standard.set(showLocationInWatermark, forKey: showLocationInWatermarkKey)
        }
    }
    
    /// ✅ 水印文字颜色
    @Published var watermarkColor: WatermarkColor {
        didSet {
            UserDefaults.standard.set(watermarkColor.rawValue, forKey: watermarkColorKey)
        }
    }

    /// 水印字号倍率：在所选档位基础上整体放大/缩小（0.6 ~ 2.0，1.0 为档位原始大小）
    @Published var watermarkFontScale: Double {
        didSet {
            UserDefaults.standard.set(watermarkFontScale, forKey: watermarkFontScaleKey)
        }
    }

    /// 自定义水印颜色（6 位 16 进制，如 "E53935"）；nil 表示使用预设颜色
    @Published var watermarkCustomColorHex: String? {
        didSet {
            if let hex = watermarkCustomColorHex {
                UserDefaults.standard.set(hex, forKey: watermarkCustomColorKey)
            } else {
                UserDefaults.standard.removeObject(forKey: watermarkCustomColorKey)
            }
        }
    }

    /// 绘制水印时真正使用的颜色：自定义色优先，否则用预设色
    var resolvedWatermarkColor: UIColor {
        if let hex = watermarkCustomColorHex, let color = UIColor(hexString: hex) {
            return color
        }
        return watermarkColor.uiColor
    }

    /// 设置页副标题：当前颜色描述
    var watermarkColorSummary: String {
        watermarkCustomColorHex == nil ? watermarkColor.rawValue : "自定义颜色"
    }
    
    private init() {
        self.autoSavePhoto = UserDefaults.standard.bool(forKey: autoSavePhotoKey)
        self.playShutterSound = UserDefaults.standard.object(forKey: playShutterSoundKey) as? Bool ?? true
        self.autoCaptureEnabled = UserDefaults.standard.bool(forKey: autoCaptureKey)
        
        let savedQuality = UserDefaults.standard.string(forKey: photoQualityKey)
        self.photoQuality = PhotoQuality.allCases.first { $0.rawValue == savedQuality } ?? .photo

        let savedWatermarkSize = UserDefaults.standard.string(forKey: watermarkFontSizeKey)
        self.watermarkFontSize = WatermarkFontSize.allCases.first { $0.rawValue == savedWatermarkSize } ?? .medium

        self.showLocationInWatermark = UserDefaults.standard.object(forKey: showLocationInWatermarkKey) as? Bool ?? false
        
        // ✅ 读取保存的水印颜色，默认白色
        let savedColor = UserDefaults.standard.string(forKey: watermarkColorKey)
        self.watermarkColor = WatermarkColor.allCases.first { $0.rawValue == savedColor } ?? .white

        let savedFontScale = UserDefaults.standard.object(forKey: watermarkFontScaleKey) as? Double
        self.watermarkFontScale = savedFontScale ?? 1.0
        self.watermarkCustomColorHex = UserDefaults.standard.string(forKey: watermarkCustomColorKey)
    }
    
    /// 水印排版的设计基准宽度（像素）。
    /// 字号、内边距、边距、圆角等都按「图片实际宽度 / 该基准」等比缩放，
    /// 保证低清晰度与最高清晰度下拍到的大图，水印观感一致。
    static let watermarkDesignWidth: CGFloat = 1280

    // MARK: 图片处理入口：缩放 + 锐化
    func processPhoto(_ image: UIImage) -> UIImage {
        let quality = photoQuality
        var resultImg = scaleImage(image, maxSide: quality.maxOutputPixelSide)
        
        if quality.enableSharpen {
            resultImg = sharpenImage(resultImg, radius:0.8, sharpness:0.35)
        }
        return resultImg
    }
    
    // MARK: 图片缩放工具：按最长边限制像素，保持宽高比
    /// 将UIImage按最大边长缩放，maxSide=0返回原图不缩放
    func scaleImage(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        guard maxSide > 0 else { return image }
        
        let originalSize = image.size
        let scale: CGFloat
        if originalSize.width > originalSize.height {
            scale = maxSide / originalSize.width
        } else {
            scale = maxSide / originalSize.height
        }
        if scale >= 1.0 { return image }
        
        let newSize = CGSize(width: originalSize.width * scale, height: originalSize.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, true, image.scale)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let scaled = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return scaled ?? image
    }
    
    // MARK: CoreImage 锐化（提升观感清晰度）
    /// 锐化，radius范围0~2，sharpness建议0.2~0.5，不要过高
    private func sharpenImage(_ image: UIImage, radius: Float, sharpness: Float) -> UIImage {
        guard let cgImg = image.cgImage else { return image }
        let ciInput = CIImage(cgImage: cgImg)
        guard let filter = CIFilter(name: "CISharpenLuminance") else { return image }
        filter.setValue(ciInput, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        filter.setValue(sharpness, forKey: kCIInputSharpnessKey)
        
        guard let ciOutput = filter.outputImage else { return image }
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let outCGImage = ciContext.createCGImage(ciOutput, from: ciOutput.extent) else {
            return image
        }
        return UIImage(cgImage: outCGImage, scale: image.scale, orientation: image.imageOrientation)
    }
}

// MARK: - UIColor 与 16 进制互转（自定义水印颜色持久化用）
extension UIColor {
    /// 从 6 位 16 进制字符串创建颜色，支持 "#RRGGBB" 或 "RRGGBB"
    convenience init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    /// 转成 6 位 16 进制字符串（不含 #），转换失败返回 nil
    var hexRGBString: String? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(
            format: "%02X%02X%02X",
            UInt32(round(max(0, min(1, r)) * 255)),
            UInt32(round(max(0, min(1, g)) * 255)),
            UInt32(round(max(0, min(1, b)) * 255))
        )
    }
}
