import SwiftUI
import AppKit

/// 클라이언트 뷰어 프록시 설정 — Cloudflare Worker 우선, Apps Script 옵션.
/// 한 번 설정하면 모든 세션이 프록시 통해 CORS 우회 로딩.
struct ClientProxySetupView: View {
    @ObservedObject var service = ClientSelectService.shared
    @Environment(\.dismiss) var dismiss

    @State private var proxyURL: String = ""
    @State private var testResult: TestResult = .idle
    @State private var showCode: Bool = false
    @State private var showAdvanced: Bool = false

    enum TestResult {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    private var usingCustom: Bool {
        !service.customProxyURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var defaultStatusBadge: String {
        usingCustom ? "CUSTOM" : "DEFAULT"
    }

    // Cloudflare Worker 코드 (기본 추천)
    private let workerCode = """
export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: cors() });
    }
    const fileId = url.searchParams.get('id');
    if (!fileId) return json({ service: 'PickShot Proxy' });
    try {
      const driveURL = `https://drive.google.com/uc?export=download&id=${encodeURIComponent(fileId)}`;
      const resp = await fetch(driveURL, { cf: { cacheTtl: 120, cacheEverything: true } });
      const content = await resp.text();
      try {
        return json(JSON.parse(content));
      } catch (_) {
        return new Response(content, { headers: { 'Content-Type': 'text/plain', ...cors() } });
      }
    } catch (e) {
      return json({ error: e.toString() }, 500);
    }
  }
};
function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=60', ...cors() }
  });
}
function cors() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
}
"""

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 24))
                        .foregroundStyle(
                            LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)
                        )
                    Text("Cloudflare Worker 프록시")
                        .font(.system(size: 18, weight: .bold))
                }
                Text("매니페스트 로딩 속도 향상 + 공유 URL 짧게")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 기본 제공 안내
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.green)
                            Text("기본 프록시 자동 적용 중")
                                .font(.system(size: 13, weight: .bold))
                            Spacer()
                            Text(defaultStatusBadge)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(usingCustom ? Color.orange.opacity(0.15) : Color.green.opacity(0.15))
                                .foregroundColor(usingCustom ? .orange : .green)
                                .cornerRadius(4)
                        }
                        Text("PickShot 이 제공하는 Cloudflare Worker 가 자동 연결되어 있어 별도 설정 없이 모든 세션이 바로 작동합니다. 무료 tier (10만 req/day) 로 수백 세션까지 무리 없이 처리.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("현재 프록시: \(service.effectiveProxyURL)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(12)
                    .background(Color.green.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.green.opacity(0.3), lineWidth: 1)
                    )
                    .cornerRadius(8)

                    // 고급 토글
                    Button(action: { withAnimation { showAdvanced.toggle() } }) {
                        HStack(spacing: 6) {
                            Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10))
                            Text("고급 — 내 Cloudflare Worker 사용하기")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)

                    if !showAdvanced {
                        EmptyView()
                    } else {

                    // 왜 CF Worker?
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "gearshape.2.fill")
                                .foregroundColor(.orange)
                            Text("직접 Worker 를 운영하고 싶다면")
                                .font(.system(size: 12, weight: .bold))
                        }
                        Text("자체 도메인/리미트를 원하는 고급 사용자 전용. 아래 3단계로 본인 Cloudflare 계정에 Worker 배포 후 URL 입력. 비워두면 기본 프록시 자동 사용.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.06))
                    .cornerRadius(8)

                    // 단계 1 — 계정 + Worker 생성
                    stepView(num: 1, title: "Cloudflare 계정 + Worker 생성") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("아래 버튼으로 Cloudflare Workers 대시보드 열기 → 로그인 또는 가입(무료)")
                                .font(.system(size: 11))
                            HStack(spacing: 8) {
                                Button(action: {
                                    if let url = URL(string: "https://dash.cloudflare.com/sign-up/workers-and-pages") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }) {
                                    Label("대시보드 열기", systemImage: "safari")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                Spacer()
                            }
                            Text("대시보드에서: 'Workers & Pages' → 'Create' → 'Worker' → 이름 (예: pickshot-proxy) → 'Deploy'")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }

                    // 단계 2 — 코드 붙여넣기
                    stepView(num: 2, title: "코드 붙여넣기 & 배포") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Worker 화면에서 'Edit code' → 기본 코드 전부 지우고 아래 코드 붙여넣기 → 'Deploy'")
                                .font(.system(size: 11))
                            HStack(spacing: 6) {
                                Button(action: copyCode) {
                                    Label("코드 복사", systemImage: "doc.on.doc")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button(action: { showCode.toggle() }) {
                                    Text(showCode ? "코드 숨기기" : "코드 보기")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.blue)
                                Spacer()
                            }
                            if showCode {
                                Text(workerCode)
                                    .font(.system(size: 10, design: .monospaced))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.black.opacity(0.4))
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    // 단계 3 — URL 복사 & 붙여넣기
                    stepView(num: 3, title: "Worker URL 복사 & 붙여넣기") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("배포 후 표시되는 URL (예: https://pickshot-proxy.xxx.workers.dev) 복사 → 아래에 붙여넣기")
                                .font(.system(size: 11))
                            HStack {
                                Image(systemName: "link")
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                                TextField("https://pickshot-proxy.xxx.workers.dev", text: $proxyURL)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            HStack(spacing: 8) {
                                Button(action: testConnection) {
                                    if case .testing = testResult {
                                        HStack(spacing: 6) {
                                            ProgressView().scaleEffect(0.5)
                                            Text("테스트 중...")
                                        }
                                    } else {
                                        Label("연결 테스트", systemImage: "bolt.fill")
                                    }
                                }
                                .disabled(proxyURL.isEmpty || proxyURL.contains("xxx"))

                                Spacer()

                                switch testResult {
                                case .idle: EmptyView()
                                case .testing: EmptyView()
                                case .success(let msg):
                                    Label(msg, systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.green)
                                case .failure(let msg):
                                    Label(msg, systemImage: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }

                    // 팁
                    VStack(alignment: .leading, spacing: 4) {
                        Label("무료 한도 & 유지보수", systemImage: "lightbulb.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.yellow)
                        Text("• 무료 플랜: 하루 100,000회 요청 (소규모 스튜디오엔 넉넉)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("• 코드 업데이트 하려면 같은 Worker 에 코드 다시 저장하면 됨")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("• URL 비워두고 저장 → 프록시 미사용 (URL 내장 방식 폴백)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(Color.yellow.opacity(0.08))
                    .cornerRadius(8)
                    } // end showAdvanced else
                }
                .padding(16)
            }

            Divider()

            // 하단
            HStack {
                Button("기본 프록시로 복원") {
                    proxyURL = ""
                    service.customProxyURL = ""
                    testResult = .idle
                }
                .foregroundColor(.orange)
                .help("커스텀 Worker URL 을 지우고 PickShot 기본 프록시 사용")

                Spacer()

                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("저장") {
                    service.customProxyURL = proxyURL.trimmingCharacters(in: .whitespaces)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 620)
        .onAppear { proxyURL = service.customProxyURL }
    }

    @ViewBuilder
    private func stepView<Content: View>(num: Int, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom))
                    .frame(width: 26, height: 26)
                Text("\(num)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(workerCode, forType: .string)
    }

    private func testConnection() {
        let url = proxyURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, let testURL = URL(string: url) else {
            testResult = .failure("URL 형식이 올바르지 않습니다")
            return
        }
        testResult = .testing
        URLSession.shared.dataTask(with: testURL) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    testResult = .failure(error.localizedDescription)
                } else if let http = response as? HTTPURLResponse {
                    if (200...299).contains(http.statusCode) {
                        testResult = .success("연결 성공 (HTTP \(http.statusCode))")
                    } else {
                        testResult = .failure("HTTP \(http.statusCode)")
                    }
                } else {
                    testResult = .failure("응답 없음")
                }
            }
        }.resume()
    }
}
