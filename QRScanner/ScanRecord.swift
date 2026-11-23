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
    
    enum ScanSource: String, Codable {
        case camera = "相机"
        case photoLibrary = "相册"
    }
    
    private static let sharedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()
    
    init(id: UUID = UUID(), content: String, timestamp: Date = Date(), source: ScanSource, symbology: String = "未知") {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.source = source
        self.symbology = symbology
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
