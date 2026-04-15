//
//  BackupProgressBar.swift
//  PhotoRawManager
//
//  Extracted from ContentView.swift split.
//

import SwiftUI

struct BackupProgressBar: View {
    @ObservedObject var session: BackupSession
    let service: MemoryCardBackupService

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576)
        }
    }
    @State private var dragOffset: CGSize = .zero
    @State private var position: CGPoint = .zero

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sdcard.fill")
                .font(.system(size: 16))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(session.volumeName) 백업 중...")
                        .font(.system(size: 12, weight: .semibold))
                    Text(formatBytes(session.totalBytes))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(session.done)/\(session.total)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                ProgressView(value: Double(session.done), total: max(Double(session.total), 1))
                    .progressViewStyle(.linear)

                HStack {
                    Text(session.speed)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    if session.eta.isEmpty {
                        Text("준비 중...")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else {
                        Text("남은 시간: \(session.eta)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Button(action: { service.cancelSession(session) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("백업 취소")
        }
        .padding(12)
        .frame(width: 400)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 5)
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in
                    position.x += value.translation.width
                    position.y += value.translation.height
                    dragOffset = .zero
                }
        )
        .offset(x: position.x, y: position.y)
    }
}
