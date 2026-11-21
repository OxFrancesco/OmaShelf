for (const button of document.querySelectorAll('[data-copy]')) {
  button.addEventListener('click', async () => {
    const text = document.getElementById(button.dataset.copy).textContent;
    await navigator.clipboard.writeText(text).then(() => { button.textContent = 'Copied'; }, () => { button.textContent = 'Select and copy'; });
    setTimeout(() => { button.textContent = 'Copy'; }, 1600);
  });
}

// Demo: a mock Omarchy bar with the shelf. Pointer events rather than HTML
// drag and drop, so it works the same with a finger.
const thumbs = {
  photo: '<svg viewBox="0 0 64 64"><circle cx="44" cy="20" r="7" fill="#fff" opacity=".9"/><path d="M0 64 22 34l12 14 8-8 22 24z" fill="#000" opacity=".55"/></svg>',
  video: '<svg viewBox="0 0 64 64"><rect x="6" y="14" width="52" height="30" fill="none" stroke="#3a3a3a"/><path d="M27 21v16l13-8z" fill="#fff"/><rect x="6" y="50" width="34" height="3" fill="oklch(61.52% .1657 26.98)"/><rect x="40" y="50" width="18" height="3" fill="#333"/></svg>',
  text: '<svg viewBox="0 0 64 64" stroke="#8a8a8a" stroke-width="3"><path d="M12 16h40M12 25h40M12 34h28M12 43h36"/></svg>',
  pdf: '<svg viewBox="0 0 64 64"><path d="M18 8h20l10 10v38H18z" fill="none" stroke="#bbb" stroke-width="2.5"/><text x="33" y="44" text-anchor="middle" font-family="Chakra Petch, sans-serif" font-weight="700" font-size="12" fill="oklch(61.52% .1657 26.98)">PDF</text></svg>',
};

const files = [
  { id: 'a', name: 'sunset.jpg', kind: 'photo', on: 'desk' },
  { id: 'b', name: 'demo.mp4', kind: 'video', on: 'desk' },
  { id: 'c', name: 'notes.txt', kind: 'text', on: 'desk' },
  { id: 'd', name: 'invoice.pdf', kind: 'pdf', on: 'desk' },
];

const desk = document.getElementById('desk');
const deskFiles = document.getElementById('desk-files');
const popup = document.getElementById('popup');
const grid = document.getElementById('shelf-grid');
const empty = document.getElementById('shelf-empty');
const icon = document.getElementById('shelf-icon');
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

function thumb(file) {
  return `<i class="thumb k-${file.kind}">${thumbs[file.kind]}</i>`;
}

function render() {
  deskFiles.innerHTML = '';
  grid.innerHTML = '';
  for (const file of files) {
    const el = document.createElement('div');
    el.dataset.id = file.id;
    el.innerHTML = `${thumb(file)}<span>${file.name}</span>`;
    if (file.on === 'desk') {
      el.className = 'file';
      el.tabIndex = 0;
      el.setAttribute('role', 'button');
      el.setAttribute('aria-label', `Put ${file.name} on the shelf`);
      deskFiles.append(el);
    } else {
      el.className = 'tile';
      grid.append(el);
    }
  }
  const count = files.filter(f => f.on === 'shelf').length;
  empty.hidden = count > 0;
  icon.classList.toggle('has', count > 0);
}

function setOpen(open) {
  popup.hidden = !open;
  icon.setAttribute('aria-expanded', String(open));
}

function move(id, to) {
  const file = files.find(f => f.id === id);
  file.on = to;
  // Newest first, like the real shelf.
  files.splice(files.indexOf(file), 1);
  if (to === 'shelf') files.unshift(file); else files.push(file);
  render();
}

icon.addEventListener('click', () => setOpen(popup.hidden));
desk.addEventListener('pointerdown', e => {
  if (!popup.hidden && !popup.contains(e.target) && !icon.contains(e.target) && !e.target.closest('.file')) setOpen(false);
});
deskFiles.addEventListener('keydown', e => {
  const el = e.target.closest('.file');
  if (el && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); move(el.dataset.id, 'shelf'); setOpen(true); }
});

const inside = (el, x, y, pad = 0) => {
  const r = el.getBoundingClientRect();
  return x >= r.left - pad && x <= r.right + pad && y >= r.top - pad && y <= r.bottom + pad;
};

let drag = null;
let holdTimer = 0;

desk.addEventListener('pointerdown', e => {
  const el = e.target.closest('.file, .tile');
  if (!el || e.button > 0) return;
  el.setPointerCapture(e.pointerId);
  drag = { el, id: el.dataset.id, from: el.classList.contains('tile') ? 'shelf' : 'desk', x: e.clientX, y: e.clientY, ghost: null };
});

desk.addEventListener('pointermove', e => {
  if (!drag) return;
  if (!drag.ghost) {
    if (Math.hypot(e.clientX - drag.x, e.clientY - drag.y) < 6) return;
    const box = drag.el.querySelector('.thumb').getBoundingClientRect();
    drag.ghost = drag.el.querySelector('.thumb').cloneNode(true);
    drag.ghost.classList.add('ghost');
    drag.ghost.style.width = `${box.width}px`;
    drag.origin = { x: box.left, y: box.top, w: box.width };
    drag.offset = { x: e.clientX - box.left, y: e.clientY - box.top };
    document.body.append(drag.ghost);
    drag.el.classList.add('away');
  }
  drag.ghost.style.transform = `translate(${e.clientX - drag.offset.x}px, ${e.clientY - drag.offset.y}px) scale(1.06)`;

  const overIcon = inside(icon, e.clientX, e.clientY, 10);
  const overPopup = !popup.hidden && inside(popup, e.clientX, e.clientY);
  if (drag.from === 'desk') {
    icon.classList.toggle('hot', overIcon);
    popup.classList.toggle('hot', overPopup);
    if (overIcon && popup.hidden && !holdTimer) holdTimer = setTimeout(() => { setOpen(true); holdTimer = 0; }, 280);
    if (!overIcon && holdTimer) { clearTimeout(holdTimer); holdTimer = 0; }
  }
  drag.target = drag.from === 'desk' ? (overPopup || overIcon ? 'shelf' : null) : (!overPopup && inside(desk, e.clientX, e.clientY) ? 'desk' : null);
});

function endDrag() {
  if (!drag) return;
  const { ghost, target, from, id, el, origin } = drag;
  clearTimeout(holdTimer); holdTimer = 0;
  icon.classList.remove('hot');
  popup.classList.remove('hot');
  drag = null;
  if (!ghost) return;
  if (target && target !== from) {
    ghost.remove();
    move(id, target);
    if (target === 'shelf') setOpen(true);
    return;
  }
  // Missed: settle back where it came from instead of vanishing.
  if (reduced) { ghost.remove(); el.classList.remove('away'); return; }
  ghost.classList.add('settle');
  ghost.style.transform = `translate(${origin.x}px, ${origin.y}px) scale(1)`;
  ghost.addEventListener('transitionend', () => { ghost.remove(); el.classList.remove('away'); }, { once: true });
}

desk.addEventListener('pointerup', endDrag);
desk.addEventListener('pointercancel', endDrag);

const clock = document.getElementById('clock');
const tick = () => { clock.textContent = new Date().toLocaleString('en-US', { weekday: 'long', hour: '2-digit', minute: '2-digit', hour12: false }).replace(',', ''); };
tick();
setInterval(tick, 30000);
render();
