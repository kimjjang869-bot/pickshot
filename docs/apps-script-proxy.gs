/**
 * PickShot - Google Apps Script 프록시
 *
 * 역할: Google Drive 의 JSON 매니페스트를 CORS 허용 헤더와 함께 반환.
 *       뷰어 페이지가 Drive 에 있는 매니페스트를 브라우저에서 직접 fetch 할 수 있도록 중계.
 *
 * 사용법:
 *   1. script.google.com 접속 → "새 프로젝트"
 *   2. 이 코드 전체를 붙여넣기
 *   3. "저장" (⌘+S) → 프로젝트 이름 아무거나 입력 (예: PickShot Proxy)
 *   4. "배포" → "새 배포" 클릭
 *      - 유형: "웹 앱"
 *      - 설명: PickShot Manifest Proxy
 *      - 실행: "나"
 *      - 액세스 권한: "모든 사용자"
 *   5. "배포" 클릭 → Google 인증 허용
 *   6. 표시되는 "웹 앱 URL" 복사 (형태: https://script.google.com/macros/s/DEPLOYID/exec)
 *   7. PickShot → 환경설정 → 클라이언트 셀렉 → 프록시 URL 에 붙여넣기
 *
 * 업데이트 시: 코드 수정 → "배포" → "배포 관리" → 수정 아이콘 → 새 버전 선택 → 배포
 */

// CORS 허용 헤더
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type"
};

/**
 * GET 요청 처리: /exec?id=DRIVE_FILE_ID
 * Drive 에 있는 파일을 읽어 CORS 허용 헤더와 함께 JSON 반환.
 */
function doGet(e) {
  try {
    const fileId = (e.parameter && e.parameter.id) || "";
    const folderId = (e.parameter && e.parameter.folder) || "";

    // ① folder 파라미터: 해당 Drive 폴더에서 manifest.json 자동 검색 후 반환
    if (folderId) {
      return findAndReturnManifest(folderId);
    }

    // ② id 파라미터: 특정 Drive 파일 ID 직접 지정
    if (!fileId) {
      return jsonResponse({ error: "id 또는 folder 파라미터가 필요합니다" });
    }
    return returnFileAsJSON(fileId);
  } catch (err) {
    return jsonResponse({ error: err.toString() });
  }
}

/** 폴더 내 manifest.json 찾아 반환 (기존 세션 URL 도 작동하도록) */
function findAndReturnManifest(folderId) {
  try {
    const folder = DriveApp.getFolderById(folderId);
    const files = folder.getFilesByName("manifest.json");
    if (files.hasNext()) {
      return returnFileAsJSON(files.next().getId());
    }
    // manifest.json 없으면 .json 파일 아무거나 첫 번째 시도
    const jsonFiles = folder.getFilesByType(MimeType.PLAIN_TEXT);
    while (jsonFiles.hasNext()) {
      const f = jsonFiles.next();
      if (f.getName().endsWith(".json")) {
        return returnFileAsJSON(f.getId());
      }
    }
    return jsonResponse({ error: "폴더에서 manifest.json 찾을 수 없음" });
  } catch (err) {
    return jsonResponse({ error: "폴더 접근 실패: " + err.toString() });
  }
}

/** 파일 ID → JSON 응답 */
function returnFileAsJSON(fileId) {
  const file = DriveApp.getFileById(fileId);
  const mimeType = file.getMimeType();
  const content = file.getBlob().getDataAsString();

  if (mimeType.indexOf("json") >= 0 || content.trim().startsWith("{")) {
    try {
      const parsed = JSON.parse(content);
      return jsonResponse(parsed);
    } catch (_) {
      return jsonResponse({ error: "유효하지 않은 JSON" });
    }
  }
  return textResponse(content);
}

/** JSON 응답 헬퍼 */
function jsonResponse(data) {
  return ContentService.createTextOutput(JSON.stringify(data))
    .setMimeType(ContentService.MimeType.JSON);
}

/** 텍스트 응답 헬퍼 */
function textResponse(text) {
  return ContentService.createTextOutput(text)
    .setMimeType(ContentService.MimeType.TEXT);
}

/**
 * 설정 확인용 — 브라우저에서 직접 /exec 만 열면 환영 메시지
 */
function doGet_healthcheck() {
  return jsonResponse({
    status: "ok",
    service: "PickShot Proxy",
    usage: "?id=DRIVE_FILE_ID"
  });
}
