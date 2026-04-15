//
//  ClientUploadProgressBar.swift
//  PhotoRawManager
//
//  Extracted from ContentView.swift split.
//

import SwiftUI

struct ClientUploadProgressBar: View {
    @ObservedObject var service: ClientSelectService
    @State private var dragOffset: CGSize = .zero
    @State private var position: CGPoint = .zero
    @State private var linkCopied = false

    var body: some View {
        let done = service.uploadDone
        let total = service.uploadTotal
        let progress = total > 0 ? Double(done) / Double(total) : 0
        let isComplete = !service.isUploading && service.viewerLink != nil

        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "icloud.and.arrow.up.fill")
                    .font(.system(size: 16))
                    .foregroundColor(isComplete ? .green : .purple)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(isComplete ? "업로드 완료!" : "클라이언트 셀렉 업로드 중...")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(done)/\(total)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if !isComplete {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.purple)
                    }
                    if !service.uploadSpeed.isEmpty && !isComplete {
                        Text(service.uploadSpeed)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                if !isComplete {
                    Button(action: { service.cancelUpload() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { service.showSetup = true }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("상세 보기")
            }

            // 완료 후 링크/QR 표시
            if isComplete, let link = service.viewerLink {
                HStack(spacing: 8) {
                    Text(link)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.blue)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                        linkCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { linkCopied = false }
                    }) {
                        Text(linkCopied ? "복사됨!" : "링크 복사")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if let url = URL(string: link) {
                        Button(action: { NSWorkspace.shared.open(url) }) {
                            Image(systemName: "safari")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help("브라우저에서 열기")
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 450)
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
