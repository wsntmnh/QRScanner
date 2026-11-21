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

    /// 历史记录上限，超出后自动淘汰最旧的记录，防止 UserDefaults 无限膨胀
    private let maxRecords = 500

    @Published var records: [ScanRecord] = []

    private init() {
        loadRecords()
    }

    func addRecord(content: String, source: ScanRecord.ScanSource, symbology: String = "未知") {
        let record = ScanRecord(content: content, source: source, symbology: symbology)
        records.insert(record, at: 0)
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
        saveRecords()
        StatisticsManager.shared.incrementScanCount()
    }

    func deleteRecord(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            records.remove(at: index)
        }
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

    private func saveRecords() {
        if let encoded = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    private func loadRecords() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ScanRecord].self, from: data) else {
            return
        }
        records = decoded
    }
}
