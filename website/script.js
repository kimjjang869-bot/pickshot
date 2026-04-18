// GitHub latest release fetch — 다운로드 버튼 버전/링크 자동 갱신
async function fetchLatestRelease() {
  try {
    const res = await fetch('https://api.github.com/repos/kimjjang869-bot/pickshot/releases/latest', {
      headers: { 'Accept': 'application/vnd.github+json' }
    });
    if (!res.ok) return;
    const data = await res.json();
    const tag = data.tag_name || '';
    if (!tag) return;

    // Hero 배지
    const heroBadge = document.getElementById('hero-version-badge');
    if (heroBadge) heroBadge.textContent = `${tag} · macOS Native · Apple Silicon 최적화`;

    // 다운로드 버튼 버전
    const dlVer = document.getElementById('download-version');
    if (dlVer) dlVer.textContent = tag;

    // 다운로드 버튼 href — PickShot-latest.dmg 우선, 없으면 버전 붙은 첫 DMG
    const dlBtn = document.getElementById('download-btn');
    if (dlBtn && data.assets && data.assets.length) {
      const latest = data.assets.find(a => a.name === 'PickShot-latest.dmg');
      const versioned = data.assets.find(a => a.name && a.name.endsWith('.dmg'));
      const chosen = latest || versioned;
      if (chosen && chosen.browser_download_url) dlBtn.href = chosen.browser_download_url;
    }
  } catch (err) { /* 네트워크 실패해도 hardcoded 값 유지 */ }
}

// Smooth scroll + intersection animations
document.addEventListener('DOMContentLoaded', () => {
  fetchLatestRelease();

  // Fade-in on scroll
  const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        entry.target.classList.add('in-view');
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.1, rootMargin: '0px 0px -60px 0px' });

  document.querySelectorAll('.feature, .stat, .price-card, .faq-item, .split-text, .split-image, .section-head')
    .forEach(el => observer.observe(el));

  // Nav active state on scroll
  const nav = document.querySelector('.nav');
  let lastScroll = 0;
  window.addEventListener('scroll', () => {
    const y = window.scrollY;
    if (y > 20) nav.classList.add('scrolled');
    else nav.classList.remove('scrolled');
    lastScroll = y;
  });
});
