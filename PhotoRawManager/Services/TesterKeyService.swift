//
//  TesterKeyService.swift
//  PhotoRawManager
//
//  출시 전 테스터용 1년 활성화 키 시스템.
//  - 키는 앱 바이너리에 SHA256 해시 형태로만 들어가고, 원문은 외부(스프레드시트)에만 보관.
//  - 한 기기에 한 개의 키만 활성화 가능 (덮어쓰기 방지).
//  - 기기 간 완전 단일 사용은 offline 특성상 불가 → 유출된 해시는 차후 업데이트로 revoke.
//

import Foundation
import CryptoKit

enum TesterKeyService {

    // MARK: - 유효한 키 해시 (SHA256, lowercase hex)

    /// 현재 유효한 테스터 키의 해시 목록. 키가 새어나가면 해당 해시를 `revokedKeyHashes` 로 옮김.
    private static let validKeyHashes: Set<String> = [
        "02c93541f37ec6f9447a4e178637b4342a8817d93c9229d7bcca53eb46bfc787",
        "0722b2caa120b56f809b4f3ae8088f4d3603e979200f1f9bce212bb35a6eccaa",
        "085f94b0487319009ec211bed9fca38f8a4569feaf20128102a927fcefee0f17",
        "2df0f9e6387163fc01abb4276c829018fb88a0565d1f98870c9957a1ff0eabb4",
        "a45fa0e09f596fe9afaa2f3236c42d3ed02a2bc6e657182a0890351ac5106895",
        "bfcc668418598d9799d790b3b0e3cadb3612804ba18133a74995e5022f1fe05a",
        "beeae991dca64ce4f425eb0957e75cd98b92ca6e531f39c30ac4a4bd04d238ba",
        "f6a397f0b3415d806b15d22e41b6c9dafad162db77f525827954eba5ff1e5ed9",
        "78bc4c6bdeff8ec4265efb10931469de3d689bb91c2e3807651d2f464ba1711c",
        "2216a4fac788def4388c2fd1395f9009465afee3f41e911ef7beb06101faae34",
        "955bae4d8d8cb65f07d286690b4206b8ae0baa690ac18fd1328bdcb225e7a832",
        "3a0ab6980f6ceea98b1eea6cafe6a30b6a52a0fd3f25e34e5d877810f3f2cbea",
        "fc425e7eca91e157224aa0c06c93d94d127d28de07ef33048e41e76d5169fac8",
        "ceddb2c5b2b3a5ccf5bc86e3f05bdb874f7977a94d862a911c541326a91ae47e",
        "f9f2d1aae15b86251e0142410bcc986f86106ceb7a3a476ef77c65d96157de4b",
        "fa88b661ddd1b57e872db7299989bcb047c05903f65fd6953eca6483694d6d7e",
        "6ddd95522b9011203a0b263365d8b0c24dee72e2719f781dfe9d2d7add647618",
        "0fb506699882b1c4c93b0128609d615594ef53b27d57e9d88ff4185c9f548ce8",
        "b19e7d148b472c5b2cc008159770c375a6f2eec944744f79f6485d3d22266902",
        "999decccf7470321da568122be6f0d139ab5966de3e23420b7e021899197350e",
    ]

    /// 유출되어 무효화된 키 해시. 이 집합에 있는 해시로는 더 이상 활성화/검증되지 않음.
    private static let revokedKeyHashes: Set<String> = []

    // MARK: - 설정

    /// 활성화 후 유효 기간 (365일)
    private static let durationSeconds: TimeInterval = 365 * 24 * 60 * 60

    // MARK: - Keychain 키

    private static let kActivatedHash = "pickshot.tester.keyhash"
    private static let kActivatedAt = "pickshot.tester.activatedAt"

    // MARK: - 결과 타입

    enum ActivationResult {
        /// 성공. `expiry` 까지 유효.
        case success(expiry: Date)
        /// 유효하지 않은 키.
        case invalid
        /// 유출되어 무효화된 키.
        case revoked
        /// 이미 이 기기에 동일 키로 활성화됨.
        case alreadyActivated(expiry: Date)
        /// 이 기기는 이미 다른 테스터 키로 활성화되었음 (한 기기 1개 제한).
        case deviceAlreadyHasKey
    }

    // MARK: - Public API

    /// 현재 기기가 유효한 테스터 키로 활성화되어 있고 만료되지 않았는지.
    static func isActive() -> Bool {
        guard let expiry = currentExpiryDate() else { return false }
        return expiry > Date()
    }

    /// 현재 기기에 저장된 만료일. 없거나 해시가 revoke 된 경우 nil.
    static func currentExpiryDate() -> Date? {
        guard let hash = KeychainService.read(key: kActivatedHash),
              validKeyHashes.contains(hash),
              !revokedKeyHashes.contains(hash),
              let atStr = KeychainService.read(key: kActivatedAt),
              let at = Double(atStr)
        else { return nil }
        return Date(timeIntervalSince1970: at).addingTimeInterval(durationSeconds)
    }

    /// 남은 일수. 비활성이면 0.
    static func daysRemaining() -> Int {
        guard let expiry = currentExpiryDate() else { return 0 }
        let remaining = expiry.timeIntervalSince(Date())
        return max(0, Int(ceil(remaining / (24 * 60 * 60))))
    }

    /// 키 활성화 시도.
    static func activate(code rawCode: String) -> ActivationResult {
        let normalized = rawCode
            .uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        let hash = sha256Hex(normalized)

        // revoke 된 키
        if revokedKeyHashes.contains(hash) { return .revoked }

        // 유효하지 않은 키
        guard validKeyHashes.contains(hash) else { return .invalid }

        // 이미 활성화되어 있는지 확인
        if let existing = KeychainService.read(key: kActivatedHash) {
            if existing == hash {
                // 같은 키로 이미 활성화됨 → 만료일만 알려줌
                if let expiry = currentExpiryDate() {
                    return .alreadyActivated(expiry: expiry)
                }
                // 해시는 있지만 날짜가 망가진 희귀 케이스 → 덮어쓰기 허용
            } else {
                // 다른 키가 이미 활성화된 상태 → 1기기 1키 원칙
                return .deviceAlreadyHasKey
            }
        }

        // 새로 활성화
        let now = Date()
        _ = KeychainService.save(key: kActivatedHash, value: hash)
        _ = KeychainService.save(key: kActivatedAt, value: String(now.timeIntervalSince1970))
        AppLogger.log(.general, "TesterKey 활성화: 만료 \(now.addingTimeInterval(durationSeconds))")
        return .success(expiry: now.addingTimeInterval(durationSeconds))
    }

    /// 디버그/복구용 초기화. 일반 배포에서는 호출하지 않음.
    static func reset() {
        _ = KeychainService.delete(key: kActivatedHash)
        _ = KeychainService.delete(key: kActivatedAt)
    }

    // MARK: - Helpers

    private static func sha256Hex(_ s: String) -> String {
        let data = Data(s.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
