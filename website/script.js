// ============================================================
// PickShot v8.8.1 — galaxy theme dynamic interactions
// ============================================================

document.addEventListener('DOMContentLoaded', () => {
  initStarfield();
  initNavScroll();
  initAppMockup();
  initRevealOnScroll();
  initCountUp();
  initCursorGlow();
  fetchLatestVersion();
});

// ─────────────────────────────────────────────────────────
// STARFIELD canvas
// ─────────────────────────────────────────────────────────
function initStarfield() {
  const canvas = document.getElementById('stars-canvas');
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  let W = 0, H = 0;
  const dpr = Math.min(2, window.devicePixelRatio || 1);

  function resize() {
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = W * dpr;
    canvas.height = H * dpr;
    canvas.style.width = W + 'px';
    canvas.style.height = H + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  resize();
  window.addEventListener('resize', resize);

  const STAR_COUNT = Math.max(80, Math.floor(W * H / 12000));
  const stars = Array.from({ length: STAR_COUNT }, () => ({
    x: Math.random() * W,
    y: Math.random() * H,
    z: 0.3 + Math.random() * 0.7,
    r: 0.4 + Math.random() * 1.4,
    hue: 220 + Math.random() * 80,
    twinkle: Math.random() * Math.PI * 2,
    twinkleSpeed: 0.8 + Math.random() * 1.4,
  }));

  let scrollY = window.scrollY;
  window.addEventListener('scroll', () => { scrollY = window.scrollY; }, { passive: true });

  let t0 = performance.now();
  function frame() {
    const t = (performance.now() - t0) / 1000;
    ctx.clearRect(0, 0, W, H);
    for (const s of stars) {
      const parallax = scrollY * s.z * 0.1;
      const y = (s.y - parallax) % H;
      const yy = y < 0 ? y + H : y;
      const alpha = 0.3 + Math.abs(Math.sin(t * s.twinkleSpeed + s.twinkle)) * 0.7;
      ctx.beginPath();
      ctx.fillStyle = `hsla(${s.hue}, 80%, ${60 + s.z * 20}%, ${alpha * s.z})`;
      ctx.shadowBlur = 4 * s.z;
      ctx.shadowColor = ctx.fillStyle;
      ctx.arc(s.x, yy, s.r * s.z, 0, Math.PI * 2);
      ctx.fill();
    }
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

// ─────────────────────────────────────────────────────────
// NAV scroll
// ─────────────────────────────────────────────────────────
function initNavScroll() {
  const nav = document.getElementById('nav');
  if (!nav) return;
  let ticking = false;
  window.addEventListener('scroll', () => {
    if (!ticking) {
      requestAnimationFrame(() => {
        nav.classList.toggle('scrolled', window.scrollY > 8);
        ticking = false;
      });
      ticking = true;
    }
  }, { passive: true });
}

// ─────────────────────────────────────────────────────────
// APP MOCKUP — synthetic thumbnails in hero
// ─────────────────────────────────────────────────────────
function initAppMockup() {
  const grid = document.getElementById('app-grid');
  if (!grid) return;

  const TOTAL = 48;   // 8 cols × 6 rows
  // Nebula/photography palette — no real photos
  const gradients = [
    'radial-gradient(ellipse at 30% 25%, #ffb8a0, transparent 55%), linear-gradient(135deg, #3a2e5a, #6a4a8a)',
    'radial-gradient(ellipse at 65% 40%, #80d8ff, transparent 55%), linear-gradient(135deg, #1e3a5a, #2e5a8a)',
    'radial-gradient(ellipse at 45% 55%, #ff9ab0, transparent 50%), linear-gradient(135deg, #4a2a4a, #7c4a6a)',
    'radial-gradient(ellipse at 25% 60%, #ffd080, transparent 50%), linear-gradient(135deg, #3a2a1a, #6a4a2a)',
    'radial-gradient(ellipse at 70% 30%, #b084ff, transparent 50%), linear-gradient(135deg, #2a1a4a, #5a3a7a)',
    'radial-gradient(ellipse at 50% 45%, #5eead4, transparent 45%), linear-gradient(135deg, #1a3a4a, #3a6a7a)',
    'radial-gradient(ellipse at 35% 35%, #ff7ab6, transparent 50%), linear-gradient(135deg, #3a1a3a, #6a2a5a)',
    'radial-gradient(ellipse at 60% 50%, #a0c0ff, transparent 50%), linear-gradient(135deg, #1a2a4a, #3a4a7a)',
    'radial-gradient(ellipse at 40% 70%, #d4a080, transparent 50%), linear-gradient(135deg, #2a1a1a, #5a3a2a)',
    'radial-gradient(ellipse at 70% 65%, #8eaeff, transparent 50%), linear-gradient(135deg, #1a1e3a, #3a4a6a)',
  ];

  // Predetermined "picked" and "starred" positions for believable distribution
  const pickedIndices = new Set([7, 14, 23, 31, 40]);
  const stars5 = new Set([7, 14, 23, 31, 40, 3, 18, 27]);
  const stars4 = new Set([1, 12, 20, 33, 44]);
  const stars3 = new Set([5, 9, 17, 28, 36, 42]);
  const selectedIdx = 14;  // 선택된 하나

  for (let i = 0; i < TOTAL; i++) {
    const cell = document.createElement('div');
    cell.className = 'app-cell';
    cell.style.background = gradients[i % gradients.length];
    if (i === selectedIdx) cell.classList.add('selected');
    if (pickedIndices.has(i)) cell.classList.add('picked');
    if (stars5.has(i)) cell.classList.add('stars-5');
    else if (stars4.has(i)) cell.classList.add('stars-4');
    else if (stars3.has(i)) cell.classList.add('stars-3');
    grid.appendChild(cell);
  }

  // Animate cells appearing (stagger)
  const cells = grid.querySelectorAll('.app-cell');
  cells.forEach((c, i) => {
    c.style.opacity = '0';
    c.style.transform = 'scale(0.92)';
    c.style.transition = `opacity .4s ease ${200 + i * 18}ms, transform .4s ease ${200 + i * 18}ms, outline-color .3s`;
  });
  // Trigger reveal on visible
  const io = new IntersectionObserver((entries) => {
    entries.forEach(e => {
      if (e.isIntersecting) {
        cells.forEach(c => {
          c.style.opacity = '1';
          c.style.transform = 'scale(1)';
        });
        io.disconnect();
      }
    });
  }, { threshold: 0.1 });
  io.observe(grid);
}

// ─────────────────────────────────────────────────────────
// Reveal on scroll with stagger
// ─────────────────────────────────────────────────────────
function initRevealOnScroll() {
  const els = document.querySelectorAll('[data-reveal]');
  if (!('IntersectionObserver' in window)) {
    els.forEach(el => el.classList.add('in'));
    return;
  }
  const io = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        const parent = entry.target.parentElement;
        const siblings = parent
          ? Array.from(parent.querySelectorAll(':scope > [data-reveal]'))
          : [entry.target];
        const idx = siblings.indexOf(entry.target);
        entry.target.style.transitionDelay = `${Math.min(idx, 10) * 60}ms`;
        entry.target.classList.add('in');
        io.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12, rootMargin: '0px 0px -50px 0px' });
  els.forEach(el => io.observe(el));
}

// ─────────────────────────────────────────────────────────
// Count-up for speed-num
// ─────────────────────────────────────────────────────────
function initCountUp() {
  const nums = document.querySelectorAll('.speed-num[data-count]');
  if (!nums.length) return;

  const animate = (el) => {
    const target = parseFloat(el.dataset.count);
    const suffix = el.dataset.suffix || '';
    const isInt = Number.isInteger(target);
    const duration = 1600;
    const startTime = performance.now();

    function tick(now) {
      const t = Math.min(1, (now - startTime) / duration);
      const eased = 1 - Math.pow(1 - t, 3);
      const val = target * eased;
      el.textContent = (isInt ? Math.floor(val) : val.toFixed(1)) + suffix;
      if (t < 1) requestAnimationFrame(tick);
      else el.textContent = target + suffix;
    }
    requestAnimationFrame(tick);
  };

  if (!('IntersectionObserver' in window)) {
    nums.forEach(animate);
    return;
  }
  const io = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        animate(entry.target);
        io.unobserve(entry.target);
      }
    });
  }, { threshold: 0.4 });
  nums.forEach(el => io.observe(el));
}

// ─────────────────────────────────────────────────────────
// Cursor-reactive glow
// ─────────────────────────────────────────────────────────
function initCursorGlow() {
  const targets = document.querySelectorAll('.btn-primary');
  targets.forEach(el => {
    el.addEventListener('mousemove', (e) => {
      const rect = el.getBoundingClientRect();
      const mx = ((e.clientX - rect.left) / rect.width) * 100;
      const my = ((e.clientY - rect.top) / rect.height) * 100;
      el.style.setProperty('--mx', mx + '%');
      el.style.setProperty('--my', my + '%');
    });
  });
}

// ─────────────────────────────────────────────────────────
// Fetch latest version
// ─────────────────────────────────────────────────────────
async function fetchLatestVersion() {
  try {
    const res = await fetch('https://api.github.com/repos/kimjjang869-bot/pickshot/releases/latest', {
      headers: { 'Accept': 'application/vnd.github+json' }
    });
    if (!res.ok) return;
    const data = await res.json();
    const tag = data.tag_name || '';
    const asset = (data.assets || []).find(a => a.name.endsWith('.dmg'));
    if (!tag || !asset) return;

    const verEl = document.getElementById('download-version');
    if (verEl) verEl.textContent = tag;
    const btn = document.getElementById('download-btn');
    if (btn) btn.href = asset.browser_download_url;
  } catch (_) { /* silent */ }
}
