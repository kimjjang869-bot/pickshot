//
//  LocalOAuthServer.swift
//  PhotoRawManager
//
//  Extracted from GoogleDriveService.swift split.
//

import Foundation
import AppKit
import Network
import CommonCrypto

// MARK: - Local OAuth Server (receives callback from browser)

class LocalOAuthServer {
    private var listener: NWListener?
    private let port: UInt16
    /// v8.8.0: start() 실패 시 실제 바인딩된 port (redirect URI 재생성 용).
    private(set) var boundPort: UInt16 = 0
    private let completion: (String?, Error?) -> Void
    /// v8.6.1: OAuth state 검증 (CSRF 방지) — 요청 시작 전 세팅한 값과 콜백 state 가 일치해야 함.
    private let expectedState: String?

    init(port: UInt16, expectedState: String? = nil, completion: @escaping (String?, Error?) -> Void) {
        self.port = port
        self.expectedState = expectedState
        self.completion = completion
    }

    /// v8.8.0: NWParameters 구성 — localEndpointReuse 허용 (TIME_WAIT 재사용).
    private static func makeParameters() -> NWParameters {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true  // 127.0.0.1 만
        return params
    }

    /// v8.8.0: 포트 8085 가 잡혀있으면 8086, 8087 … 순차 시도.
    private func tryBind(preferredPort: UInt16) -> (listener: NWListener, port: UInt16)? {
        for offset: UInt16 in 0..<20 {
            let candidate = preferredPort &+ offset
            guard let nwPort = NWEndpoint.Port(rawValue: candidate) else { continue }
            if let l = try? NWListener(using: Self.makeParameters(), on: nwPort) {
                plog("[OAUTH-SRV] bound on port \(candidate)\n")
                return (l, candidate)
            } else {
                plog("[OAUTH-SRV] port \(candidate) in use — next\n")
            }
        }
        return nil
    }

    func start() {
        guard NWEndpoint.Port(rawValue: port) != nil else {
            completion(nil, NSError(domain: "LocalOAuthServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid port: \(port)"]))
            return
        }
        guard let result = tryBind(preferredPort: port) else {
            completion(nil, NSError(domain: "LocalOAuthServer", code: -3, userInfo: [NSLocalizedDescriptionKey: "OAuth 로컬 포트(8085~8104)가 모두 사용중입니다. 다른 OAuth 창을 닫거나 앱을 재시작해 주세요."]))
            return
        }
        listener = result.listener
        boundPort = result.port
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                plog("[OAUTH-SRV] ✅ listener ready on port \(self?.boundPort ?? 0)\n")
            case .failed(let err):
                plog("[OAUTH-SRV] ❌ listener failed: \(err.localizedDescription)\n")
                DispatchQueue.main.async {
                    self?.completion(nil, err)
                }
            case .cancelled:
                plog("[OAUTH-SRV] listener cancelled\n")
            case .waiting(let err):
                plog("[OAUTH-SRV] ⚠️ listener waiting: \(err.localizedDescription)\n")
            default:
                plog("[OAUTH-SRV] listener state: \(state)\n")
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            plog("[OAUTH-SRV] 📥 incoming connection\n")
            self?.handleConnection(connection)
        }
        listener?.start(queue: .global(qos: .userInitiated))
        plog("[OAUTH-SRV] start() called, port=\(boundPort)\n")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let data = data, let request = String(data: data, encoding: .utf8) else {
                self?.stop()
                return
            }

            // Parse authorization code and state from GET request
            var code: String?
            var state: String?

            // URL 쿼리 파라미터 안전한 파싱 (HTTP 첫째줄에서 path 추출)
            if let firstLine = request.components(separatedBy: "\r\n").first,
               let pathPart = firstLine.components(separatedBy: " ").dropFirst().first,
               let urlComponents = URLComponents(string: "http://localhost\(pathPart)") {
                code = urlComponents.queryItems?.first(where: { $0.name == "code" })?.value
                state = urlComponents.queryItems?.first(where: { $0.name == "state" })?.value
            }

            // Fallback: 기존 파싱
            if code == nil, let range = request.range(of: "code=") {
                let codeStart = request[range.upperBound...]
                if let end = codeStart.firstIndex(of: "&") ?? codeStart.firstIndex(of: " ") {
                    code = String(codeStart[..<end])
                } else {
                    code = String(codeStart)
                }
            }

            // v8.6.1: OAuth state 검증 (CSRF 방지).
            // expectedState 가 세팅됐는데 callback state 가 다르면 공격자의 code 주입으로 간주 → 거부.
            let stateValid: Bool = {
                guard let expected = self?.expectedState else { return true }  // 검증 비활성 (backward compat)
                return state == expected
            }()

            let html: String
            let returnedCode: String?
            let returnedError: Error?
            if !stateValid {
                html = """
                <html><body style="font-family:-apple-system;text-align:center;padding:60px;background:#1a1a2e;color:#ff6b6b;">
                <h1>⚠️ 보안 오류</h1>
                <p>OAuth state 불일치 — 로그인 취소됨. PickShot에서 다시 시도해주세요.</p>
                </body></html>
                """
                returnedCode = nil
                returnedError = NSError(domain: "LocalOAuthServer", code: -2,
                                        userInfo: [NSLocalizedDescriptionKey: "OAuth state 불일치 (CSRF 의심)"])
                plog("[OAUTH-SRV] ❌ state mismatch: expected=\(self?.expectedState ?? "nil") got=\(state ?? "nil")\n")
            } else {
                html = """
                <html><body style="font-family:-apple-system;text-align:center;padding:60px;background:#1a1a2e;color:white;">
                <h1>✅ PickShot 로그인 성공!</h1>
                <p>이 창을 닫고 PickShot으로 돌아가세요.</p>
                <script>setTimeout(function(){window.close()},2000);</script>
                </body></html>
                """
                returnedCode = code
                returnedError = nil
            }
            // v9.1.4: 보안 헤더 추가 (보안 감사 M-2) — 동일 Mac 내 다른 앱의 iframe / MIME 추측 방어.
            let headers = [
                "HTTP/1.1 200 OK",
                "Content-Type: text/html; charset=utf-8",
                "Content-Length: \(html.utf8.count)",
                "Connection: close",
                "X-Frame-Options: DENY",
                "X-Content-Type-Options: nosniff",
                "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'",
                "Referrer-Policy: no-referrer",
                "Cache-Control: no-store"
            ].joined(separator: "\r\n")
            let response = "\(headers)\r\n\r\n\(html)"

            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            self?.stop()
            DispatchQueue.main.async {
                self?.completion(returnedCode, returnedError)
            }
        }
    }
}
