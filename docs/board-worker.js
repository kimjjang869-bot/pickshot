/**
 * PickShot 피드백 게시판 — Cloudflare Worker
 *
 * 무료. 회원가입 없음. Cloudflare KV 저장소 사용.
 *
 * ============ 배포 방법 (5분) ============
 *
 * 1) https://dash.cloudflare.com → Workers & Pages → Create
 * 2) Worker 선택 → 이름 "pickshot-board" → Deploy
 * 3) Edit code → 기본 내용 전부 지우고 이 파일 내용 붙여넣기 → Deploy
 * 4) 좌측 메뉴 → Workers & Pages → KV 클릭
 *    - Create namespace → 이름 "BOARD" → Add
 * 5) 다시 워커로: pickshot-board → Settings → Variables → KV Namespace Bindings
 *    - Variable name: BOARD
 *    - KV namespace: BOARD (방금 만든 것)
 *    - Save
 * 6) 워커 URL 복사 (형식: https://pickshot-board.<계정>.workers.dev)
 * 7) feedback.html 의 BOARD_API 상수에 URL 붙여넣기
 *
 * 무료 한도 (Workers):
 *   - 일 100,000 요청
 *   - KV: 일 100,000 읽기 / 1,000 쓰기 (게시판 규모 충분)
 */

const CORS_ORIGIN = '*';                  // 운영 시엔 본인 사이트로 한정 추천: 'https://kimjjang869-bot.github.io'
const RATE_LIMIT_PER_HOUR = 5;            // IP 당 시간당 게시 가능 횟수
const MAX_POSTS_PER_BOARD = 500;          // 보드당 최대 보관 글 수 (오래된 글 자동 정리)
const MAX_TITLE = 120;
const MAX_BODY = 5000;
const VALID_BOARDS = ['bug', 'feature'];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/$/, '');

    if (request.method === 'OPTIONS') return new Response(null, { headers: cors() });

    try {
      if (path === '' || path === '/posts') return listPosts(url, env);
      if (path === '/post' && request.method === 'GET') return getPost(url, env);
      if (path === '/post' && request.method === 'POST') return createPost(request, env);
      if (path === '/post' && request.method === 'DELETE') return deletePost(request, url, env);
      if (path === '/comment' && request.method === 'POST') return addComment(request, env);
      return json({ error: 'not found' }, 404);
    } catch (e) {
      return json({ error: String(e.message || e) }, 500);
    }
  }
};

// ============ Handlers ============

async function listPosts(url, env) {
  const board = url.searchParams.get('board');
  if (!VALID_BOARDS.includes(board)) return json({ error: 'invalid board' }, 400);
  const list = await loadIndex(env, board);
  // 최신순 (생성시각 내림차순)
  list.sort((a, b) => b.createdAt - a.createdAt);
  // password 등 민감 필드는 응답에서 제거
  const safe = list.map(p => ({
    id: p.id,
    title: p.title,
    author: p.author,
    bodyPreview: (p.body || '').slice(0, 200),
    commentCount: (p.comments || []).length,
    createdAt: p.createdAt,
    state: p.state || 'open',
  }));
  return json({ posts: safe });
}

async function getPost(url, env) {
  const id = url.searchParams.get('id');
  if (!id) return json({ error: 'id required' }, 400);
  const post = await env.BOARD.get(`post:${id}`, 'json');
  if (!post) return json({ error: 'not found' }, 404);
  // password 제거
  const { password, ipHash, ...safe } = post;
  safe.comments = (post.comments || []).map(c => {
    const { password: _, ipHash: __, ...rest } = c;
    return rest;
  });
  return json(safe);
}

async function createPost(request, env) {
  const body = await request.json().catch(() => ({}));
  const board = body.board;
  if (!VALID_BOARDS.includes(board)) return json({ error: 'invalid board' }, 400);

  // 봇 차단 (honeypot — 사람이면 비워둠)
  if (body.website) return json({ error: 'spam' }, 400);

  const title = sanitize(body.title || '', MAX_TITLE);
  const text = sanitize(body.body || '', MAX_BODY);
  const author = sanitize(body.author || '익명', 30);
  const password = (body.password || '').slice(0, 50);
  if (!title.trim() || !text.trim()) return json({ error: '제목과 내용을 입력하세요' }, 400);
  if (!password) return json({ error: '비밀번호를 입력하세요 (수정/삭제용)' }, 400);

  const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
  if (!(await checkRateLimit(env, ip))) return json({ error: '잠시 후 다시 시도해주세요 (시간당 5회 제한)' }, 429);

  const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const post = {
    id,
    board,
    title,
    body: text,
    author,
    password: await sha256(password),
    ipHash: await sha256(ip),
    comments: [],
    state: 'open',
    createdAt: Date.now(),
  };
  await env.BOARD.put(`post:${id}`, JSON.stringify(post));
  await appendIndex(env, board, id);
  return json({ ok: true, id });
}

async function deletePost(request, url, env) {
  const id = url.searchParams.get('id');
  const body = await request.json().catch(() => ({}));
  const password = body.password || '';
  if (!id || !password) return json({ error: 'id + password required' }, 400);
  const post = await env.BOARD.get(`post:${id}`, 'json');
  if (!post) return json({ error: 'not found' }, 404);
  if (post.password !== await sha256(password)) return json({ error: '비밀번호 불일치' }, 403);
  await env.BOARD.delete(`post:${id}`);
  await removeFromIndex(env, post.board, id);
  return json({ ok: true });
}

async function addComment(request, env) {
  const body = await request.json().catch(() => ({}));
  const id = body.postId;
  if (!id) return json({ error: 'postId required' }, 400);
  if (body.website) return json({ error: 'spam' }, 400);

  const text = sanitize(body.body || '', 1000);
  const author = sanitize(body.author || '익명', 30);
  const password = (body.password || '').slice(0, 50);
  if (!text.trim()) return json({ error: '댓글 내용을 입력하세요' }, 400);

  const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
  if (!(await checkRateLimit(env, ip, 10))) return json({ error: '잠시 후 다시 시도해주세요' }, 429);

  const post = await env.BOARD.get(`post:${id}`, 'json');
  if (!post) return json({ error: 'post not found' }, 404);

  const comment = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
    body: text,
    author,
    password: password ? await sha256(password) : '',
    ipHash: await sha256(ip),
    createdAt: Date.now(),
  };
  post.comments = post.comments || [];
  post.comments.push(comment);
  await env.BOARD.put(`post:${id}`, JSON.stringify(post));
  await touchIndex(env, post.board, id, { commentCount: post.comments.length });
  return json({ ok: true });
}

// ============ Index helpers ============
// 보드 목록은 KV "index:{board}" 에 [{id, title, author, createdAt, commentCount, state}] 캐시.
// 글 추가/삭제/댓글 시 갱신. 목록 조회는 이 한 번의 read 만.

async function loadIndex(env, board) {
  return (await env.BOARD.get(`index:${board}`, 'json')) || [];
}

async function appendIndex(env, board, id) {
  const post = await env.BOARD.get(`post:${id}`, 'json');
  if (!post) return;
  let list = await loadIndex(env, board);
  list.unshift({
    id: post.id,
    title: post.title,
    author: post.author,
    body: post.body,
    createdAt: post.createdAt,
    commentCount: 0,
    state: post.state || 'open',
  });
  // cap
  if (list.length > MAX_POSTS_PER_BOARD) {
    const removed = list.slice(MAX_POSTS_PER_BOARD);
    list = list.slice(0, MAX_POSTS_PER_BOARD);
    // 오래된 글 본체도 삭제 (KV 절약)
    for (const r of removed) await env.BOARD.delete(`post:${r.id}`);
  }
  await env.BOARD.put(`index:${board}`, JSON.stringify(list));
}

async function removeFromIndex(env, board, id) {
  const list = (await loadIndex(env, board)).filter(p => p.id !== id);
  await env.BOARD.put(`index:${board}`, JSON.stringify(list));
}

async function touchIndex(env, board, id, patch) {
  const list = await loadIndex(env, board);
  const idx = list.findIndex(p => p.id === id);
  if (idx === -1) return;
  list[idx] = { ...list[idx], ...patch };
  await env.BOARD.put(`index:${board}`, JSON.stringify(list));
}

// ============ Rate limit ============

async function checkRateLimit(env, ip, limit = RATE_LIMIT_PER_HOUR) {
  const ipHash = await sha256(ip);
  const key = `rl:${ipHash}:${Math.floor(Date.now() / 3600000)}`;
  const cur = parseInt((await env.BOARD.get(key)) || '0', 10);
  if (cur >= limit) return false;
  await env.BOARD.put(key, String(cur + 1), { expirationTtl: 3600 });
  return true;
}

// ============ Utils ============

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...cors() },
  });
}

function cors() {
  return {
    'Access-Control-Allow-Origin': CORS_ORIGIN,
    'Access-Control-Allow-Methods': 'GET,POST,DELETE,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
}

function sanitize(s, max) {
  return String(s).slice(0, max).replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, '');
}

async function sha256(s) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('');
}
