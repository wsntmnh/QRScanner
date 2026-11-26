//
//  HistoryView.swift
//  QRScanner
//
//  Created by 史冬亮 on 2026/8/14.
//

import SwiftUI
import UIKit

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var historyManager = HistoryManager.shared
    @State private var showClearConfirm = false
    @State private var copiedId: UUID?
    @State private var searchText = ""
    @State private var isSearching = false

    private var filteredRecords: [ScanRecord] {
        historyManager.searchRecords(query: searchText)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    SearchBar(text: $searchText, isSearching: $isSearching)
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 8)

                    if filteredRecords.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: searchText.isEmpty ? "barcode.viewfinder" : "magnifyingglass")
                                .font(.system(size: 60))
                                .foregroundColor(.gray.opacity(0.5))
                            Text(searchText.isEmpty ? "暂无扫描记录" : "未找到匹配记录")
                                .font(.system(size: 16))
                                .foregroundColor(.gray)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(filteredRecords) { record in
                                RecordRow(record: record, copiedId: $copiedId)
                            }
                            .onDelete { indexSet in
                                let toDelete = indexSet.map { filteredRecords[$0] }
                                for record in toDelete {
                                    historyManager.deleteRecord(record)
                                }
                            }

                            if searchText.isEmpty {
                                Section {
                                    Button(role: .destructive) {
                                        showClearConfirm = true
                                    } label: {
                                        HStack {
                                            Spacer()
                                            Text("清空所有记录")
                                            Spacer()
                                        }
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }
            }
            .navigationTitle("扫描历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .alert("确认清空", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    historyManager.clearAllRecords()
                }
            } message: {
                Text("此操作不可撤销，确定要清空所有扫描记录吗？")
            }
        }
    }
}

struct SearchBar: UIViewRepresentable {
    @Binding var text: String
    @Binding var isSearching: Bool

    func makeUIView(context: Context) -> UISearchBar {
        let searchBar = UISearchBar()
        searchBar.delegate = context.coordinator
        searchBar.placeholder = "搜索内容、日期或码制..."
        searchBar.searchBarStyle = .minimal
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.returnKeyType = .search
        searchBar.enablesReturnKeyAutomatically = false
        return searchBar
    }

    func updateUIView(_ uiView: UISearchBar, context: Context) {
        // 修复：仅在文本真正变化时赋值，避免 SwiftUI 重绘打断输入、导致光标跳动或中文组词中断
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UISearchBarDelegate {
        let parent: SearchBar

        init(_ parent: SearchBar) {
            self.parent = parent
        }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            parent.text = searchText
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            parent.isSearching = true
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            parent.isSearching = false
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
        }
    }
}

struct RecordRow: View {
    let record: ScanRecord
    @Binding var copiedId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.content)
                    .font(.system(size: 15))
                    .lineLimit(3)
                    .foregroundColor(.primary)

                Spacer()

                if copiedId == record.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 18))
                        .transition(.scale.combined(with: .opacity))
                }
            }

            HStack(spacing: 8) {
                Label(record.symbology, systemImage: record.typeIcon)
                    .font(.system(size: 11))
                    .foregroundColor(record.isBarcode ? .orange : .blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (record.isBarcode ? Color.orange : Color.blue)
                            .opacity(0.12)
                    )
                    .clipShape(Capsule())

                Label(record.source.rawValue, systemImage: record.source == .camera ? "camera.fill" : "photo.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.gray.opacity(0.12))
                    .clipShape(Capsule())

                Text(record.formattedTime)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Spacer()
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                HistoryManager.shared.deleteRecord(record)
            } label: {
                Label("删除", systemImage: "trash")
            }

            Button {
                HistoryManager.shared.copyToClipboard(record.content)
                withAnimation(.spring(response: 0.3)) {
                    copiedId = record.id
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation {
                        copiedId = nil
                    }
                }
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .tint(.blue)
        }
    }
}


// MARK: - 数据整理与导出

/// 导出时间范围
enum ExportTimeRange: String, CaseIterable, Identifiable {
    case today = "今天"
    case week = "近 7 天"
    case month = "近 30 天"
    case day = "指定某一天"
    case all = "全部"

    var id: String { rawValue }

    /// 时间区间（start 含、end 不含；nil 表示该端不限制）
    /// 「指定某一天」取所选日期的 0 点到次日 0 点
    func interval(selectedDay: Date) -> (start: Date?, end: Date?) {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        switch self {
        case .today: return (todayStart, nil)
        case .week: return (calendar.date(byAdding: .day, value: -6, to: todayStart), nil)
        case .month: return (calendar.date(byAdding: .day, value: -29, to: todayStart), nil)
        case .day:
            let dayStart = calendar.startOfDay(for: selectedDay)
            return (dayStart, calendar.date(byAdding: .day, value: 1, to: dayStart))
        case .all: return (nil, nil)
        }
    }
}

/// 导出格式
enum ExportFormat: String, CaseIterable, Identifiable {
    case csv = "CSV（Excel 可打开）"
    case json = "JSON（结构化）"
    case txt = "TXT（纯文本）"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        case .txt: return "txt"
        }
    }
}

/// 只导出车架号时的 JSON 结构：合计条数 + 车架号清单
private struct VinExportItem: Encodable {
    let vin: String
    let time: String
}

private struct VinExportPayload: Encodable {
    let total: Int
    let items: [VinExportItem]
}

/// 完整导出时的 JSON 结构：合计条数 + 原始记录
private struct RecordExportPayload: Encodable {
    let total: Int
    let items: [ScanRecord]
}

struct DataExportView: View {
    @ObservedObject private var historyManager = HistoryManager.shared

    @State private var range: ExportTimeRange = .all
    /// 「指定某一天」用的日期
    @State private var selectedDay = Date()
    @State private var format: ExportFormat = .csv
    /// 车架号（VIN）前 5 位前缀筛选，"全部" 表示不按前缀过滤
    @State private var vinPrefixFilter = "全部"
    /// 只导出完整车架号：开启后仅保留能被识别为完整 VIN 的记录，导出文件只含车架号
    @State private var vinOnly = true
    @State private var copiedCount = 0
    @State private var showCopied = false
    @State private var shareURL: URL?
    @State private var showShare = false

    // MARK: 数据整理

    /// 按「时间范围 + 车架号前缀」筛选后的记录（保持最新在前）
    private var exportRecords: [ScanRecord] {
        let bounds = range.interval(selectedDay: selectedDay)
        return historyManager.records.filter { record in
            if let start = bounds.start, record.timestamp < start { return false }
            if let end = bounds.end, record.timestamp >= end { return false }
            if vinOnly, vinString(of: record.content) == nil { return false }
            if vinPrefixFilter != "全部" {
                guard let prefix = vinPrefix(of: record.content), prefix == vinPrefixFilter else { return false }
            }
            return true
        }
    }

    /// 车架号（VIN）判定：17 位字母数字、不含 I/O/Q（VIN 规范禁用这三个字母）。
    /// 车架号的第 1–3 位是制造商代码（WMI），前 5 位即「制造商 + 车型系列」标识，适合做归类键。
    private func vinString(of content: String) -> String? {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.count == 17 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHJKLMNPRSTUVWXYZ0123456789")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    private func vinPrefix(of content: String) -> String? {
        vinString(of: content).map { String($0.prefix(5)) }
    }

    /// 车架号前 5 位 / 前 3 位（WMI）对应的品牌名。
    /// 5 位优先（同厂家不同车型系列），认不出 5 位再退回 3 位 WMI；都没有则只显示前缀。
    /// 需要补品牌时，直接在这里加一行即可。
    private static let vinBrands: [String: String] = [
        // 5 位：具体车型系列
        "LSJEM": "尚界",
        "LSJEK": "荣威",
        // 3 位：WMI 厂家（作为兜底）
        "LSV": "上汽大众",
        "LFV": "一汽-大众",
        "LSG": "上汽通用",
        "LSJ": "上汽乘用车",
        "LGB": "东风日产",
        "LGW": "长城汽车",
        "LVG": "广汽丰田",
        "LHG": "广汽本田",
        "LFM": "一汽丰田",
        "LZW": "上汽通用五菱",
        "LVS": "长安福特",
        "LDC": "神龙汽车"
    ]

    private func brandName(for prefix: String) -> String? {
        if let exact = Self.vinBrands[prefix] { return exact }
        return Self.vinBrands[String(prefix.prefix(3))]
    }

    /// 现有记录里的车架号前缀分布（按条数降序）
    private var vinPrefixGroups: [(prefix: String, count: Int)] {
        var counts: [String: Int] = [:]
        for record in historyManager.records {
            if let prefix = vinPrefix(of: record.content) {
                counts[prefix, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (prefix: $0.key, count: $0.value) }
    }

    /// 当前筛选结果里含车架号的条数
    private var vinRecordCount: Int {
        exportRecords.filter { vinPrefix(of: $0.content) != nil }.count
    }

    // MARK: 文本生成

    private var exportText: String {
        let records = exportRecords
        guard !records.isEmpty else { return "" }
        switch format {
        case .csv: return csvText(records)
        case .json: return jsonText(records)
        case .txt: return txtText(records)
        }
    }

    private var fileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "QRScanner-扫描记录-\(formatter.string(from: Date())).\(format.fileExtension)"
    }

    private func csvText(_ records: [ScanRecord]) -> String {
        if vinOnly {
            var lines = ["车架号,扫描时间"]
            for record in records {
                guard let vin = vinString(of: record.content) else { continue }
                lines.append([vin, record.formattedTime]
                    .map(csvField).joined(separator: ","))
            }
            lines.append("合计,\(lines.count - 1) 条")
            return lines.joined(separator: "\n")
        }
        var lines = ["序号,时间,来源,码制,类型,内容"]
        for (index, record) in records.enumerated() {
            let fields = [
                "\(index + 1)",
                record.formattedTime,
                record.source.rawValue,
                record.symbology,
                record.typeName,
                record.content
            ]
            lines.append(fields.map(csvField).joined(separator: ","))
        }
        lines.append("合计,\(records.count) 条")
        return lines.joined(separator: "\n")
    }

    private func jsonText(_ records: [ScanRecord]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]

        if vinOnly {
            let items = records.compactMap { record -> VinExportItem? in
                guard let vin = vinString(of: record.content) else { return nil }
                return VinExportItem(vin: vin, time: record.formattedTime)
            }
            guard let data = try? encoder.encode(VinExportPayload(total: items.count, items: items)),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }

        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(RecordExportPayload(total: records.count, items: records)),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private func txtText(_ records: [ScanRecord]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "zh_CN")

        var lines: [String] = [
            "# QRScanner 扫描记录导出",
            "# 范围：\(range.rawValue) 条数：\(records.count)",
            "# 导出时间：\(formatter.string(from: Date()))",
            "# 时间\t来源\t码制\t类型\t内容"
        ]
        if vinOnly {
            var vinLines: [String] = [
                "# QRScanner 车架号导出",
                "# 范围：\(range.rawValue)，条数：\(records.count)",
                "# 导出时间：\(formatter.string(from: Date()))",
                "# 车架号\t扫描时间"
            ]
            for record in records {
                guard let vin = vinString(of: record.content) else { continue }
                vinLines.append("\(vin)\t\(record.formattedTime)")
            }
            vinLines.append("# 合计：\(records.count) 条")
            return vinLines.joined(separator: "\n")
        }
        for record in records {
            lines.append([
                record.formattedTime,
                record.source.rawValue,
                record.symbology,
                record.typeName,
                record.content
            ].joined(separator: "\t"))
        }
        lines.append("# 合计：\(records.count) 条")
        return lines.joined(separator: "\n")
    }

    /// CSV 字段转义：含逗号、引号、换行时用双引号包裹
    private func csvField(_ value: String) -> String {
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    // MARK: 复制 / 分享

    private func copyToClipboard() {
        let text = exportText
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        copiedCount = exportRecords.count
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.success)
        withAnimation { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { showCopied = false }
        }
    }

    private func prepareShareFile() {
        let text = exportText
        guard !text.isEmpty else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try text.data(using: .utf8)?.write(to: url)
            shareURL = url
            showShare = true
        } catch {
            print("导出文件写入失败: \(error.localizedDescription)")
        }
    }

    var body: some View {
        List {
            Section(header: Text("时间范围"),
                    footer: Text(range == .day ? "只导出所选那一天（00:00 至次日 00:00）的记录。" : "按时间范围筛选要导出的记录。")) {
                Picker("选择时间", selection: $range) {
                    ForEach(ExportTimeRange.allCases) { Text($0.rawValue).tag($0) }
                }

                if range == .day {
                    DatePicker("选择日期", selection: $selectedDay, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                }
            }

            Section(header: Text("车架号归类"),
                    footer: Text("按车架号（VIN）前 5 位归类：前 3 位是制造商代码（WMI），前 5 位即「厂家 + 车型系列」。只识别 17 位、不含 I/O/Q 的字母数字。")) {
                Toggle(isOn: $vinOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("只导出完整车架号")
                            .font(.system(size: 16))
                        Text(vinOnly ? "只保留 17 位完整车架号，文件里不含其他扫码内容" : "导出全部记录（含非车架号内容）")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                Picker("前 5 位前缀", selection: $vinPrefixFilter) {
                    Text("全部").tag("全部")
                    ForEach(vinPrefixGroups, id: \.prefix) { item in
                        if let brand = brandName(for: item.prefix) {
                            Text("\(item.prefix) · \(brand)（\(item.count) 条）").tag(item.prefix)
                        } else {
                            Text("\(item.prefix)（\(item.count) 条）").tag(item.prefix)
                        }
                    }
                }
                if vinPrefixGroups.isEmpty {
                    Text("暂无车架号记录")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }

            if !vinPrefixGroups.isEmpty {
                Section(header: Text("前缀分布（归类结果）")) {
                    ForEach(vinPrefixGroups.prefix(12), id: \.prefix) { item in
                        HStack(spacing: 8) {
                            Text(item.prefix)
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                            if let brand = brandName(for: item.prefix) {
                                Text(brand)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.blue.opacity(0.12)))
                            }
                            Spacer()
                            Text("\(item.count) 条")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section(header: Text("文件格式")) {
                Picker("选择格式", selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section(header: Text("数据概览")) {
                HStack {
                    Text("可导出")
                    Spacer()
                    Text("\(exportRecords.count) 条").foregroundColor(.secondary)
                }
                HStack {
                    Text("含车架号 / 前缀数")
                    Spacer()
                    Text("\(vinRecordCount) / \(vinPrefixGroups.count)").foregroundColor(.secondary)
                }
            }

            Section(header: Text("内容预览"),
                    footer: Text("预览只显示开头部分，复制/分享时是完整数据。")) {
                if exportText.isEmpty {
                    Text("当前筛选条件下暂无可导出的记录")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                } else {
                    Text(String(exportText.prefix(700)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Button {
                    copyToClipboard()
                } label: {
                    Label("复制到剪贴板", systemImage: "doc.on.doc")
                }
                .disabled(exportText.isEmpty)

                Button {
                    prepareShareFile()
                } label: {
                    Label("导出为文件（分享/存到「文件」）", systemImage: "square.and.arrow.up")
                }
                .disabled(exportText.isEmpty)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("导出数据")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if showCopied {
                Text("已复制 \(copiedCount) 条记录到剪贴板")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showShare) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
    }
}

/// 系统分享面板（导出文件用）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
