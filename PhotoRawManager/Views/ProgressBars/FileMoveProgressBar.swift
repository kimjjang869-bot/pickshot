//
//  FileMoveProgressBar.swift
//  PhotoRawManager
//
//  Extracted from ContentView.swift split.
//

import SwiftUI

struct FileMoveProgressBar: View {
    @ObservedObject var store: PhotoStore

    var body: some View {
        let done = store.fileMoveDone
        let total = store.fileMoveTotal
        let progress = total > 0 ? Double(done) / Double(total) : 0

        HStack(spacing: 12) {
            Image(systemName: "folder.badge.arrow.forward")
                .font(.system(size: 16))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(store.fileMoveLabel) 중...")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(done)/\(total)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }
        }
        .padding(12)
        .frame(width: 350)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(radius: 5)
    }
}
