import SwiftUI
import AppKit

/// 내 클라이언트 세션 목록 — 업로드했던 세션을 다시 확인/공유할 수 있는 팝업.
/// 컴팩트 디자인: 가운데 정렬, QR 없음, 한 카드당 한 줄로 핵심 정보 + 액션 버튼.
struct ClientSessionListView: View {
    @ObservedObject var service = ClientSelectService.shared
    @Environment(\.dismiss) var dismiss

    @State private var searchQuery: String = ""
    @State private var sortMode: SortMode = .recent
    @State private var copiedSessionID: UUID? = nil

    enum SortMode: String, CaseIterable {
        case recent = "최근 활동순"
        case name = "세션명"
        case client = "고객명"
    }

    private var filteredSessions: [ClientSelectService.ClientSession] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? service.sessionHistory :
            service.sessionHistory.filter {
                $0.sessionName.lowercased().contains(q) ||
                $0.clientName.lowercased().contains(q)
            }
        switch sortMode {
        case .recent: return filtered  // 이미 최신순
        case .name: return filtered.sorted { $0.sessionName < $1.sessionName }
        case .client: return filtered.sorted { $0.clientName < $1.clientName }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "list.clipboard.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)
                        )
                    Text("내 클라이언트 세션")
                        .font(.system(size: 18, weight: .bold))
                }
                Text("총 \(service.sessionHistory.count)개 세션")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            // 검색 + 정렬
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                TextField("세션명 / 고객명 검색", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                Spacer()

                Picker("", selection: $sortMode) {
                    ForEach(SortMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))

            // 세션 리스트
            ScrollView {
                VStack(spacing: 10) {
                    if filteredSessions.isEmpty {
                        emptyView
                    } else {
                        ForEach(filteredSessions) { session in
                            sessionCard(session)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
            }

            Divider()

            // 하단
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 540, height: 620)
        .onAppear { service.loadSessionHistory() }
    }

    // MARK: - 빈 상태

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundColor(.secondary.opacity(0.4))
            Text("아직 업로드한 세션이 없습니다")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text("PickShot 에서 클라이언트 셀렉 업로드 후 이 목록에서 확인할 수 있습니다.")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 세션 카드 (컴팩트)

    private func sessionCard(_ session: ClientSelectService.ClientSession) -> some View {
        let hasFeedback = session.feedbackSelectedCount != nil
        let isCopied = copiedSessionID == session.id

        return VStack(alignment: .leading, spacing: 8) {
            // 1줄: 세션명 + 상대 시간 + 피드백 배지
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.blue)
                Text(session.sessionName.isEmpty ? "(이름 없음)" : session.sessionName)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Spacer()
                if hasFeedback {
                    Text("✨ 피드백 \(session.feedbackSelectedCount ?? 0)장")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.18))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                }
                Text(relativeTime(session.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // 2줄: 고객 + 사진 수 + URL
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(session.clientName.isEmpty ? "—" : session.clientName)
                        .font(.system(size: 11))
                }
                HStack(spacing: 3) {
                    Image(systemName: "photo")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("\(session.uploadedCount)장")
                        .font(.system(size: 11, design: .monospaced))
                }
                if session.selectionLimit > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text("최대 \(session.selectionLimit)장")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
                Spacer()
            }

            // 3줄: URL (클릭 가능)
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 9))
                    .foregroundColor(.blue)
                Text(shortenDisplayURL(session.viewerURL))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // 4줄: 액션 버튼
            HStack(spacing: 6) {
                actionButton(icon: "doc.on.doc", label: isCopied ? "복사됨!" : "링크 복사", color: isCopied ? .green : .primary) {
                    copyLink(session)
                }
                actionButton(icon: "qrcode", label: "QR 저장", color: .primary) {
                    saveQRImage(session)
                }
                actionButton(icon: "safari", label: "열기", color: .primary) {
                    openInBrowser(session)
                }
                actionButton(icon: "folder", label: "Drive", color: .primary) {
                    openDriveFolder(session)
                }
                Spacer()
                actionButton(icon: "trash", label: "", color: .red) {
                    deleteSession(session)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    hasFeedback ? Color.green.opacity(0.3) : Color.white.opacity(0.06),
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private func actionButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundColor(color)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 액션 헬퍼

    private func copyLink(_ session: ClientSelectService.ClientSession) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(session.viewerURL, forType: .string)
        withAnimation { copiedSessionID = session.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { if copiedSessionID == session.id { copiedSessionID = nil } }
        }
    }

    private func saveQRImage(_ session: ClientSelectService.ClientSession) {
        guard let img = service.generateQRCode(from: session.viewerURL) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "PickShot_QR_\(session.sessionName).png"
        if panel.runModal() == .OK, let url = panel.url,
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    private func openInBrowser(_ session: ClientSelectService.ClientSession) {
        if let url = URL(string: session.viewerURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func openDriveFolder(_ session: ClientSelectService.ClientSession) {
        if let link = session.shareLink, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        } else if !session.driveFolderID.isEmpty,
                  let url = URL(string: "https://drive.google.com/drive/folders/\(session.driveFolderID)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func deleteSession(_ session: ClientSelectService.ClientSession) {
        let alert = NSAlert()
        alert.messageText = "세션 삭제"
        alert.informativeText = "'\(session.sessionName)' 세션을 목록에서 제거합니다.\nGoogle Drive 폴더는 유지됩니다."
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            service.deleteSession(id: session.id)
        }
    }

    // MARK: - 유틸

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "방금 전" }
        if interval < 3600 { return "\(Int(interval / 60))분 전" }
        if interval < 86400 { return "\(Int(interval / 3600))시간 전" }
        if interval < 86400 * 30 { return "\(Int(interval / 86400))일 전" }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    private func shortenDisplayURL(_ url: String) -> String {
        if url.hasPrefix("https://is.gd/") {
            return url
        }
        // 긴 URL은 도메인 + ... 형태로 축약
        if url.count > 50 {
            if let schemeEnd = url.range(of: "://"), let pathStart = url[schemeEnd.upperBound...].firstIndex(of: "/") {
                let domain = String(url[..<pathStart])
                return "\(domain)/... (\(url.count)자)"
            }
        }
        return url
    }
}
