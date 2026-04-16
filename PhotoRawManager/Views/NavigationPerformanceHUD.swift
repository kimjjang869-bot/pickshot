//
//  NavigationPerformanceHUD.swift
//  PhotoRawManager
//
//  행 이동 성능 디버그 HUD.
//  - 오른쪽 하단에 플로팅
//  - 실시간 이동 간격 그래프
//  - 통계: 평균/최소/최대/저하 비율
//  - CSV 리포트 버튼
//

import SwiftUI

struct NavigationPerformanceHUD: View {
    @ObservedObject var monitor = NavigationPerformanceMonitor.shared
    @State private var isCompact: Bool = false

    var body: some View {
        if monitor.isEnabled {
            VStack(alignment: .leading, spacing: 6) {
                // 헤더
                HStack(spacing: 8) {
                    Image(systemName: "speedometer")
                        .foregroundColor(.yellow)
                    Text("Navigation Debug")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Spacer()
                    Button(action: { isCompact.toggle() }) {
                        Image(systemName: isCompact ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    Button(action: { _ = monitor.exportReport() }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("CSV 리포트 저장 (/tmp)")
                    Button(action: { monitor.isEnabled = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }

                if !isCompact {
                    // 통계
                    statsRow
                    // 그래프
                    intervalGraph
                    // 최근 이동 5개
                    recentList
                }
            }
            .padding(10)
            .frame(width: isCompact ? 280 : 360)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.yellow.opacity(0.5), lineWidth: 1)
                    )
            )
            .foregroundColor(.white)
        }
    }

    private var statsRow: some View {
        let s = monitor.stats
        let slowdownColor: Color = {
            if s.slowdownRatio >= 1.5 { return .red }
            if s.slowdownRatio >= 1.2 { return .orange }
            return .green
        }()
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                statCell("Moves", "\(s.totalMoves)", .cyan)
                statCell("Avg", String(format: "%.0fms", s.avgIntervalMs), .white)
                statCell("Recent", String(format: "%.0fms", s.recentAvgIntervalMs), .yellow)
            }
            HStack(spacing: 12) {
                statCell("Min", String(format: "%.0fms", s.minIntervalMs), .green)
                statCell("Max", String(format: "%.0fms", s.maxIntervalMs), .orange)
                statCell("Slow", String(format: "%.2fx", s.slowdownRatio), slowdownColor)
            }
            if s.firstHalfAvgMs > 0 {
                HStack(spacing: 8) {
                    Text("전반: \(String(format: "%.0fms", s.firstHalfAvgMs))")
                        .foregroundColor(.green.opacity(0.8))
                    Text("→")
                        .foregroundColor(.secondary)
                    Text("후반: \(String(format: "%.0fms", s.secondHalfAvgMs))")
                        .foregroundColor(slowdownColor)
                }
                .font(.system(size: 9, design: .monospaced))
            }
        }
    }

    private func statCell(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .frame(minWidth: 55, alignment: .leading)
    }

    // 간단한 bar 그래프 — 최근 60개
    private var intervalGraph: some View {
        let moves = Array(monitor.recentMoves.suffix(60))
        let maxInterval = max(moves.map(\.intervalMs).max() ?? 100, 100)

        return GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(moves) { m in
                    let h = m.intervalMs > 0 ? (m.intervalMs / maxInterval) * geo.size.height : 1
                    let c: Color = {
                        if m.intervalMs > 200 { return .red }
                        if m.intervalMs > 100 { return .orange }
                        if m.intervalMs > 50 { return .yellow }
                        return .green
                    }()
                    Rectangle()
                        .fill(c)
                        .frame(height: max(1, h))
                }
                // 남은 공간 채우기
                if moves.count < 60 {
                    ForEach(0..<(60 - moves.count), id: \.self) { _ in
                        Rectangle()
                            .fill(Color.gray.opacity(0.15))
                            .frame(height: 1)
                    }
                }
            }
        }
        .frame(height: 30)
    }

    private var recentList: some View {
        let last5 = Array(monitor.recentMoves.suffix(5).reversed())
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(last5) { m in
                HStack(spacing: 8) {
                    Text("\(m.index)")
                        .frame(width: 32, alignment: .trailing)
                        .foregroundColor(.secondary)
                    Text(m.direction)
                        .frame(width: 14)
                    Text("#\(m.photoIndex)")
                        .frame(width: 48, alignment: .trailing)
                        .foregroundColor(.cyan)
                    Text(String(format: "%.0fms", m.intervalMs))
                        .frame(width: 56, alignment: .trailing)
                        .foregroundColor(m.intervalMs > 100 ? .orange : .green)
                    Text("RAM \(m.ramUsageMB)M")
                        .foregroundColor(.secondary)
                    Text("C \(m.previewCacheCount)")
                        .foregroundColor(.secondary)
                }
                .font(.system(size: 9, design: .monospaced))
            }
        }
    }
}
