// Procedural 24x24 pixel pets (+ a 12x12 hoot head for the cursor) for "wait, what?" — owl (hoot), axolotl (lotl), robot (bit).
// Copied from the Claude Design project "wait what Crisp". export-sprites.mjs turns it into
// the app's PetSprites JSON.
(function () {
  const N = 24;
  const PAL = {
    owl: { o: '#3B2A1E', b: '#B47B47', B: '#8E5A31', l: '#F0D3A3', d: '#D3A86C', h: '#D49A62', g: '#2E2720', w: '#FFFDF7', f: '#F0D3A3', e: '#2E2720', k: '#E8963A', m: '#7A3B1A', S: 'rgba(60,40,20,0.16)', a: '#C7782E' },
    lotl: { o: '#7A3346', p: '#F6A9BA', q: '#FCD6DE', r: '#E25A78', n: '#2B2B30', y: '#F2C14E', e: '#2B1B22', w: '#FFFFFF', c: '#F07F98', m: '#8A2E45', h: '#FFD0DA', S: 'rgba(0,0,0,0.12)', a: '#1FA6B8' },
    bit: { o: '#16211B', c: '#93AE9F', h: '#C9DBD0', g: '#5E7769', s: '#07120B', f: '#5CF08F', y: '#F2B84B', Y: '#6E5628', S: 'rgba(0,0,0,0.35)', a: '#57F08A' }
  };
  const G = () => Array.from({ length: N }, () => Array(N).fill(null));
  const set = (g, x, y, c) => { if (x >= 0 && y >= 0 && x < N && y < N) g[y][x] = c; };
  const ell = (g, cx, cy, rx, ry, c) => { for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) { const dx = (x + .5 - cx) / rx, dy = (y + .5 - cy) / ry; if (dx * dx + dy * dy <= 1) g[y][x] = c; } };
  const rect = (g, x, y, w, h, c) => { for (let j = y; j < y + h; j++) for (let i = x; i < x + w; i++) set(g, i, j, c); };
  const px = (g, l, c) => l.forEach(([x, y]) => set(g, x, y, c));
  const pxm = (g, l, c) => l.forEach(([x, y]) => { set(g, x, y, c); set(g, N - 1 - x, y, c); });
  const soft = (g, l, c) => l.forEach(([x, y]) => { if (x >= 0 && y >= 0 && x < N && y < N && !g[y][x]) g[y][x] = c; });
  function outline(g, c) {
    const o = g.map(r => r.slice());
    for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
      if (g[y][x]) continue;
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) { const v = g[y + dy] && g[y + dy][x + dx]; if (v) { o[y][x] = c; break; } }
    }
    return o;
  }
  function shift(g, dy) { const o = G(); for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) { const v = g[y][x]; if (v && y + dy >= 0 && y + dy < N) o[y + dy][x] = v; } return o; }
  function extras(g, o, spec) {
    if (o.waves && !spec.noWaves) {
      soft(g, [[21, 8], [22, 9], [22, 10], [22, 11], [22, 12], [21, 13]], 'a');
      if (o.waves > 1) soft(g, [[23, 9], [23, 10], [23, 11], [23, 12]], 'a');
    }
    if (o.dots) for (let i = 0; i < o.dots; i++) { soft(g, [[15 + i * 3, 1], [16 + i * 3, 1], [15 + i * 3, 2], [16 + i * 3, 2]], 'a'); }
    if (o.spark && spec.spark) soft(g, spec.spark, 'a');
  }
  const DRAW = {
    owl(o) {
      const g = G(); const t = o.alert ? 1 : 0; const [dx, dy] = o.look || [0, 0];
      pxm(g, [[5, 3 - t], [5, 4 - t], [6, 4 - t], [6, 5 - t], [7, 5 - t]], 'b');
      ell(g, 12, 13.5, 8.5, 8.5, 'b');
      ell(g, 12, 16.5, 5.5, 5, 'l');
      pxm(g, [[9, 17], [10, 18], [10, 20], [11, 21]], 'd');
      px(g, [[7, 6], [8, 6], [6, 7]], 'h');
      ell(g, 4.6, 15.5, 1.8, 4.2, 'B');
      if (o.arm === 'point') ell(g, 20, 13, 3, 1.5, 'B');
      else if (o.arm === 'wave1') ell(g, 20, 9.5, 1.6, 3.5, 'B');
      else if (o.arm === 'wave2') ell(g, 21, 10.5, 1.6, 3.5, 'B');
      else ell(g, 19.4, 15.5, 1.8, 4.2, 'B');
      ell(g, 8.5, 11, 3.3, 3.3, 'g'); ell(g, 15.5, 11, 3.3, 3.3, 'g');
      const shut = o.eyes === 'closed' || o.eyes === 'happy';
      ell(g, 8.5, 11, 2.4, 2.4, shut ? 'f' : 'w'); ell(g, 15.5, 11, 2.4, 2.4, shut ? 'f' : 'w');
      if (o.eyes === 'closed') { rect(g, 6, 11, 5, 1, 'e'); rect(g, 13, 11, 5, 1, 'e'); }
      else if (o.eyes === 'happy') { px(g, [[6, 12], [7, 11], [8, 10], [9, 11], [10, 12]], 'e'); px(g, [[13, 12], [14, 11], [15, 10], [16, 11], [17, 12]], 'e'); }
      else {
        rect(g, 8 + dx, 10 + dy, 2, 2, 'e'); rect(g, 15 + dx, 10 + dy, 2, 2, 'e');
        if (o.eyes === 'wide') { set(g, 8 + dx, 10 + dy, 'w'); set(g, 15 + dx, 10 + dy, 'w'); }
      }
      px(g, [[11, 13], [12, 13], [11, 14], [12, 14]], 'k');
      if (o.mouth === 'open') { px(g, [[11, 14], [12, 14]], 'm'); px(g, [[11, 15], [12, 15]], 'k'); }
      pxm(g, [[8, 22], [9, 22], [10, 22]], 'k');
      const r = outline(g, 'o'); extras(r, o, { spark: [[23, 11], [23, 14]] }); return r;
    },
    lotl(o) {
      const g = G(); const fl = o.flare ? 1 : 0; const [dx, dy] = o.look || [0, 0];
      const fr = [[4, 10], [3, 9], [2, 8], [3, 12], [2, 12], [1, 12], [2, 15], [1, 16]];
      if (fl || o.alert) fr.push([1, 7], [0, 12], [0, 17]);
      if (fl) fr.push([0, 6], [1, 6]);
      pxm(g, fr, 'r');
      ell(g, 12, 14.5, 8.5, 6.5, 'p');
      ell(g, 12, 18, 5.5, 2.8, 'q');
      px(g, [[8, 9], [9, 9], [7, 10]], 'h');
      rect(g, 9, 6, 6, 2, 'n'); rect(g, 6, 5, 12, 1, 'n'); px(g, [[17, 6], [17, 7], [17, 8]], 'y');
      if (o.eyes === 'closed') { rect(g, 7, 13, 2, 1, 'e'); rect(g, 15, 13, 2, 1, 'e'); }
      else if (o.eyes === 'happy') { px(g, [[6, 13], [7, 12], [8, 12], [9, 13]], 'e'); px(g, [[14, 13], [15, 12], [16, 12], [17, 13]], 'e'); }
      else { rect(g, 7 + dx, 12 + dy, 2, 2, 'e'); rect(g, 15 + dx, 12 + dy, 2, 2, 'e'); set(g, 7 + dx, 12 + dy, 'w'); set(g, 15 + dx, 12 + dy, 'w'); }
      pxm(g, [[5, 15], [6, 15]], 'c');
      if (o.mouth === 'open') { rect(g, 10, 15, 4, 2, 'm'); px(g, [[11, 16], [12, 16]], 'c'); }
      else px(g, [[10, 15], [11, 16], [12, 16], [13, 15]], 'm');
      px(g, [[4, 18], [5, 18]], 'p');
      if (o.arm === 'point') px(g, [[20, 16], [21, 15], [22, 15]], 'p');
      else if (o.arm === 'wave1') px(g, [[20, 16], [21, 15], [21, 14], [21, 13]], 'p');
      else if (o.arm === 'wave2') px(g, [[20, 16], [21, 15], [22, 14], [22, 13]], 'p');
      else px(g, [[18, 18], [19, 18]], 'p');
      pxm(g, [[8, 21], [9, 21]], 'p');
      const r = outline(g, 'o'); extras(r, o, { noWaves: true, spark: [[23, 13], [23, 17]] }); return r;
    },
    bit(o) {
      const g = G(); const [dx, dy] = o.look || [0, 0];
      rect(g, 11, 3, 2, 2, 'g'); rect(g, 11, 1, 2, 2, o.lit ? 'y' : 'Y');
      rect(g, 4, 5, 16, 12, 'c'); [[4, 5], [19, 5], [4, 16], [19, 16]].forEach(([x, y]) => { g[y][x] = null; });
      px(g, [[5, 6], [6, 6], [5, 7]], 'h');
      rect(g, 6, 7, 12, 8, 's'); [[6, 7], [17, 7], [6, 14], [17, 14]].forEach(([x, y]) => { g[y][x] = 'c'; });
      if (o.eyes === 'closed') { rect(g, 8, 10, 2, 1, 'f'); rect(g, 14, 10, 2, 1, 'f'); }
      else if (o.eyes === 'happy') { px(g, [[7, 10], [8, 9], [9, 9], [10, 10]], 'f'); px(g, [[13, 10], [14, 9], [15, 9], [16, 10]], 'f'); }
      else { rect(g, 8 + dx, 9 + dy, 2, 2, 'f'); rect(g, 14 + dx, 9 + dy, 2, 2, 'f'); }
      if (o.waves) {
        const hs = o.waves > 1 ? [2, 3, 1, 2, 3, 1, 1, 2] : [1, 2, 3, 1, 2, 3, 2, 1];
        hs.forEach((h, i) => rect(g, 8 + i, 12 - Math.floor((h - 1) / 2), 1, h, 'f'));
      } else if (o.think) rect(g, 11, 12, 2, 1, 'f');
      else if (o.mouth === 'open') { rect(g, 10, 12, 4, 2, 'f'); px(g, [[11, 12], [12, 12]], 's'); }
      else rect(g, 10, 12, 4, 1, 'f');
      rect(g, 10, 17, 4, 1, 'g'); rect(g, 7, 18, 10, 3, 'c'); rect(g, 11, 19, 2, 1, 'y');
      rect(g, 7, 21, 3, 1, 'g'); rect(g, 14, 21, 3, 1, 'g');
      rect(g, 5, 18, 2, 1, 'g'); set(g, 5, 19, 'g');
      if (o.arm === 'point') { rect(g, 17, 18, 4, 1, 'g'); rect(g, 21, 17, 2, 2, 'c'); }
      else if (o.arm === 'wave1') { px(g, [[17, 18], [18, 17], [19, 16], [20, 15], [20, 14]], 'g'); rect(g, 20, 12, 2, 2, 'c'); }
      else if (o.arm === 'wave2') { px(g, [[17, 18], [18, 18], [19, 17], [20, 16], [21, 15]], 'g'); rect(g, 22, 13, 2, 2, 'c'); }
      else { rect(g, 17, 18, 2, 1, 'g'); set(g, 18, 19, 'g'); }
      const r = outline(g, 'o'); extras(r, o, { spark: [[23, 16], [23, 19]] }); return r;
    }
  };
  const STATES = {
    idle: [[{}, 520], [{ bob: 1 }, 520], [{}, 520], [{ bob: 1 }, 520], [{ eyes: 'closed' }, 130]],
    listening: [[{ alert: 1, eyes: 'wide', waves: 1, lit: 1 }, 240], [{ alert: 1, eyes: 'wide', waves: 2, flare: 1, lit: 1 }, 240]],
    thinking: [[{ look: [1, -1], dots: 1, lit: 1, think: 1 }, 320], [{ look: [1, -1], dots: 2, think: 1 }, 320], [{ look: [1, -1], dots: 3, lit: 1, think: 1 }, 320], [{ look: [1, -1], dots: 3, think: 1 }, 320]],
    talking: [[{ mouth: 'open' }, 150], [{}, 170], [{ mouth: 'open', bob: 1 }, 150], [{}, 200]],
    pointing: [[{ arm: 'point', look: [1, 0], spark: 1 }, 320], [{ arm: 'point', look: [1, 0] }, 320]],
    presenting: [[{ look: [0, 1] }, 900], [{ look: [0, 1], bob: 1 }, 900], [{ eyes: 'closed', look: [0, 1] }, 130]],
    hello: [[{ arm: 'wave1', eyes: 'happy' }, 300], [{ arm: 'wave2', eyes: 'happy' }, 300]]
  };
  // 12x12 head-only hoot for the cursor companion
  const HEAD = [
    '............',
    '.oo......oo.',
    '.obo....obo.',
    '.obboooobbo.',
    'obbbbbbbbbbo',
    'oggggbbggggo',
    'ogwwggggwwgo',
    'ogwegbbgewgo',
    'oggggkkggggo',
    'obbbbkkbbbbo',
    '.obbllllbbo.',
    '..oooooooo..'
  ];
  function head(o) {
    let r = HEAD.map(s => s.split(''));
    const put = (x, y, c) => { r[y][x] = c; };
    if (o.alert) { r[0] = '.o........o.'.split(''); r[1] = '.bo......ob.'.split(''); r[2] = '.bbo....obb.'.split(''); }
    if (o.eyes === 'closed') { [2, 3, 8, 9].forEach(x => { put(x, 6, 'f'); put(x, 7, 'e'); }); }
    else if (o.look) { [2, 3, 8, 9].forEach(x => { put(x, 6, 'w'); put(x, 7, 'w'); }); const [dx, dy] = o.look; put(dx > 0 ? 3 : 2, dy < 0 ? 6 : 7, 'e'); put(dx > 0 ? 9 : 8, dy < 0 ? 6 : 7, 'e'); }
    if (o.mouth === 'open') { put(5, 9, 'm'); put(6, 9, 'm'); }
    r = r.map(row => row.map(c => (c === '.' ? null : c)));
    if (o.bob) { r.shift(); r.push(Array(12).fill(null)); }
    return r;
  }
  const HEAD_STATES = {
    idle: [[{}, 600], [{ bob: 1 }, 600], [{}, 600], [{ eyes: 'closed' }, 130]],
    listening: [[{ alert: 1 }, 260], [{ alert: 1, bob: 1 }, 260]],
    thinking: [[{ look: [-1, -1] }, 360], [{ look: [1, -1] }, 360]],
    talking: [[{ mouth: 'open' }, 150], [{}, 170], [{ mouth: 'open', bob: 1 }, 150], [{}, 200]]
  };
  function build(pet, o) {
    let g = DRAW[pet](o);
    g = shift(g, o.bob ? 0 : -1);
    for (let x = 6; x <= 17; x++) soft(g, [[x, 23]], 'S');
    return g;
  }
  function frames(pet, state) {
    if (pet === 'owlhead') return (HEAD_STATES[state] || HEAD_STATES.idle).map(([o, ms]) => ({ grid: head(o), ms }));
    return (STATES[state] || STATES.idle).map(([o, ms]) => ({ grid: build(pet, o), ms }));
  }
  PAL.owlhead = PAL.owl;
  const api = { N, PAL, STATES, HEAD_STATES, frames };
  if (typeof module !== 'undefined') module.exports = api;
  if (typeof window !== 'undefined') window.WWPets = api;
})();
