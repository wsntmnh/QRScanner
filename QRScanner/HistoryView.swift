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

                if let direction = record.direction {
                    Label(direction.rawValue, systemImage: direction.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(direction == .inbound ? .green : .orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background((direction == .inbound ? Color.green : Color.orange).opacity(0.12))
                        .clipShape(Capsule())
                }

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

/// 导出格式：TXT 排第一，也是默认格式
enum ExportFormat: String, CaseIterable, Identifiable {
    case txt = "TXT（纯文本）"
    case csv = "CSV（Excel 可打开）"
    case json = "JSON（结构化）"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .txt: return "txt"
        case .csv: return "csv"
        case .json: return "json"
        }
    }
}

/// 导出内容项目：车架号（或扫码内容）始终导出，这里控制额外附加哪些项目
enum ExportField: String, CaseIterable, Identifiable {
    case brand = "品牌"
    case direction = "入库/出库"
    case time = "扫描时间"
    case source = "来源"
    case symbology = "码制"

    var id: String { rawValue }
}

/// 出入库筛选
enum DirectionFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case inbound = "仅入库"
    case outbound = "仅出库"

    var id: String { rawValue }

    var direction: ScanRecord.VINDirection? {
        switch self {
        case .all: return nil
        case .inbound: return .inbound
        case .outbound: return .outbound
        }
    }
}

struct DataExportView: View {
    @ObservedObject private var historyManager = HistoryManager.shared

    @State private var range: ExportTimeRange = .all
    /// 「指定某一天」用的日期
    @State private var selectedDay = Date()
    @State private var format: ExportFormat = .txt
    @State private var directionFilter: DirectionFilter = .all
    /// 车架号（VIN）前 5 位前缀筛选，"全部" 表示不按前缀过滤
    @State private var vinPrefixFilter = "全部"
    /// 只导出完整车架号：开启后仅保留能被识别为完整 VIN 的记录
    @State private var vinOnly = true
    /// 导出内容项目（车架号/内容之外的附加项）
    @State private var fields: Set<ExportField> = [.brand, .direction, .time]
    /// 手动添加的品牌前缀
    @State private var userBrands: [String: String] = [:]
    @State private var newPrefix = ""
    @State private var newBrand = ""
    @State private var copiedCount = 0
    @State private var searchText = ""
    @State private var showCopied = false
    @State private var shareURL: URL?
    @State private var showShare = false

    private let brandMapKey = "vin_brand_map"

    // MARK: 数据整理

    /// 按「时间范围 + 出入库 + 车架号前缀」筛选后的记录（保持最新在前）
    private var exportRecords: [ScanRecord] {
        let bounds = range.interval(selectedDay: selectedDay)
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return historyManager.records.filter { record in
            if let start = bounds.start, record.timestamp < start { return false }
            if let end = bounds.end, record.timestamp >= end { return false }
            if let wanted = directionFilter.direction {
                guard record.direction == wanted else { return false }
            }
            if vinOnly, vinString(of: record.content) == nil { return false }
            if vinPrefixFilter != "全部" {
                guard let prefix = vinPrefix(of: record.content), prefix == vinPrefixFilter else { return false }
            }
            if !keyword.isEmpty {
                // 搜索：车架号 / 扫码内容 / 品牌名 任一命中即可
                let brand = vinPrefix(of: record.content).flatMap { brandName(for: $0) } ?? ""
                let hit = record.content.lowercased().contains(keyword)
                    || brand.lowercased().contains(keyword)
                    || record.symbology.lowercased().contains(keyword)
                if !hit { return false }
            }
            return true
        }
    }

    private func vinString(of content: String) -> String? {
        ScanRecord.vinString(from: content)
    }

    private func vinPrefix(of content: String) -> String? {
        vinString(of: content).map { String($0.prefix(5)) }
    }

    /// 内置品牌表：5 位优先（具体车型系列），认不出再退回 3 位 WMI
    private static let builtinBrands: [String: String] = [
        "LSJEM": "尚界",
        "LSJEK": "荣威",
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

    /// 手动添加的优先，其后是内置表；5 位认不出时退回 3 位 WMI
    private func brandName(for prefix: String) -> String? {
        if let name = userBrands[prefix] { return name }
        if let name = Self.builtinBrands[prefix] { return name }
        let wmi = String(prefix.prefix(3))
        return userBrands[wmi] ?? Self.builtinBrands[wmi]
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

    private var vinRecordCount: Int {
        exportRecords.filter { vinString(of: $0.content) != nil }.count
    }

    private var inboundCount: Int { exportRecords.filter { $0.direction == .inbound }.count }
    private var outboundCount: Int { exportRecords.filter { $0.direction == .outbound }.count }

    private var userBrandKeys: [String] { userBrands.keys.sorted() }

    private var canAddBrand: Bool {
        let prefix = newPrefix.trimmingCharacters(in: .whitespaces).uppercased()
        let brand = newBrand.trimmingCharacters(in: .whitespaces)
        guard brand.count > 0, prefix.count == 3 || prefix.count == 5 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHJKLMNPRSTUVWXYZ0123456789")
        return prefix.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: 文本生成

    /// 当前勾选的附加项目（按固定顺序）
    private var selectedFields: [ExportField] {
        ExportField.allCases.filter { fields.contains($0) }
    }

    private var exportHeader: [String] {
        var titles = [vinOnly ? "车架号" : "内容"]
        for field in selectedFields { titles.append(field.rawValue) }
        return titles
    }

    private func exportRow(_ record: ScanRecord) -> [String] {
        var values = [vinOnly ? (vinString(of: record.content) ?? "") : record.content]
        for field in selectedFields {
            switch field {
            case .brand:
                if let prefix = vinPrefix(of: record.content), let brand = brandName(for: prefix) {
                    values.append(brand)
                } else {
                    values.append("")
                }
            case .direction: values.append(record.direction?.rawValue ?? "未标记")
            case .time: values.append(record.formattedTime)
            case .source: values.append(record.source.rawValue)
            case .symbology: values.append(record.symbology)
            }
        }
        return values
    }

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
        var lines = [exportHeader.map(csvField).joined(separator: ",")]
        for record in records {
            lines.append(exportRow(record).map(csvField).joined(separator: ","))
        }
        lines.append("合计,\(records.count) 条")
        return lines.joined(separator: "\n")
    }

    private func txtText(_ records: [ScanRecord]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "zh_CN")

        var lines: [String] = [
            "# QRScanner 扫描记录导出",
            "# 范围：\(range.rawValue) 方向：\(directionFilter.rawValue) 条数：\(records.count)",
            "# 导出时间：\(formatter.string(from: Date()))",
            "# " + exportHeader.joined(separator: "\t")
        ]
        for record in records {
            lines.append(exportRow(record).joined(separator: "\t"))
        }
        lines.append("# 合计：\(records.count) 条")
        return lines.joined(separator: "\n")
    }

    private func jsonText(_ records: [ScanRecord]) -> String {
        let header = exportHeader
        let items = records.map { record -> [String: String] in
            var dict: [String: String] = [:]
            let values = exportRow(record)
            for (index, key) in header.enumerated() where index < values.count {
                dict[key] = values[index]
            }
            return dict
        }
        let payload: [String: Any] = ["total": records.count, "items": items]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// CSV 字段转义：含逗号、引号、换行时用双引号包裹
    private func csvField(_ value: String) -> String {
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    // MARK: 品牌前缀管理

    private func loadBrands() {
        userBrands = UserDefaults.standard.dictionary(forKey: brandMapKey) as? [String: String] ?? [:]
    }

    private func persistBrands() {
        UserDefaults.standard.set(userBrands, forKey: brandMapKey)
    }

    private func addBrand() {
        let prefix = newPrefix.trimmingCharacters(in: .whitespaces).uppercased()
        let brand = newBrand.trimmingCharacters(in: .whitespaces)
        guard canAddBrand else { return }
        userBrands[prefix] = brand
        persistBrands()
        newPrefix = ""
        newBrand = ""
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
            Section(header: Text("搜索"),
                    footer: Text(searchText.isEmpty
                                 ? "可按车架号、扫码内容、品牌名或码制搜索，结果同时作用到预览、条数和导出。"
                                 : "已按「\(searchText)」筛选，命中 \(exportRecords.count) 条。")) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索车架号 / 内容 / 品牌", text: $searchText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .submitLabel(.search)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

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

            Section(header: Text("入库 / 出库"),
                    footer: Text("入库、出库分开记录，可分别导出，也可以一次导出全部。")) {
                Picker("选择方向", selection: $directionFilter) {
                    ForEach(DirectionFilter.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section(header: Text("车架号归类"),
                    footer: Text("按车架号（VIN）前 5 位归类：前 3 位是制造商代码（WMI），前 5 位即「厂家 + 车型系列」。只识别 17 位、不含 I/O/Q 的字母数字。")) {
                Toggle(isOn: $vinOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("只导出完整车架号")
                            .font(.system(size: 16))
                        Text(vinOnly ? "只保留 17 位完整车架号，不含其他扫码内容" : "导出全部记录（含非车架号内容）")
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

            Section(header: Text("品牌前缀（可手动添加）"),
                    footer: Text("填车架号前 5 位（或前 3 位 WMI）+ 品牌名。手动添加的排在内置表前面，左滑可删除。")) {
                ForEach(userBrandKeys, id: \.self) { prefix in
                    HStack(spacing: 8) {
                        Text(prefix)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                        Text(userBrands[prefix] ?? "")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                        Spacer()
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                            .onTapGesture {
                                userBrands.removeValue(forKey: prefix)
                                persistBrands()
                            }
                    }
                }

                HStack(spacing: 8) {
                    TextField("前缀（3 或 5 位）", text: $newPrefix)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 14))
                        .frame(width: 120)
                    TextField("品牌名", text: $newBrand)
                        .font(.system(size: 14))
                    Button("添加") { addBrand() }
                        .font(.system(size: 14, weight: .semibold))
                        .disabled(!canAddBrand)
                }
            }

            Section(header: Text("导出内容项目"),
                    footer: Text(vinOnly ? "车架号始终导出，上面勾选的是附加项目。" : "扫码内容始终导出，上面勾选的是附加项目。")) {
                ForEach(ExportField.allCases) { field in
                    Toggle(field.rawValue, isOn: Binding(
                        get: { fields.contains(field) },
                        set: { isOn in
                            if isOn { fields.insert(field) } else { fields.remove(field) }
                        }
                    ))
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
                    Text("入库 / 出库")
                    Spacer()
                    Text("\(inboundCount) / \(outboundCount)").foregroundColor(.secondary)
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
        .onAppear { loadBrands() }
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
