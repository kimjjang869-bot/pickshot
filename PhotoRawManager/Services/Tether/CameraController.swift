//
//  CameraController.swift
//  PhotoRawManager
//
//  테더링 카메라 제어 공통 인터페이스.
//  Sony/Canon/Nikon SDK 를 어댑터 패턴으로 연결하기 위한 프로토콜.
//
//  각 SDK 구현체 (SonyCameraAdapter, CanonCameraAdapter, NikonCameraAdapter) 는
//  이 프로토콜을 구현하고, TetherCoordinator 가 브랜드별 선택적으로 로드한다.
//

import Foundation
import AppKit
import Combine

/// 카메라 제조사
enum CameraBrand: String, CaseIterable {
    case sony = "Sony"
    case canon = "Canon"
    case nikon = "Nikon"
    case appleImageCapture = "ImageCaptureCore"  // fallback (파일 전송만)

    var requiresSDK: Bool {
        switch self {
        case .sony, .canon, .nikon: return true
        case .appleImageCapture: return false
        }
    }
}

/// 카메라 프로퍼티 (ISO, 조리개 등). 어댑터마다 지원 여부 다름.
enum CameraProperty: String, CaseIterable, Identifiable {
    var id: String { rawValue }

    case iso                    // ISO 감도
    case aperture               // 조리개 (f-number)
    case shutterSpeed           // 셔터 속도
    case whiteBalance           // 화이트밸런스
    case exposureCompensation   // 노출 보정 (EV)
    case focusMode              // 포커스 모드 (AF-S/AF-C/MF)
    case focusArea              // 포커스 영역
    case driveMode              // 드라이브 모드 (단사/연사/타이머)
    case meteringMode           // 측광 모드
    case imageQuality           // 화질/파일 포맷 (JPEG/RAW/RAW+JPG)
    case pictureProfile         // 픽처 프로파일 (S-Log3 등)
    case batteryLevel           // 배터리 (0-100, read-only)
    case recordingMedia         // 저장 매체 (SD1/SD2/PC)

    var displayName: String {
        switch self {
        case .iso: return "ISO"
        case .aperture: return "조리개"
        case .shutterSpeed: return "셔터"
        case .whiteBalance: return "WB"
        case .exposureCompensation: return "노출 보정"
        case .focusMode: return "AF 모드"
        case .focusArea: return "AF 영역"
        case .driveMode: return "드라이브"
        case .meteringMode: return "측광"
        case .imageQuality: return "화질"
        case .pictureProfile: return "픽처 프로파일"
        case .batteryLevel: return "배터리"
        case .recordingMedia: return "저장 매체"
        }
    }
}

/// 프로퍼티 값 + 사용 가능한 후보 목록.
struct CameraPropertyState: Equatable {
    /// 현재 선택된 값 (카메라에서 읽은 그대로. 예: "ISO 400", "f/2.8", "1/250")
    var current: String
    /// 선택 가능한 값 목록
    var candidates: [String]
    /// 쓰기 가능 여부 (녹화 중 등에 일시 잠길 수 있음)
    var isWritable: Bool
}

/// 촬영 결과 이벤트 (SDK 에서 전달)
struct CaptureEvent {
    enum Kind {
        case shutterFired            // 셔터가 내려감 (파일은 아직)
        case fileReceived(URL)       // 파일 전송 완료
        case fileFailed(String)      // 전송 실패
        case liveViewFrame(NSImage)  // 라이브 뷰 프레임
        case settingsChanged([CameraProperty])  // 특정 설정이 바뀜 (재조회 필요)
    }
    let kind: Kind
    let timestamp: Date
}

/// 테더링 카메라 공통 인터페이스. 각 SDK 어댑터가 구현.
protocol CameraController: AnyObject {
    // MARK: 연결 상태

    var brand: CameraBrand { get }
    var modelName: String { get }
    var serial: String? { get }
    var isConnected: Bool { get }

    /// 이벤트 스트림 (촬영, 설정 변경, 라이브뷰 프레임 등)
    var eventPublisher: AnyPublisher<CaptureEvent, Never> { get }

    // MARK: 연결 관리

    /// 연결 시작 (USB 또는 Wi-Fi 검색 + 세션 열기).
    /// - Returns: 성공 시 연결된 카메라 정보, 실패 시 throws.
    func connect() async throws

    /// 연결 해제
    func disconnect() async

    // MARK: 설정값 제어

    /// 현재 카메라가 지원하는 프로퍼티 목록
    var supportedProperties: [CameraProperty] { get }

    /// 특정 프로퍼티 현재 상태 조회
    func read(_ property: CameraProperty) async -> CameraPropertyState?

    /// 특정 프로퍼티에 값 쓰기 (candidates 중 하나)
    /// - Returns: 쓰기 성공 여부
    func write(_ property: CameraProperty, value: String) async -> Bool

    // MARK: 촬영

    /// 셔터 반누름 (AF + AE lock)
    func shutterHalfPress() async

    /// 셔터 완전 누름 (실제 촬영)
    func shutterFullPress() async

    /// 셔터 놓기
    func shutterRelease() async

    // MARK: 라이브 뷰

    /// 라이브 뷰 지원 여부
    var supportsLiveView: Bool { get }

    /// 라이브 뷰 시작 (eventPublisher 로 .liveViewFrame 프레임 전송)
    func startLiveView() async throws

    /// 라이브 뷰 중지
    func stopLiveView() async

    // MARK: 파일 전송

    /// 카메라가 촬영한 파일을 저장할 폴더 지정
    func setDownloadFolder(_ url: URL)
}

/// 어댑터 에러
enum CameraControllerError: LocalizedError {
    case sdkNotAvailable(String)       // SDK 가 앱에 번들되지 않음 (승인 대기 등)
    case deviceNotFound
    case connectionFailed(String)
    case propertyNotSupported(CameraProperty)
    case writeFailed(String)
    case busy                          // 다른 작업 진행 중

    var errorDescription: String? {
        switch self {
        case .sdkNotAvailable(let msg): return "SDK 미설치: \(msg)"
        case .deviceNotFound: return "카메라를 찾을 수 없습니다"
        case .connectionFailed(let msg): return "연결 실패: \(msg)"
        case .propertyNotSupported(let p): return "\(p.displayName) 은 이 카메라에서 지원 안 함"
        case .writeFailed(let msg): return "설정 변경 실패: \(msg)"
        case .busy: return "카메라가 사용 중입니다"
        }
    }
}
