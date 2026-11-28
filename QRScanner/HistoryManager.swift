//
//  HistoryManager.swift
//  QRScanner
//
//  Created by 史冬亮 on 2026/8/14.
//

import Foundation
import UIKit
import Combine

class HistoryManager: ObservableObject {
    static let shared = HistoryManager()
    private let key = "qr_scan_history"

    @Published var records: [ScanRecord] = []

    private init() {
        loadRecords()
    }

    @discardableResult
    func addRecord(content: String, source: ScanRecord.ScanSource, symbology: String = "未知", direction: ScanRecord.VINDirection? = nil) -> UUID {
        let record = ScanRecord(content: content, source: source, symbology: symbology, direction: direction)
        records.insert(record, at: 0)
        saveRecords()
        return record.id
    }

    /// 拍照拍完后再选择入库/出库：回填方向到已保存的记录
    func updateDirection(recordID: UUID, direction: ScanRecord.VINDirection) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        let old = records[index]
        records[index] = ScanRecord(id: old.id, content: old.content, timestamp: old.timestamp,
                                    source: old.source, symbology: old.symbology, direction: direction)
        saveRecords()
    }

    /// 刚扫过的相同内容（连拍抖动 / 相机同一码反复上报）
    func hasRecentRecord(content: String, within seconds: TimeInterval = 5) -> Bool {
        let now = Date()
        return records.contains { $0.content == content && now.timeIntervalSince($0.timestamp) < seconds }
    }

    /// 相同内容 + 相同方向是否已存在（去掉正在补方向的那条）
    func hasRecord(content: String, direction: ScanRecord.VINDirection, excluding recordID: UUID?) -> Bool {
        records.contains { $0.content == content && $0.direction == direction && $0.id != recordID }
    }

    /// 相同内容是否已存在（相册导入去重用）
    func hasAnyRecord(content: String) -> Bool {
        records.contains { $0.content == content }
    }

    func removeRecord(id: UUID) {
        records.removeAll { $0.id == id }
        saveRecords()
    }

    func deleteRecord(_ record: ScanRecord) {
        records.removeAll { $0.id == record.id }
        saveRecords()
    }

    func clearAllRecords() {
        records.removeAll()
        saveRecords()
    }

    func copyToClipboard(_ content: String) {
        UIPasteboard.general.string = content
    }

    func searchRecords(query: String) -> [ScanRecord] {
        guard !query.isEmpty else { return records }
        let lowerQuery = query.lowercased()
        return records.filter {
            $0.content.lowercased().contains(lowerQuery) ||
            $0.formattedTime.lowercased().contains(lowerQuery) ||
            $0.symbology.lowercased().contains(lowerQuery) ||
            $0.typeName.lowercased().contains(lowerQuery)
        }
    }


    /// 批量导入（来自 TXT / CSV / JSON 文件）。
    /// 去重口径：内容 + 方向都相同才视为重复；保留文件里的原始时间。
    @discardableResult
    func importRecords(_ incoming: [ScanRecord]) -> (added: Int, duplicates: Int) {
        var added = 0
        var duplicates = 0
        var merged = records
        for item in incoming {
            let isDuplicate = merged.contains { $0.content == item.content && $0.direction == item.direction }
            if isDuplicate {
                duplicates += 1
                continue
            }
            merged.append(item)
            added += 1
        }
        guard added > 0 else { return (0, duplicates) }
        merged.sort { $0.timestamp > $1.timestamp }
        records = merged
        saveRecords()
        return (added, duplicates)
    }

    private func saveRecords() {
        if let encoded = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
        // 记录变动后自动往 iCloud 备份一份（开关在「数据」页里控制）
        ICloudBackupManager.shared.scheduleAutoBackup()
    }

    private func loadRecords() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ScanRecord].self, from: data) else {
            return
        }
        records = decoded
    }
}
