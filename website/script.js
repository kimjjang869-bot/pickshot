// ============================================================
// PickShot v8.8.1 — galaxy-themed dynamic interactions
// ============================================================

document.addEventListener('DOMContentLoaded', () => {
  initStarfield();
  initNavScroll();
  initHeroViz();
  initRevealOnScroll();
  initCountUp();
  initCursorGlow();
  fetchLatestVersion();
});

// ─────────────────────────────────────────────────────────
// STARFIELD — animated canvas background
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
// NAV scroll state
// ─────────────────────────────────────────────────────────
function initNavScroll() {
  const nav = document.getElementById('nav');
  if (!nav) return;
  let ticking = false;
  window.addEventListener('scroll', () => {
    if (!ticking) {
      window.requestAnimationFrame(() => {
        nav.classList.toggle('scrolled', window.scrollY > 8);
        ticking = false;
      });
      ticking = true;
    }
  }, { passive: true });
}

// ─────────────────────────────────────────────────────────
// HERO loading visualization
// ─────────────────────────────────────────────────────────
function initHeroViz() {
  const grid = document.getElementById('viz-grid');
  const bar = document.getElementById('viz-bar');
  const timer = document.getElementById('viz-timer');
  const counter = document.getElementById('viz-count');
  if (!grid) return;

  const TOTAL_CELLS = 96;   // 16×6
  const TARGET_MS = 1500;

  // Varied nebula hues (purple-blue-teal-pink)
  const paletteHues = [250, 260, 275, 290, 200, 180, 320];

  for (let i = 0; i < TOTAL_CELLS; i++) {
    const cell = document.createElement('div');
    cell.className = 'viz-cell';
    const hue = paletteHues[Math.floor(Math.random() * paletteHues.length)] + Math.random() * 15;
    cell.style.setProperty('--h', hue);
    grid.appendChild(cell);
  }

  const cells = Array.from(grid.children);
  let loopTimeout = null;

  function runLoadCycle() {
    cells.forEach(c => c.classList.remove('loaded', 'ping'));
    bar.style.width = '0%';
    timer.textContent = '0.00초';
    counter.textContent = '10,234';

    const startTime = performance.now();
    let completed = 0;
    const perCell = TARGET_MS / TOTAL_CELLS;

    function loadNext() {
      if (completed >= TOTAL_CELLS) {
        const elapsed = (performance.now() - startTime) / 1000;
        timer.textContent = elapsed.toFixed(2) + '초';
        loopTimeout = setTimeout(runLoadCycle, 2800);
        return;
      }
      const cell = cells[completed];
      cell.classList.add('loaded', 'ping');
      completed++;

      const elapsed = (performance.now() - startTime) / 1000;
      const pct = (completed / TOTAL_CELLS) * 100;
      bar.style.width = pct + '%';
      timer.textContent = elapsed.toFixed(2) + '초';

      const jitter = 0.55 + Math.random() * 0.9;
      setTimeout(loadNext, perCell * jitter);
    }
    setTimeout(loadNext, 200);
  }

  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach(e => {
        if (e.isIntersecting) runLoadCycle();
        else if (loopTimeout) clearTimeout(loopTimeout);
      });
    }, { threshold: 0.2 });
    io.observe(document.querySelector('.hero-viz'));
  } else {
    runLoadCycle();
  }
}

// ─────────────────────────────────────────────────────────
// Reveal on scroll — with stagger for grid children
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
        // Find siblings with data-reveal in the same parent — stagger them
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
  }, { threshold: 0.12, rootMargin: '0px 0px -60px 0px' });
  els.forEach(el => io.observe(el));
}

// ─────────────────────────────────────────────────────────
// Count-up for .speed-num
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
// Cursor-reactive glow on CTA buttons
// ─────────────────────────────────────────────────────────
function initCursorGlow() {
  const targets = document.querySelectorAll('.dl-cta, .btn-cta, .btn-price, .nav-cta');
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
// Fetch latest version from GitHub API
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
