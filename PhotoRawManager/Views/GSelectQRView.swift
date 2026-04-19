import SwiftUI
import CoreImage.CIFilterBuiltins

struct GSelectQRView: View {
    let link: String
    let count: Int
    let folderName: String
    var viewerLink: String? = nil

    @State private var showViewer = true  // Default: show viewer QR
    @State private var cachedQRImage: NSImage?
    @State private var cachedQRLink: String = ""

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack(spacing: 6) {
                Text("G")
                    .font(.system(size: 16, weight: .black))
                    .foregroundColor(.blue)
                Image(systemName: "cloud.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.green)
                Text("G셀렉 공유")
                    .font(.system(size: 14, weight: .bold))
            }

            // Toggle: Google Drive vs Web Viewer
            if viewerLink != nil {
                Picker("", selection: $showViewer) {
                    Text("고객 셀렉").tag(true)
                    Text("Drive 폴더").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            // QR Code — 캐시된 이미지 사용 (body 내 CIContext 생성 방지)
            let activeLink = (showViewer && viewerLink != nil) ? viewerLink! : link
            if let qrImage = cachedQRImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .background(Color.white)
                    .cornerRadius(8)
            }

            // Info
            VStack(spacing: 4) {
                Text(folderName)
                    .font(.system(size: 12, weight: .medium))
                Text("\(count)장 업로드됨")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            // Link display + copy
            HStack {
                Text(activeLink)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(activeLink, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("링크 복사")
            }
            .padding(.horizontal, 8)

            if showViewer && viewerLink != nil {
                Text("고객이 QR 스캔 → 사진 셀렉 → 완료\n결과가 Google Drive에 자동 저장됩니다")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
                    .multilineTextAlignment(.center)
            } else {
                Text("클라이언트 폰으로 QR 스캔하면\nGoogle Drive 폴더를 바로 확인할 수 있습니다")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(width: 280)
        .onAppear { updateQR() }
        .onChange(of: showViewer) { _, _ in updateQR() }
    }

    private func updateQR() {
        let activeLink = (showViewer && viewerLink != nil) ? viewerLink! : link
        guard activeLink != cachedQRLink else { return }
        cachedQRLink = activeLink
        cachedQRImage = generateQR(from: activeLink)
    }

    private func generateQR(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up for sharp rendering
        let scale = 10.0
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
