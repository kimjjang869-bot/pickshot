//
//  ExportProgressBar.swift
//  PhotoRawManager
//
//  Extracted from ContentView.swift split.
//

import SwiftUI

struct ExportProgressBar: View {
    @ObservedObject var store: PhotoStore
    @State private var dragOffset: CGSize = .zero
    @State private var position: CGPoint = .zero

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up.fill")
                .font(.system(size: 16))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(store.bgExportLabel)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(store.bgExportDone)/\(store.bgExportTotal)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 80, alignment: .trailing)
                }

                ProgressView(value: store.bgExportProgress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }

            Button(action: { store.bgExportCancelled = true }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("내보내기 취소")
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

// MARK: - AI 분류 진행률 바

// MARK: - 파일 이동 진행률 바

// MARK: - 클라이언트 셀렉 업로드 진행률 바
