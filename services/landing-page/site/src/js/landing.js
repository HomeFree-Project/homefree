/* HomeFree landing page — tile-light animation + copy button.
   Keep this small and dependency-free. No anime.js bundle. */

(() => {
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ── App-tile stagger: tiles light up on a slow loop, evoking SSO
  //    sign-ins propagating across the surface. Random subset each cycle
  //    so it doesn't feel mechanical. Pauses when tab is hidden.
  const tiles = Array.from(document.querySelectorAll('[data-animate-tiles] .app-tile'));
  if (tiles.length && !reduceMotion) {
    const litCount = Math.max(2, Math.min(4, Math.floor(tiles.length / 5)));

    const cycle = () => {
      if (document.hidden) return;
      // pick `litCount` unique tiles
      const picked = new Set();
      while (picked.size < litCount) {
        picked.add(Math.floor(Math.random() * tiles.length));
      }
      // stagger the lighting and unlight previous cycle's tiles
      tiles.forEach((t, i) => {
        if (picked.has(i)) {
          setTimeout(() => t.classList.add('lit'), (i % litCount) * 220);
        } else {
          t.classList.remove('lit');
        }
      });
    };

    cycle();
    setInterval(cycle, 2400);
  } else if (tiles.length && reduceMotion) {
    // For reduced motion, gently mark a couple permanently lit so
    // the "this is SSO-active" visual cue still reads.
    tiles.slice(0, 2).forEach(t => t.classList.add('lit'));
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
