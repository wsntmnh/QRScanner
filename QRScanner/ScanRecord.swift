//
//  ScanRecord.swift
//  QRScanner
//
//  Created by 史冬亮 on 2026/8/14.
//

import Foundation

struct ScanRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let content: String
    let timestamp: Date
    let source: ScanSource
    let symbology: String  // 码制类型
    /// 车架号的出入库方向：扫码时选择，未选（或非车架号）为 nil
    let direction: VINDirection?
    
    enum ScanSource: String, Codable {
        case camera = "相机"
        case photoLibrary = "相册"
    }

    /// 出入库方向
    enum VINDirection: String, Codable, CaseIterable, Identifiable {
        case inbound = "入库"
        case outbound = "出库"
        case transfer = "移库"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .inbound: return "arrow.down.to.line"
            case .outbound: return "arrow.up.to.line"
            case .transfer: return "arrow.left.arrow.right"
            }
        }
    }
    
    private static let sharedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()
    
    init(id: UUID = UUID(), content: String, timestamp: Date = Date(), source: ScanSource, symbology: String = "未知", direction: VINDirection? = nil) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.source = source
        self.symbology = symbology
        self.direction = direction
    }

    /// 从任意扫码内容里取出 17 位车架号：允许前后带 "VIN:"、空格、括号等噪声。
    /// 先按整串严格判定，再清洗出字母数字、找 17 位且不含 I/O/Q 的片段。
    static func vinInText(_ content: String) -> String? {
        if let exact = vinString(from: content) { return exact }

        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let cleaned = String(content.uppercased().unicodeScalars.filter { allowed.contains($0) }.map(Character.init))
        let chars = Array(cleaned)
        guard chars.count >= 17 else { return nil }
        let banned: Set<Character> = ["I", "O", "Q"]
        for start in 0...(chars.count - 17) {
            let candidate = String(chars[start..<(start + 17)])
            if !candidate.contains(where: { banned.contains($0) }) { return candidate }
        }
        return nil
    }

    /// 完整车架号判定：17 位、字母数字、不含 I/O/Q（VIN 规范禁用），统一转大写
    static func vinString(from content: String) -> String? {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.count == 17 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHJKLMNPRSTUVWXYZ0123456789")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }
    
    var formattedTime: String {
        let formatter = ScanRecord.sharedFormatter
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: timestamp)
    }
    
    // 判断是二维码还是条形码
    var isBarcode: Bool {
        let barcodes = [
            "EAN-8", "EAN-13", "UPC-E", "Code 39", "Code 93", "Code 128",
            "Interleaved 2 of 5", "ITF14",
            "GS1 DataBar", "GS1 DataBar Limited", "GS1 DataBar Expanded"
        ]
        return barcodes.contains(symbology)
    }
    
    var typeIcon: String {
        return isBarcode ? "barcode" : "qrcode"
    }
    
    var typeName: String {
        return isBarcode ? "条形码" : "二维码"
    }
}
