/* HomeFree landing page — product-tour carousel + copy button.
   Keep this small and dependency-free. */

(() => {
  // ── Product tour carousel: prev/next + dots + keyboard nav.
  //    Single slide at a time, .is-active class drives visibility.
  //    The CSS hides nav buttons until data-carousel-ready is set,
  //    so if JS fails to load the first slide still renders alone.
  const carousel = document.querySelector('[data-carousel]');
  if (carousel) {
    const slides = Array.from(carousel.querySelectorAll('[data-carousel-slides] .tour-slide'));
    const dots   = Array.from(carousel.querySelectorAll('[data-carousel-dots] .tour-dot'));
    const prev   = carousel.querySelector('[data-carousel-prev]');
    const next   = carousel.querySelector('[data-carousel-next]');

    if (slides.length > 1) {
      let active = 0;

      const setActive = (i) => {
        active = (i + slides.length) % slides.length;
        slides.forEach((s, k) => s.classList.toggle('is-active', k === active));
        dots.forEach((d, k) => {
          const on = k === active;
          d.classList.toggle('is-active', on);
          d.setAttribute('aria-selected', on ? 'true' : 'false');
        });
      };

      prev?.addEventListener('click', () => setActive(active - 1));
      next?.addEventListener('click', () => setActive(active + 1));
      dots.forEach((d, k) => d.addEventListener('click', () => setActive(k)));

      carousel.addEventListener('keydown', (e) => {
        if (e.key === 'ArrowLeft')  { e.preventDefault(); setActive(active - 1); }
        if (e.key === 'ArrowRight') { e.preventDefault(); setActive(active + 1); }
      });

      // Reveal the controls now that JS is wired up.
      carousel.setAttribute('data-carousel-ready', '');
    }
  }

  // ── Copy install command
  const cmd = document.getElementById('install-cmd');
  if (cmd) {
    const btn = cmd.querySelector('button');
    const txt = document.getElementById('install-cmd-text');
    btn?.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(txt.textContent.trim());
        btn.textContent = 'Copied';
        btn.classList.add('copied');
        setTimeout(() => {
          btn.textContent = 'Copy';
          btn.classList.remove('copied');
        }, 1600);
      } catch {
        btn.textContent = 'Press Ctrl-C';
      }
    });
  }
})();
