//
//  MemoryLeakHUD.swift
//  PhotoRawManager
//
//  v8.6.1 메모리 누수 추적 HUD.
//  Cmd+Shift+Option+M 단축키로 토글.
//

import SwiftUI

struct MemoryLeakHUD: View {
    @ObservedObject var tracker = MemoryLeakTracker.shared
    @State private var showDetails: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if showDetails {
                statsRow
                miniGraph
                stressSection
            }
        }
        .padding(10)
        .frame(width: showDetails ? 440 : 300)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.purple.opacity(0.5), lineWidth: 1)
                )
        )
        .foregroundColor(.white)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "memorychip").foregroundColor(.purple)
            Text("Memory Leak Tracker")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Spacer()
            if tracker.isTracking {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundColor(.green)
            }
            Button(action: { showDetails.toggle() }) {
                Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 14) {
            stat(label: "RSS", value: "\(tracker.currentRSSMB)MB",
                 color: tracker.currentRSSMB > 4000 ? .red : (tracker.currentRSSMB > 2000 ? .orange : .green))
            stat(label: "Peak", value: "\(tracker.peakRSSMB)MB", color: .yellow)
            stat(label: "증가율", value: "\(Int(tracker.growthRateMBPerMin))MB/m",
                 color: tracker.growthRateMBPerMin > 100 ? .red : .white.opacity(0.8))
            stat(label: "샘플", value: "\(tracker.snapshots.count)", color: .white.opacity(0.7))
            Spacer()
            HStack(spacing: 4) {
                Button(tracker.isTracking ? "정지" : "시작") {
                    if tracker.isTracking { tracker.stop() } else { tracker.start() }
                }
                .font(.system(size: 10))
                Button("로그") { tracker.openLogFolder() }
                    .font(.system(size: 10))
            }
        }
    }

    private func stat(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundColor(.white.opacity(0.6))
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(color)
        }
    }

    private var miniGraph: some View {
        GeometryReader { geo in
            let samples = tracker.snapshots.suffix(100)
            let maxMB = CGFloat(max(samples.map { $0.rssMB }.max() ?? 1, 100))
            let step = geo.size.width / CGFloat(max(samples.count, 1))
            Path { p in
                for (i, s) in samples.enumerated() {
                    let x = CGFloat(i) * step
                    let y = geo.size.height - (CGFloat(s.rssMB) / maxMB) * geo.size.height
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.purple, lineWidth: 1.5)
            // spike 표시
            ForEach(Array(samples.enumerated()), id: \.element.id) { (i, s) in
                if s.trigger.hasPrefix("spike") {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 4, height: 4)
                        .position(x: CGFloat(i) * step,
                                  y: geo.size.height - (CGFloat(s.rssMB) / maxMB) * geo.size.height)
                }
            }
        }
        .frame(height: 60)
        .background(Color.white.opacity(0.05))
        .cornerRadius(4)
    }

    private var stressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("스트레스 테스트")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Button(tracker.isStressTesting ? "진행 중..." : "실행 (50 cycles)") {
                    tracker.runStressTest(cycles: 50)
                }
                .font(.system(size: 10))
                .disabled(tracker.isStressTesting)
            }
            if !tracker.stressProgress.isEmpty {
                Text(tracker.stressProgress)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
            }
        }
    }
}
