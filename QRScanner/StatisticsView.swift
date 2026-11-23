//
//  StatisticsView.swift
//  QRScanner
//
//  Created by 史冬亮 on 2026/8/18.
//

import SwiftUI

struct StatisticsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var statsManager = StatisticsManager.shared
    @State private var selectedTab = 0
    @State private var dailyRange = 7

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // 统计摘要卡片
                    summaryCards

                    // 分段控制器
                    Picker("统计维度", selection: $selectedTab) {
                        Text("今日每小时").tag(0)
                        Text("每日趋势").tag(1)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)

                    if selectedTab == 0 {
                        hourlyChartSection
                    } else {
                        dailyChartSection
                    }
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("扫描统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - 统计摘要卡片
    private var summaryCards: some View {
        // 使用 @Published 属性，扫码后打开本页时数据已是最新
        let today = statsManager.todayTotal
        let total = statsManager.allTimeTotal
        let avg7 = statsManager.averageDailyScans(days: 7)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                SummaryCard(
                    title: "今日扫描",
                    value: "\(today)",
                    icon: "barcode.viewfinder",
                    color: .blue
                )
                SummaryCard(
                    title: "累计扫描",
                    value: "\(total)",
                    icon: "chart.bar.fill",
                    color: .green
                )
                SummaryCard(
                    title: "7日日均",
                    value: String(format: "%.1f", avg7),
                    icon: "calendar.badge.clock",
                    color: .orange
                )
            }
            .padding(.horizontal)
        }
    }

    // MARK: - 每小时图表
    private var hourlyChartSection: some View {
        let hourlyData = statsManager.hourlyStats(for: Date())
        let maxCount = max(hourlyData.map(\.count).max() ?? 1, 1)
        let totalToday = hourlyData.map(\.count).reduce(0, +)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日每小时扫描量")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("合计: \(totalToday)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            BarChartView(
                data: hourlyData.map { BarData(label: "\($0.hour)时", value: Double($0.count)) },
                maxValue: Double(maxCount),
                barColor: .blue,
                showGrid: true
            )
            .frame(height: 220)
            .padding(.horizontal)
        }
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }

    // MARK: - 每日图表
    private var dailyChartSection: some View {
        let dailyData = statsManager.dailyStats(days: dailyRange)
        let maxCount = max(dailyData.map(\.count).max() ?? 1, 1)
        let totalPeriod = dailyData.map(\.count).reduce(0, +)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近\(dailyRange)天扫描趋势")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("合计: \(totalPeriod)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            // 范围选择器
            HStack(spacing: 8) {
                ForEach([7, 14, 30], id: \.self) { days in
                    Button {
                        withAnimation {
                            dailyRange = days
                        }
                    } label: {
                        Text("\(days)天")
                            .font(.system(size: 13, weight: dailyRange == days ? .semibold : .regular))
                            .foregroundColor(dailyRange == days ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(dailyRange == days ? Color.blue : Color.gray.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Spacer()
            }
            .padding(.horizontal)

            BarChartView(
                data: dailyData.map {
                    let comps = $0.date.split(separator: "-")
                    let label = comps.count >= 3 ? "\(comps[1])-\(comps[2])" : $0.date
                    return BarData(label: String(label), value: Double($0.count))
                },
                maxValue: Double(maxCount),
                barColor: .green,
                showGrid: true
            )
            .frame(height: 220)
            .padding(.horizontal)
        }
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }
}

// MARK: - 摘要卡片
struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(color)
                Spacer()
            }

            Text(value)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(width: 120, height: 100)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
}

// MARK: - 柱状图数据模型
struct BarData: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
}

// MARK: - 柱状图视图
struct BarChartView: View {
    let data: [BarData]
    let maxValue: Double
    let barColor: Color
    let showGrid: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let bottomPadding: CGFloat = 28
            let topPadding: CGFloat = 8
            let chartHeight = height - bottomPadding - topPadding
            let barWidth = max((width - CGFloat(data.count + 1) * 4) / CGFloat(data.count), 4)
            let spacing = max((width - CGFloat(data.count) * barWidth) / CGFloat(data.count + 1), 2)

            ZStack {
                // 网格线
                if showGrid {
                    VStack(spacing: 0) {
                        ForEach(0..<5) { i in
                            HStack {
                                Text("\(Int(maxValue * Double(4 - i) / 4))")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .frame(width: 20, alignment: .trailing)
                                Rectangle()
                                    .fill(Color.gray.opacity(0.15))
                                    .frame(height: 0.5)
                            }
                            if i < 4 {
                                Spacer()
                            }
                        }
                    }
                    .padding(.leading, 2)
                    .padding(.trailing, 4)
                }

                // 柱状图
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(data) { item in
                        VStack(spacing: 4) {
                            // 柱子
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor.opacity(item.value > 0 ? 0.85 : 0.2))
                                .frame(width: barWidth, height: max(chartHeight * CGFloat(item.value / maxValue), 2))

                            // 标签
                            Text(item.label)
                                .font(.system(size: data.count > 14 ? 8 : 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(width: max(barWidth + 4, 20))
                        }
                    }
                }
                .padding(.leading, showGrid ? 26 : 0)
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
            }
        }
    }
}
