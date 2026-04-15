//
//  PickshotImportResultSheet.swift
//  PhotoRawManager
//
//  Extracted from ContentView+SupportingViews.swift split.
//

import SwiftUI
import AppKit

// MARK: - Pickshot Import Result Sheet (셀렉 가져오기 결과)

struct PickshotImportResultSheet: View {
    @ObservedObject var store: PhotoStore

    private var result: PickshotImportResult? { store.lastImportResult }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 헤더
            HStack {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                Text("셀렉 가져오기 결과")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if let r = result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // 세션 정보
                        if !r.sourceFolderName.isEmpty {
                            infoRow(label: "원본 폴더", value: r.sourceFolderName, icon: "folder.fill", color: .blue)
                        }

                        // 통계 그리드
                        HStack(spacing: 12) {
                            statCard(title: "전체", value: "\(r.totalInFile)", color: .secondary)
                            statCard(title: "매칭", value: "\(r.matched.count)", color: .green)
                            statCard(title: "미매칭", value: "\(r.unmatched.count)", color: r.unmatched.isEmpty ? .secondary : .red)
                            statCard(title: "SP 셀렉", value: "\(r.matched.filter { $0.spacePick }.count)", color: .orange)
                            statCard(title: "코멘트", value: "\(r.commentsCount)", color: .purple)
                        }

                        // 코멘트 목록
                        if !r.commentDetails.isEmpty {
                            Divider()
                            Text("클라이언트 코멘트")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.orange)

                            ForEach(r.commentDetails.indices, id: \.self) { i in
                                let detail = r.commentDetails[i]
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "bubble.left.fill")
                                        .foregroundColor(.orange)
                                        .font(.system(size: 11))
                                        .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(detail.filename)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(.secondary)
                                        ForEach(detail.comments.indices, id: \.self) { j in
                                            Text(detail.comments[j])
                                                .font(.system(size: 12))
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        // 미매칭 파일 목록
                        if !r.unmatched.isEmpty {
                            Divider()
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(r.unmatched, id: \.self) { name in
                                        Text(name)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.red)
                                    }
                                }
                            } label: {
                                Text("미매칭 파일 (\(r.unmatched.count))")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: 400)
            } else {
                Text("가져오기 결과가 없습니다")
                    .foregroundColor(.secondary)
                    .padding()
            }

            Divider()

            // 하단 버튼
            HStack {
                Spacer()
                Button("닫기") {
                    store.showPickshotImportSheet = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 500)
        .frame(minHeight: 300)
    }

    private func infoRow(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 12))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .bold))
        }
    }

    private func statCard(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }
}
