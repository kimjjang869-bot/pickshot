//
//  RawMatchResultView.swift
//  PhotoRawManager
//
//  Extracted from ContentView+SupportingViews.swift split.
//

import SwiftUI
import AppKit

// MARK: - RAW Match Result

struct RawMatchResult {
    var jpgCount: Int = 0
    var rawCount: Int = 0
    var matchedCount: Int = 0
    var jpgOnlyNames: [String] = []
    var rawOnlyNames: [String] = []
    var failedNames: [(name: String, reason: String)] = []
    var destFolder: URL? = nil
}

struct RawMatchResultView: View {
    let result: RawMatchResult
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.green)
                Text("JPG, RAW 매칭 완료")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
            }

            Divider()

            // Summary
            HStack(spacing: 24) {
                VStack {
                    Text("\(result.jpgCount)")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.blue)
                    Text("JPG")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                VStack {
                    Text("\(result.rawCount)")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                    Text("RAW")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                VStack {
                    Text("\(result.matchedCount)")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                    Text("매칭 성공")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            // JPG only (no RAW)
            if !result.jpgOnlyNames.isEmpty {
                DisclosureGroup {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(result.jpgOnlyNames, id: \.self) { name in
                                Text(name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 80)
                } label: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                            .font(.system(size: 11))
                        Text("JPG만 있음 (RAW 없음): \(result.jpgOnlyNames.count)장")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.yellow)
                    }
                }
            }

            // RAW only (no JPG)
            if !result.rawOnlyNames.isEmpty {
                DisclosureGroup {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(result.rawOnlyNames, id: \.self) { name in
                                Text(name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 80)
                } label: {
                    HStack {
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                        Text("RAW만 있음 (JPG 없음): \(result.rawOnlyNames.count)장")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Copy failures
            if !result.failedNames.isEmpty {
                DisclosureGroup {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(result.failedNames.indices, id: \.self) { i in
                                HStack {
                                    Text(result.failedNames[i].name)
                                        .font(.system(size: 11, design: .monospaced))
                                    Text(result.failedNames[i].reason)
                                        .font(.system(size: 10))
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 60)
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 11))
                        Text("복사 실패: \(result.failedNames.count)장")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                    }
                }
            }

            Divider()

            // Actions
            HStack {
                if let dest = result.destFolder {
                    Button("폴더 열기") {
                        NSWorkspace.shared.open(dest)
                    }
                    .help("복사된 파일 폴더 열기")
                }
                Spacer()
                Button("확인") { isPresented = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
