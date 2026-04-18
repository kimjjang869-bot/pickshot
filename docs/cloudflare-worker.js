/**
 * PickShot Cloudflare Worker — Google Drive CORS 프록시
 *
 * 역할: Google Drive 의 매니페스트 JSON 을 브라우저에 CORS 허용 헤더와 함께 릴레이.
 *       뷰어가 drive.google.com 에서 직접 받지 못하는 JSON 을 우회해 받아옴.
 *
 * 배포 방법:
 *   1. https://dash.cloudflare.com/ 접속 → Workers & Pages → "Create" → "Worker"
 *   2. 이름 입력 (예: pickshot-proxy) → "Deploy"
 *   3. "Edit code" 클릭 → 기본 코드 전부 지우고 이 파일 내용 붙여넣기
 *   4. "Deploy" 클릭
 *   5. 상단에 표시되는 URL 복사 (형태: https://pickshot-proxy.<계정>.workers.dev)
 *   6. PickShot → 클라이언트 → "프록시 설정" → URL 붙여넣기
 *
 * 무료 한도: 일 100,000 요청 — 소규모 스튜디오 사용에 충분.
 */

export default {
  async fetch(request) {
    const url = new URL(request.url);

    // CORS preflight 처리
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        headers: corsHeaders(),
      });
    }

    // 경로 형태: /?id=FILE_ID 또는 /exec?id=FILE_ID (Apps Script 호환)
    const fileId = url.searchParams.get('id');
    if (!fileId) {
      return jsonResponse({
        status: 'ok',
        service: 'PickShot CF Worker',
        usage: '?id=DRIVE_FILE_ID',
      });
    }

    try {
      // Drive 공개 파일 다운로드 (파일이 "링크가 있는 모든 사용자" 공유 상태여야 함)
      const driveURL = `https://drive.google.com/uc?export=download&id=${encodeURIComponent(fileId)}`;

      const driveResp = await fetch(driveURL, {
        cf: { cacheTtl: 120, cacheEverything: true },
        headers: {
          // Drive 가 HTML confirm 페이지 내는 걸 방지하기 위해 User-Agent 지정
          'User-Agent': 'PickShot-CF-Proxy/1.0',
        },
      });

      if (!driveResp.ok) {
        // 첫 번째 URL 실패 시 대체 엔드포인트 시도
        const altURL = `https://drive.usercontent.google.com/download?id=${encodeURIComponent(fileId)}&export=download`;
        const altResp = await fetch(altURL, { cf: { cacheTtl: 120 } });
        if (!altResp.ok) {
          return jsonResponse({
            error: `Drive 접근 실패 (HTTP ${driveResp.status})`,
            hint: '파일이 "링크가 있는 모든 사용자" 로 공유돼 있는지 확인',
          }, driveResp.status);
        }
        return passthrough(altResp);
      }

      return passthrough(driveResp);
    } catch (err) {
      return jsonResponse({ error: err.toString() }, 500);
    }
  },
};

/** Drive 응답을 그대로 CORS 헤더 추가해 릴레이 */
async function passthrough(driveResp) {
  const content = await driveResp.text();

  // JSON 파싱 시도 → 성공하면 JSON 응답, 실패하면 원본 텍스트
  try {
    const parsed = JSON.parse(content);
    return jsonResponse(parsed);
  } catch (_) {
    return new Response(content, {
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        ...corsHeaders(),
        'Cache-Control': 'public, max-age=60',
      },
    });
  }
}

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'public, max-age=60',
      ...corsHeaders(),
    },
  });
}

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Max-Age': '86400',
  };
}
