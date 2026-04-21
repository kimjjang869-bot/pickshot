// ============================================================
// PickShot v8.8.1 — dynamic interactions
// ============================================================

document.addEventListener('DOMContentLoaded', () => {
  initNavScroll();
  initHeroViz();
  initRevealOnScroll();
  initCountUp();
  fetchLatestVersion();
});

// --- Nav: add .scrolled class after scrolling ---
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

// --- Hero loading visualization: simulates RAW folder loading ---
function initHeroViz() {
  const grid = document.getElementById('viz-grid');
  const bar = document.getElementById('viz-bar');
  const timer = document.getElementById('viz-timer');
  const counter = document.getElementById('viz-count');
  if (!grid) return;

  const TOTAL_CELLS = 96;   // 16×6 grid
  const TARGET_MS = 1500;   // 1.5s simulated load time

  // Build cells with warm varied hues
  for (let i = 0; i < TOTAL_CELLS; i++) {
    const cell = document.createElement('div');
    cell.className = 'viz-cell';
    const hue = 10 + Math.floor(Math.random() * 40); // warm (10-50)
    cell.style.setProperty('--h', hue);
    grid.appendChild(cell);
  }

  const cells = Array.from(grid.children);
  let loopTimeout = null;

  function runLoadCycle() {
    cells.forEach(c => c.classList.remove('loaded', 'ping'));
    bar.style.width = '0%';
    timer.textContent = '0.00초';
    counter.textContent = '2,134';

    const startTime = performance.now();
    let completed = 0;
    const perCell = TARGET_MS / TOTAL_CELLS;

    function loadNext() {
      if (completed >= TOTAL_CELLS) {
        const elapsed = (performance.now() - startTime) / 1000;
        timer.textContent = elapsed.toFixed(2) + '초';
        loopTimeout = setTimeout(runLoadCycle, 2500);
        return;
      }
      const cell = cells[completed];
      cell.classList.add('loaded', 'ping');
      completed++;

      const elapsed = (performance.now() - startTime) / 1000;
      const pct = (completed / TOTAL_CELLS) * 100;
      bar.style.width = pct + '%';
      timer.textContent = elapsed.toFixed(2) + '초';

      const jitter = 0.6 + Math.random() * 0.8;
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

// --- Reveal on scroll ---
function initRevealOnScroll() {
  const els = document.querySelectorAll('[data-reveal]');
  if (!('IntersectionObserver' in window)) {
    els.forEach(el => el.classList.add('in'));
    return;
  }
  const io = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        entry.target.classList.add('in');
        io.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
  els.forEach(el => io.observe(el));
}

// --- Count-up animation for .speed-num ---
function initCountUp() {
  const nums = document.querySelectorAll('.speed-num[data-count]');
  if (!nums.length) return;

  const animate = (el) => {
    const target = parseFloat(el.dataset.count);
    const suffix = el.dataset.suffix || '';
    const isInt = Number.isInteger(target);
    const duration = 1400;
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

// --- Fetch latest version from GitHub API (fallback: static v8.8.1) ---
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
    const heroBadge = document.getElementById('hero-version-badge');
    if (heroBadge) heroBadge.textContent = `${tag} · 사진가가 만든 사진가의 도구`;
  } catch (_) { /* silent fallback */ }
}
