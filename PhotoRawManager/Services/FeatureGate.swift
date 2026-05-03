//
//  FeatureGate.swift
//  PickShot v9.1+ — Pro 전용 기능 enum + 게이팅 헬퍼
//
//  사용:
//    if FeatureGate.allows(.clientSelect) { ... }
//    else { showProLockModal(for: .clientSelect) }
//

import Foundation

/// Pro 전용 (또는 미래에 게이트할) 기능 일람.
///   simple = false → Simple 사용자도 사용 가능
///   simple = true  → Simple 사용자도 사용 가능 (게이트 안 함)
///   기본은 모두 Pro 전용 으로 정의 — 명시적으로 .simple 표시한 것만 무료.
enum AppFeature: String, CaseIterable, Identifiable {
    // ── Pro 결정타: 클라이언트 워크플로우 ──
    case clientSelect           // G-Select 시작 + 웹 뷰어
    case clientWebViewer        // 클라이언트 펜/코멘트 오버레이
    case driveUpload            // Google Drive 업로드

    // ── Pro: AI 자동화 ──
    case burstBestAuto          // 연사 베스트 자동 선별
    case faceGrouping           // 얼굴 그룹 + 이름 태그
    case smartCull              // 스마트 셀렉
    case semanticSearch         // CLIP 의미 검색
    case visualSearch           // 비슷한 사진 찾기

    // ── Pro: 고급 출력 ──
    case rawToJpgConvert        // RAW→JPG 변환 (Stage3 + Lanczos + 화보 느낌)
    case batchProcess           // 배치 워터마크
    case contactSheetPDF        // 컨택트시트 PDF
    case folderStructurePreserve // 원본 폴더 구조 유지

    // ── Pro: 워크플로우 ──
    case tethering              // 카메라 테더링
    case continuousCardBackup   // 연속 메모리카드 백업 (자동 언마운트)
    case aggressiveCache        // 적극 캐시 모드

    // ── Pro: 영상 ──
    case logAutoLUT             // LOG 영상 자동 LUT

    // ── Pro: 호환 ──
    case lightroomBidirectional // XMP 사이드카 양방향
    case pickshotFileImport     // .pickshot 파일 import/export

    var id: String { rawValue }

    /// 사용자에게 보여줄 한국어 이름.
    var displayName: String {
        switch self {
        case .clientSelect:           return "G-Select 클라이언트 셀렉"
        case .clientWebViewer:        return "클라이언트 웹 뷰어"
        case .driveUpload:            return "Google Drive 업로드"
        case .burstBestAuto:          return "연사 베스트 자동 선별"
        case .faceGrouping:           return "얼굴 그룹 · 이름 태그"
        case .smartCull:              return "스마트 셀렉"
        case .semanticSearch:         return "의미 기반 검색"
        case .visualSearch:           return "비슷한 사진 찾기"
        case .rawToJpgConvert:        return "RAW → JPG 변환"
        case .batchProcess:           return "배치 처리"
        case .contactSheetPDF:        return "컨택트시트 PDF"
        case .folderStructurePreserve:return "원본 폴더 구조 유지"
        case .tethering:              return "카메라 테더링"
        case .continuousCardBackup:   return "연속 메모리카드 백업"
        case .aggressiveCache:        return "적극 캐시 모드"
        case .logAutoLUT:             return "LOG 영상 자동 LUT"
        case .lightroomBidirectional: return "Lightroom 양방향"
        case .pickshotFileImport:     return ".pickshot 파일 import"
        }
    }

    /// 잠금 모달에서 보여줄 짧은 설명.
    var blurb: String {
        switch self {
        case .clientSelect, .clientWebViewer:
            return "촬영 직후 클라이언트가 브라우저에서 별점/펜/코멘트.\n내 Mac 에 실시간 반영. 미팅 1회 ≒ 1시간 절약."
        case .driveUpload:
            return "Google Drive 자동 업로드. 링크 한 줄로 공유 — 카탈로그 만들 필요 없음."
        case .burstBestAuto:
            return "연사 그룹에서 베스트 1장 자동 선별 (눈뜸 / 포커스 / 노출 / 미소).\n1만장 폴더 30분 → 5분."
        case .faceGrouping:
            return "AdaFace R18 로컬 추론 — 같은 사람 자동 그룹.\n이름 태그 + 다중 인물 필터. 모든 처리 온디바이스."
        case .smartCull:
            return "장면 분류 + 품질 점수로 베스트만 자동 선택.\nHDR/포트레이트/풍경/이벤트 룩북."
        case .semanticSearch:
            return "\"노을에서 웃는 여자\" — MobileCLIP 로컬 임베딩.\n얼굴/옷/포즈/장면 검색."
        case .visualSearch:
            return "선택한 영역 (얼굴/사물) 과 비슷한 사진 찾기.\n드래그 한 번에 1만장 검색."
        case .rawToJpgConvert:
            return "Stage 3 임베디드 + 다단계 Lanczos. 카메라 색감 그대로.\n화보 느낌 / DPI / 해상도 직접 입력."
        case .batchProcess:
            return "워터마크 일괄 적용 + 리사이즈 + 컬러프로파일.\n수백장 한 번에."
        case .contactSheetPDF:
            return "컨택트시트 PDF 자동 생성.\n클라이언트 미리보기 + 인쇄용."
        case .folderStructurePreserve:
            return "하위폴더 모드에서 원본 폴더 구조 그대로 출력.\n[01_웨딩/홀] → [01_웨딩/홀] 자동 분류."
        case .tethering:
            return "USB 카메라 직결. 셔터 누른 즉시 PickShot 에 표시.\n실시간 셀렉 + 자동 백업."
        case .continuousCardBackup:
            return "카드 꽂으면 복사 → 언마운트 → 다음 카드 대기.\n6장 연속도 손 안 떼고."
        case .aggressiveCache:
            return "툴바 ⚡ 버튼. 폴더 진입 즉시 전체 프리뷰 병렬 캐싱.\n10,000장 폴더 40초 풀 예열."
        case .logAutoLUT:
            return "S-Log3 / V-Log / D-Log 자동 감지 + LUT 자동 적용.\n프리미어 켜기 전 셀렉 완료."
        case .lightroomBidirectional:
            return "XMP 사이드카로 별점 / 라벨 / 보정값 양방향.\nLightroom 카탈로그 대체 가능."
        case .pickshotFileImport:
            return ".pickshot 파일로 다른 Mac 과 셀렉 결과 공유.\n협업 워크플로우 지원."
        }
    }

    /// 이 기능이 Pro 전용인가? (현재 모든 항목 Pro)
    var requiresPro: Bool { true }

    /// v9.0.2: 출시 상태 — comingSoon 인 기능은 Pro 사용자에게도 비활성.
    var releaseStatus: ReleaseStatus {
        switch self {
        // AI 카테고리는 v9.1+ 공개 예정 — 아직 미완성
        case .burstBestAuto,
             .faceGrouping,
             .smartCull,
             .semanticSearch,
             .visualSearch:
            return .comingSoon
        // .pickshotFileImport 도 협업 워크플로우 미완성 → 추후 공개
        case .pickshotFileImport:
            return .comingSoon
        // 테더링은 안정성 미흡 → v9.1+ 공개 예정
        case .tethering:
            return .comingSoon
        default:
            return .released
        }
    }
}

/// 기능의 출시 상태.
enum ReleaseStatus {
    case released       // 정상 사용 가능
    case comingSoon     // 추후 공개 예정 — Pro 사용자도 비활성
    case beta           // 베타 (현재 미사용)
}

/// 기능 게이트 — 한 줄로 권한 체크.
@MainActor
enum FeatureGate {
    /// 사용자가 이 기능을 사용할 수 있는가?
    static func allows(_ feature: AppFeature) -> Bool {
        if feature.releaseStatus == .comingSoon { return false }
        if !feature.requiresPro { return true }
        return TierManager.shared.hasPro
    }

    /// 이 기능이 "출시 예정" 상태인가? (Pro 잠금 vs 추후 공개 구분용)
    static func isComingSoon(_ feature: AppFeature) -> Bool {
        return feature.releaseStatus == .comingSoon
    }
}
