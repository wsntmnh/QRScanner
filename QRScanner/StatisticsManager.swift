//
//  StatisticsManager.swift
//  QRScanner
//
//  Created by 史冬亮 on 2026/8/18.
//  功能: 管理扫描统计数据的存储与查询，支持按小时和按天统计。
//  存储: 使用 UserDefaults 持久化，自动清理 90 天前的旧数据。
//  线程安全: 所有写操作通过 serialQueue 同步。
//

import Foundation
import Combine

class StatisticsManager: ObservableObject {
    static let shared = StatisticsManager()

    private let hourlyKey = "qr_scan_hourly_stats"
    private let dailyKey  = "qr_scan_daily_stats"
    private let allTimeTotalKey = "qr_scan_total_all_time"
    private let retentionDays = 90

    private let serialQueue = DispatchQueue(label: "com.qrscanner.statistics", qos: .utility)
    private var _hourlyData: [String: Int] = [:]
    private var _dailyData:  [String: Int] = [:]

    // 修复：增加 @Published 属性，扫码后统计页摘要实时刷新，
    // 避免"扫码后立刻打开统计页看到旧数据"的问题
    @Published private(set) var todayTotal: Int = 0
    /// 累计总扫描量（不受 90 天清理影响）
    @Published private(set) var allTimeTotal: Int = 0

    private init() {
        loadData()
        allTimeTotal = UserDefaults.standard.integer(forKey: allTimeTotalKey)
        todayTotal = todayScans()
    }

    // MARK: - 公开接口

    /// 记录一次扫描（自动记录当前小时和当天）
    func incrementScanCount() {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            let now = Date()
            let hourKey = self.hourKey(for: now)
            let dayKey  = self.dayKey(for: now)

            self._hourlyData[hourKey, default: 0] += 1
            self._dailyData[dayKey,  default: 0] += 1

            self.cleanupOldData()
            self.saveData()

            let today = self._dailyData[dayKey, default: 0]
            let newAllTime = UserDefaults.standard.integer(forKey: self.allTimeTotalKey) + 1
            UserDefaults.standard.set(newAllTime, forKey: self.allTimeTotalKey)

            DispatchQueue.main.async {
                self.todayTotal = today
                self.allTimeTotal = newAllTime
            }
        }
    }

    /// 获取某天的 24 小时统计数据
    func hourlyStats(for date: Date) -> [(hour: Int, count: Int)] {
        let dayPrefix = dayKey(for: date)
        var result: [(hour: Int, count: Int)] = []
        for hour in 0..<24 {
            let key = "\(dayPrefix)-\(String(format: "%02d", hour))"
            let count = serialQueue.sync { self._hourlyData[key, default: 0] }
            result.append((hour, count))
        }
        return result
    }

    /// 获取最近 N 天的每天统计数据
    func dailyStats(days: Int) -> [(date: String, count: Int)] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "zh_CN")

        var result: [(date: String, count: Int)] = []
        for offset in (0..<days).reversed() {
            if let date = calendar.date(byAdding: .day, value: -offset, to: Date()) {
                let key = dayKey(for: date)
                let display = formatter.string(from: date)
                let count = serialQueue.sync { self._dailyData[key, default: 0] }
                result.append((display, count))
            }
        }
        return result
    }

    /// 今日扫描次数
    func todayScans() -> Int {
        let key = dayKey(for: Date())
        return serialQueue.sync { self._dailyData[key, default: 0] }
    }

    /// 最近 N 天日均扫描量
    func averageDailyScans(days: Int) -> Double {
        let stats = dailyStats(days: days)
        let total = stats.reduce(0) { $0 + $1.count }
        return Double(total) / Double(days)
    }

    // MARK: - 私有方法

    private func hourKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    private func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    private func saveData() {
        if let hourlyEncoded = try? JSONEncoder().encode(_hourlyData),
           let dailyEncoded  = try? JSONEncoder().encode(_dailyData) {
            UserDefaults.standard.set(hourlyEncoded, forKey: hourlyKey)
            UserDefaults.standard.set(dailyEncoded,  forKey: dailyKey)
        }
    }

    private func loadData() {
        if let hourlyData = UserDefaults.standard.data(forKey: hourlyKey),
           let decodedHourly = try? JSONDecoder().decode([String: Int].self, from: hourlyData) {
            _hourlyData = decodedHourly
        }
        if let dailyData = UserDefaults.standard.data(forKey: dailyKey),
           let decodedDaily = try? JSONDecoder().decode([String: Int].self, from: dailyData) {
            _dailyData = decodedDaily
        }
    }

    private func cleanupOldData() {
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        let cutoffDayKey = dayKey(for: cutoffDate)
        let cutoffHourKey = hourKey(for: cutoffDate)

        _dailyData = _dailyData.filter { $0.key >= cutoffDayKey }
        _hourlyData = _hourlyData.filter { $0.key >= cutoffHourKey }
    }
}
