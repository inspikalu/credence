// Credence landing page: nav state and reveal-on-scroll. No dependencies.
(function () {
  'use strict';

  var nav = document.getElementById('nav');
  function onScroll() {
    if (!nav) return;
    nav.classList.toggle('scrolled', window.scrollY > 8);
  }
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  // Reveal each element once as it enters the viewport. Elements in the same
  // grid get a short stagger (50 ms) so a row reads as one gesture.
  var targets = Array.prototype.slice.call(document.querySelectorAll('.reveal'));
  var visual = document.querySelector('.hero__visual');
  if (visual) targets.push(visual);

  function show(el) {
    var siblings = el.parentElement ? el.parentElement.children : [];
    var index = Array.prototype.indexOf.call(siblings, el);
    if (index > 0 && index < 8 && el.classList.contains('reveal')) {
      el.style.transitionDelay = index * 50 + 'ms';
    }
    el.classList.add('in');
  }

  if (!('IntersectionObserver' in window)) {
    targets.forEach(show);
    return;
  }
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        show(entry.target);
        io.unobserve(entry.target);
      }
    });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.05 });
  targets.forEach(function (el) { io.observe(el); });

  // Clear stagger delays after the first reveal so later state changes
  // (none today) are never delayed.
  document.addEventListener('transitionend', function (e) {
    if (e.target.classList && e.target.classList.contains('in')) {
      e.target.style.transitionDelay = '';
    }
  });
})();
