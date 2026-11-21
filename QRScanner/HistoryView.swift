//
//  HistoryView.swift
//  QRScanner
//
//  Created by 史冬亮 on 2026/8/14.
//

import SwiftUI

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
