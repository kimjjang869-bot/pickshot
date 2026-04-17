//
//  SonyCameraAdapter.swift
//  PhotoRawManager
//
//  Sony Camera Remote SDK 어댑터 (승인 대기 중 스켈레톤).
//
//  SDK 승인 받은 후:
//  1. Sony SDK 를 Frameworks/CameraRemoteSDK.framework 로 번들
//  2. Bridging/SonyBridge.mm 에서 C++ API 를 Obj-C 로 래핑
//  3. 이 파일의 stubs 를 실제 SDK 호출로 교체
//
//  현재는 "SDK 미설치" 에러만 던지는 더미 구현.
//

import Foundation
import AppKit
import Combine

final class SonyCameraAdapter: CameraController {
    // MARK: Protocol

    let brand: CameraBrand = .sony
    private(set) var modelName: String = "Sony Camera (SDK 대기 중)"
    private(set) var serial: String? = nil
    private(set) var isConnected: Bool = false

    private let eventSubject = PassthroughSubject<CaptureEvent, Never>()
    var eventPublisher: AnyPublisher<CaptureEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    let supportsLiveView: Bool = true

    var supportedProperties: [CameraProperty] {
        [.iso, .aperture, .shutterSpeed, .whiteBalance,
         .exposureCompensation, .focusMode, .focusArea, .driveMode,
         .meteringMode, .imageQuality, .pictureProfile,
         .batteryLevel, .recordingMedia]
    }

    private var downloadFolder: URL

    init(downloadFolder: URL) {
        self.downloadFolder = downloadFolder
    }

    func setDownloadFolder(_ url: URL) {
        self.downloadFolder = url
    }

    // MARK: Connection

    func connect() async throws {
        // SDK 미설치 — 정식 통합 후 교체
        throw CameraControllerError.sdkNotAvailable("""
        Sony Camera Remote SDK 가 아직 번들되지 않았습니다.
        https://support.d-imaging.sony.co.jp/app/sdk/en/ 에서 신청 → EULA 서명 → SDK 수신 후 통합 예정.
        """)
    }

    func disconnect() async {
        isConnected = false
    }

    // MARK: Properties

    func read(_ property: CameraProperty) async -> CameraPropertyState? {
        return nil
    }

    func write(_ property: CameraProperty, value: String) async -> Bool {
        return false
    }

    // MARK: Shutter

    func shutterHalfPress() async {}
    func shutterFullPress() async {}
    func shutterRelease() async {}

    // MARK: Live View

    func startLiveView() async throws {
        throw CameraControllerError.sdkNotAvailable("Sony SDK 통합 대기 중")
    }

    func stopLiveView() async {}
}

// MARK: - Sony SDK 통합 메모 (참고용)
//
// 1. SDK 구조 (예상):
//    - CrSDK.framework (C++ headers + .dylib)
//    - CrAdapter 플러그인 (Crash CrAdapter.framework)
//
// 2. Obj-C++ Bridge 에서 래핑해야 할 주요 함수:
//    - CrSDK_Init()
//    - CrSDK_EnumCameraObjects()
//    - CrSDK_Connect(device, callback)
//    - CrSDK_SetDeviceProperty(deviceHandle, propertyCode, value)
//    - CrSDK_GetLiveViewImage(deviceHandle) → JPEG bytes
//    - CrSDK_Disconnect(deviceHandle)
//
// 3. 콜백 이벤트:
//    - OnConnected/OnDisconnected
//    - OnPropertyChanged (ISO/Av/Tv 변경)
//    - OnCompleteDownload (파일 도착)
//
// 4. 실행 환경:
//    - Sony 카메라를 "PC Remote" 모드로 설정
//    - macOS: Imaging Edge Desktop 이 먼저 실행 중이면 충돌 → 먼저 종료 필요
//
// 5. Sony SDK Property Codes (참고):
//    ISO = 0x0002100 계열
//    Av = 0x0002104
//    Tv = 0x0002103
//    WB = 0x000210B
//    (정확한 값은 SDK 헤더 확인)
