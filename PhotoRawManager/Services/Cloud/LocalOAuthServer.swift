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
    private let completion: (String?, Error?) -> Void
    /// v8.6.1: OAuth state 검증 (CSRF 방지) — 요청 시작 전 세팅한 값과 콜백 state 가 일치해야 함.
    private let expectedState: String?

    init(port: UInt16, expectedState: String? = nil, completion: @escaping (String?, Error?) -> Void) {
        self.port = port
        self.expectedState = expectedState
        self.completion = completion
    }

    func start() {
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                completion(nil, NSError(domain: "LocalOAuthServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid port: \(port)"]))
                return
            }
            listener = try NWListener(using: .tcp, on: nwPort)
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    fputs("[OAUTH-SRV] ✅ listener ready on port \(self?.port ?? 0)\n", stderr)
                case .failed(let err):
                    fputs("[OAUTH-SRV] ❌ listener failed: \(err.localizedDescription)\n", stderr)
                    DispatchQueue.main.async {
                        self?.completion(nil, err)
                    }
                case .cancelled:
                    fputs("[OAUTH-SRV] listener cancelled\n", stderr)
                case .waiting(let err):
                    fputs("[OAUTH-SRV] ⚠️ listener waiting: \(err.localizedDescription)\n", stderr)
                default:
                    fputs("[OAUTH-SRV] listener state: \(state)\n", stderr)
                }
            }
            listener?.newConnectionHandler = { [weak self] connection in
                fputs("[OAUTH-SRV] 📥 incoming connection\n", stderr)
                self?.handleConnection(connection)
            }
            listener?.start(queue: .global(qos: .userInitiated))
            fputs("[OAUTH-SRV] start() called, port=\(port)\n", stderr)
        } catch {
            fputs("[OAUTH-SRV] ❌ start() threw: \(error.localizedDescription)\n", stderr)
            completion(nil, error)
        }
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
                fputs("[OAUTH-SRV] ❌ state mismatch: expected=\(self?.expectedState ?? "nil") got=\(state ?? "nil")\n", stderr)
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
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"

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
