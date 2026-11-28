//
//  ICloudBackupManager.swift
//  QRScanner
//
//  iCloud 自动备份：把全部扫描记录打成一份 JSON 快照
//  1) iCloud 键值存储（NSUbiquitousKeyValueStore）：开了 iCloud 能力时可在多台设备间同步
//  2) App 沙盒 Documents/QRScanner-backup.json：随 iPhone 的 iCloud 备份一起走，不依赖应用能力
//

import Foundation
import Combine

final class ICloudBackupManager: ObservableObject {
    static let shared = ICloudBackupManager()

    private let kv = NSUbiquitousKeyValueStore.default
    private let snapshotKey = "qrscanner.snapshot.v1"
    private let dateKey = "qrscanner.snapshot.date"
    private let localFileName = "QRScanner-backup.json"

    /// 最近一次备份时间（云端与本地取较新者）
    @Published private(set) var lastBackupDate: Date?
    /// 云端快照里的记录条数
    @Published private(set) var cloudRecordCount: Int = 0
    /// iCloud 是否真的可用（未登录 / 没开能力时为 false）
    @Published private(set) var cloudAvailable: Bool = false
    /// 最近一次操作结果，用于界面提示
    @Published private(set) var statusText: String = ""

    private var pendingWork: DispatchWorkItem?

    private init() {
        cloudAvailable = FileManager.default.ubiquityIdentityToken != nil
        kv.synchronize()
        lastBackupDate = (kv.object(forKey: dateKey) as? Date) ?? localBackupDate()
        cloudRecordCount = cloudSnapshot()?.count ?? 0

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.cloudAvailable = true
            self.lastBackupDate = (self.kv.object(forKey: self.dateKey) as? Date) ?? self.lastBackupDate
            self.cloudRecordCount = self.cloudSnapshot()?.count ?? self.cloudRecordCount
        }
    }

    // MARK: - 自动备份

    /// 记录有变动时调用：延迟 3 秒合并写入，避免连扫时反复落地
    func scheduleAutoBackup() {
        guard SettingsManager.shared.iCloudAutoBackup else { return }
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.backupNow(showStatus: false)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - 立即备份

    @discardableResult
    func backupNow(showStatus: Bool = true) -> Bool {
        let records = HistoryManager.shared.records
        guard let data = try? JSONEncoder().encode(records) else {
            if showStatus { statusText = "备份失败：记录编码异常" }
            return false
        }

        // 1) iCloud 键值存储（超过 1MB 时 iOS 会拒绝，500 条上限下远小于该值）
        if data.count < 900_000 {
            kv.set(data, forKey: snapshotKey)
            kv.set(Date(), forKey: dateKey)
            kv.synchronize()
        }

        // 2) 本地 Documents 快照（随 iPhone 备份一起进 iCloud）
        var localOK = false
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = dir.appendingPathComponent(localFileName)
            localOK = (try? data.write(to: url, options: .atomic)) != nil
        }

        lastBackupDate = Date()
        cloudRecordCount = records.count
        cloudAvailable = kv.object(forKey: snapshotKey) != nil || FileManager.default.ubiquityIdentityToken != nil
        if showStatus {
            statusText = localOK
                ? "已备份 \(records.count) 条记录"
                : "已写入 iCloud，但本地快照写入失败"
        }
        return localOK || kv.object(forKey: snapshotKey) != nil
    }

    // MARK: - 从 iCloud 恢复

    /// 恢复并合并（内容 + 方向相同视为重复，自动跳过），返回新增条数与云端总条数
    func restoreFromCloud() -> (added: Int, cloudTotal: Int)? {
        guard let snapshot = cloudSnapshot() else {
            statusText = "iCloud 里还没有备份"
            return nil
        }
        let outcome = HistoryManager.shared.importRecords(snapshot)
        statusText = "恢复完成：新增 \(outcome.added) 条，跳过重复 \(outcome.duplicates) 条"
        return (outcome.added, snapshot.count)
    }

    // MARK: - 内部

    private func cloudSnapshot() -> [ScanRecord]? {
        if let data = kv.data(forKey: snapshotKey),
           let records = try? JSONDecoder().decode([ScanRecord].self, from: data) {
            return records
        }
        // 本地快照兜底（同一台设备重装后也能拿回来）
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = dir.appendingPathComponent(localFileName)
            if let data = try? Data(contentsOf: url),
               let records = try? JSONDecoder().decode([ScanRecord].self, from: data) {
                return records
            }
        }
        return nil
    }

    private func localBackupDate() -> Date? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let url = dir.appendingPathComponent(localFileName)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    var summaryText: String {
        let n = HistoryManager.shared.records.count
        guard let date = lastBackupDate else {
            return n == 0 ? "暂无记录" : "尚未备份，共 \(n) 条记录"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return "上次备份 \(formatter.string(from: date))，本地 \(n) 条"
    }
}
