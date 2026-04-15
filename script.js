// Smooth scroll + intersection animations
document.addEventListener('DOMContentLoaded', () => {
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
