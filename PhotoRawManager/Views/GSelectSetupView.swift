import SwiftUI

enum GSelectUploadType: String, CaseIterable {
    case both = "JPG + RAW"
    case jpgOnly = "JPG만"
    case rawOnly = "RAW만"
}

struct GSelectSetupView: View {
    @ObservedObject var gSelect = GSelectService.shared
    @Environment(\.dismiss) var dismiss

    @State private var folderName: String = ""
    @State private var uploadType: GSelectUploadType = .both

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("G")
                        .font(.system(size: 32, weight: .black))
                        .foregroundColor(.green)
                    Image(systemName: "icloud.and.arrow.up.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.green)
                }

                Text("G셀렉 시작")
                    .font(.system(size: 18, weight: .bold))

                Text("G키를 눌러 사진을 선택하면 Google Drive에 즉시 업로드됩니다")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // Google account status
                HStack {
                    Image(systemName: gSelect.isLoggedIn ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(gSelect.isLoggedIn ? .green : .red)
                    Text(gSelect.isLoggedIn ? "Google Drive 연결됨" : "Google Drive 미연결")
                        .font(.system(size: 13))

                    Spacer()

                    if gSelect.isLoggedIn {
                        Button("로그아웃") { gSelect.logout() }
                            .font(.system(size: 11))
                    } else {
                        Button("Google 로그인") { gSelect.loginToGoogle() }
                            .font(.system(size: 11))
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(8)

                // Folder name
                VStack(alignment: .leading, spacing: 4) {
                    Text("업로드 폴더 이름")
                        .font(.system(size: 12, weight: .medium))

                    TextField("예: 20260322_행사_셀렉", text: $folderName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))

                    Text("Google Drive에 이 이름으로 폴더가 생성됩니다")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                // Upload file type
                VStack(alignment: .leading, spacing: 4) {
                    Text("업로드 파일")
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: $uploadType) {
                        Text("JPG + RAW").tag(GSelectUploadType.both)
                        Text("JPG만").tag(GSelectUploadType.jpgOnly)
                        Text("RAW만").tag(GSelectUploadType.rawOnly)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                // How it works
                HStack(spacing: 0) {
                    Spacer()
                    VStack(spacing: 4) {
                        howToRow(icon: "g.circle.fill", color: .green, text: "G키 → 업로드")
                        howToRow(icon: "g.circle", color: .orange, text: "다시 G키 → 삭제")
                        howToRow(icon: "link", color: .blue, text: "종료 시 공유 링크")
                    }
                    Spacer()
                }
                .padding(8)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(8)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)

            Divider()

            // Footer
            HStack {
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("G셀렉 시작") {
                    let name = folderName.isEmpty ? defaultFolderName : folderName
                    gSelect.startSession(folderName: name, uploadType: uploadType)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!gSelect.isLoggedIn)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .frame(width: 420, height: 500)
        .onAppear {
            folderName = defaultFolderName
        }
    }

    private var defaultFolderName: String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmm"
        return "PickShot_\(df.string(from: Date()))"
    }

    private func howToRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 11))
        }
    }
}
