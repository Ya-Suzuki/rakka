/*
 * 落花: 桜の花びらが舞いながら散り、ページの底（フッターの下）に積もる。
 * 途中を読んでいる間は画面の下を通り抜けて見えなくなり、最後までスクロールすると山が見える。
 * 着地すると水面のような波紋が広がり、積もった花びらはしばらくすると消える
 * （散って、積もって、消えるまでが一枚の一生）。
 *
 * フッターの一言を押すと、イベントを最初から再生して山を作り直す:
 *   1. 巻き戻し: 全部の花びらが、新しいものから順に舞い上がる（状態を捨てる）
 *   2. 早送りで再生: 最初の一枚から、全員の時間を同じ倍率で速めて再生する。順番も間隔も
 *      元のままなので一斉には降らず、山は散った順に積み上がる。速さは等速から上限
 *      （MAX_SPEED 倍。一枚が落ちる様子が見える速さ）までなめらかに上げ、また等速まで下げる
 *   3. 今に追いつく: 最後の CATCH_UP 秒ぶんは等速で、直近の花びらは元どおりに舞って着地する
 *
 * 花びらの動きは「生まれた時刻と乱数から決まる値（イベント）」と「経過時間」だけで
 * 決まる純粋な関数（place）なので、巻き戻しも再生も、時間を動かすだけでできる。
 * 積もる位置も、散った順番だけで決まる。Rakka がイベントから状態を作り直すのと同じ。
 */
(function () {
'use strict';

const BINS = 72;          // 積もる位置の区切り（画面幅によらず一定。幅を変えても同じ山になる）
const LAYER = 3.4;        // 1枚積もるごとに山が高くなる量（px）
const HEAP_MAX = 40;      // 山の高さの上限（px）
const PILE_MAX = 24;      // 一度に積もっている枚数の上限。超えたら画面の外へ落ちて消える
const STAY = 150;         // 積もってから消え始めるまでの秒数（散って、積もって、消えるまでが一枚の一生）
const FADE = 6;           // 消えるのにかける秒数
const RIPPLE = 2.8;       // 着地の波紋が広がって消えるまでの秒数
const RINGS = [0, 0.35, 0.7]; // 波紋の輪ごとの遅れ（秒）
const REWIND = 2.4;       // 巻き戻しにかける秒数（全体）
const LIFT = 1.2;         // 一枚が舞い上がるのにかける秒数。最後に散ったものから順に、ずらして上がる
const MAX_SPEED = 50;     // 早送りの上限（倍）。これより速いと、落ちる途中が見えず下端に突然現れて見える
const RAMP = 1.2;         // 等速と上限の間を加速・減速するのにかける秒数
const CATCH_UP = 10;      // 最後に等速で再生する長さ（元の時間で秒）
const SIZE = 0.62;        // 花びらの大きさ（40 × 52 の下絵に掛ける倍率）

const SPRITES = 8;        // 花びらの描き分けの数（ひとつずつ、にじみ方が違う）
const SPRITE_RES = 4;     // 下絵の解像度（1 単位あたりの px）
const PAD = 4;            // 下絵の余白（にじみが外へ広がる分）

// 桜の花びらの輪郭（40 × 52、根元が下、上端に浅い切れ込み）。三次ベジェの列
const OUTLINE = [
  [20, 51], [9, 44, 1, 30, 2, 17], [3, 7, 10, 2, 16, 4], [18, 5, 19, 7, 20, 10],
  [21, 7, 22, 5, 24, 4], [30, 2, 37, 7, 38, 17], [39, 30, 31, 44, 20, 51]
];
const INK = 'rgba(43, 39, 36, 1)'; // 墨（波紋の線）

// --- 花びらの下絵: 没骨（輪郭線を引かない）の淡い紅。縁に顔料が溜まり、紙の上で粒立つ ---
function makeSprites() {
  const list = [];
  for (let i = 0; i < SPRITES; i++) list.push(makeSprite(i));
  return list;
}

function makeSprite(index) {
  let seed = 7919 * (index + 1);
  const rand = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  const R = SPRITE_RES;
  const w = (40 + PAD * 2) * R, h = (52 + PAD * 2) * R;
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  const g = c.getContext('2d');

  // 輪郭をなぞって点にし、少しだけ揺らす（筆の当たりの不揃い）
  const pts = [];
  let [px, py] = OUTLINE[0];
  for (let s = 1; s < OUTLINE.length; s++) {
    const [x1, y1, x2, y2, x3, y3] = OUTLINE[s];
    for (let n = 1; n <= 14; n++) {
      const t = n / 14, u = 1 - t;
      pts.push([u * u * u * px + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3,
                u * u * u * py + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3]);
    }
    px = x3; py = y3;
  }
  const waves = [rand() * 6.28, rand() * 6.28, rand() * 6.28];
  const outline = new Path2D();
  pts.forEach(([x, y], n) => {
    const a = Math.atan2(y - 24, x - 20);
    const d = 0.55 * Math.sin(a * 3 + waves[0]) + 0.35 * Math.sin(a * 7 + waves[1]) + 0.25 * Math.sin(a * 13 + waves[2]);
    const X = x + Math.cos(a) * d, Y = y + Math.sin(a) * d;
    if (n === 0) outline.moveTo(X, Y); else outline.lineTo(X, Y);
  });
  outline.closePath();

  const hue = (rand() - 0.5) * 10;  // 紅の色味を少しずつ変える
  const tone = (r, gg, b, a) => `rgba(${Math.round(r + hue)}, ${gg}, ${Math.round(b - hue)}, ${a})`;
  g.scale(R, R);
  g.translate(PAD, PAD);

  // 1. 淡い地: 先は白く抜け、根元へ向かって紅が濃くなる
  const wash = g.createLinearGradient(20, 2, 20, 51);
  wash.addColorStop(0, tone(244, 229, 224, 0.72));
  wash.addColorStop(0.45, tone(226, 178, 180, 0.82));
  wash.addColorStop(1, tone(184, 92, 108, 0.92));
  g.fillStyle = wash;
  g.fill(outline);

  g.save();
  g.clip(outline);
  // 2. 根元の濃い紅（萼に近いところ）
  const base = g.createRadialGradient(20, 52, 0, 20, 52, 20);
  base.addColorStop(0, tone(140, 42, 62, 0.55));
  base.addColorStop(1, tone(168, 52, 78, 0));
  g.fillStyle = base;
  g.fillRect(0, 0, 40, 52);
  // 3. 縁に溜まる顔料（にじみの輪）
  g.filter = `blur(${1.1 * R}px)`;
  g.strokeStyle = tone(166, 70, 88, 0.6);
  g.lineWidth = 2.4;
  g.stroke(outline);
  g.filter = 'none';
  // 4. 筋: 根元から先へ、ごく淡く
  g.strokeStyle = tone(120, 50, 62, 0.2);
  g.lineWidth = 0.35;
  for (let n = -2; n <= 2; n++) {
    g.beginPath();
    g.moveTo(20, 50);
    g.quadraticCurveTo(20 + n * 3, 32, 20 + n * 6.5 + (rand() - 0.5) * 2, 12 + Math.abs(n) * 2);
    g.stroke();
  }
  g.restore();

  // 5. 紙の上の粒立ち: 濃さを細かくむらにする
  g.setTransform(1, 0, 0, 1, 0, 0);
  const img = g.getImageData(0, 0, w, h);
  const cell = 3, cols = Math.ceil(w / cell) + 1;
  const grain = new Float32Array(cols * (Math.ceil(h / cell) + 1)).map(() => rand());
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      if (!img.data[i + 3]) continue;
      const gx = x / cell, gy = y / cell, x0 = gx | 0, y0 = gy | 0, fx = gx - x0, fy = gy - y0;
      const v = (grain[y0 * cols + x0] * (1 - fx) + grain[y0 * cols + x0 + 1] * fx) * (1 - fy) +
                (grain[(y0 + 1) * cols + x0] * (1 - fx) + grain[(y0 + 1) * cols + x0 + 1] * fx) * fy;
      img.data[i + 3] = Math.min(255, img.data[i + 3] * (0.72 + 0.4 * v + 0.12 * (rand() - 0.5)));
    }
  }
  g.putImageData(img, 0, 0);

  // 6. 紙ににじむ: 全体の縁をわずかにぼかす
  const out = document.createElement('canvas');
  out.width = w; out.height = h;
  const o = out.getContext('2d');
  o.filter = `blur(${0.35 * R}px)`;
  o.drawImage(c, 0, 0);
  return out;
}

function start() {
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  canvas.className = 'petal-canvas';
  canvas.setAttribute('aria-hidden', 'true');

  const sprites = makeSprites();

  // --- イベントの列 ---
  let seed = 20261117;
  const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;

  let W = 0, H = 0, docH = 0, scrollY = 0;
  let clock = 0;
  let petals = [];
  let nextSpawn = 0;
  let mode = 'live';       // live / rewind / replay
  let modeStart = 0;
  let replayFrom = 0;      // 再生の基準（最初の花びらが散った時刻）
  let replayLength = 0;    // 再生する元の時間の長さ（最初の花びらから、最後の花びらが積もるまで）

  const countPiled = () => petals.reduce((n, p) => n + (p.piled && clock - p.born < life(p) ? 1 : 0), 0);

  function spawn(born) {
    // 風は右へ吹いている。落ちる先は右下に寄り、吹き溜まりになる
    const end = Math.min(0.995, 1 - 0.97 * Math.pow(random(), 1.7));
    const x = Math.max(0.005, end - (0.04 + random() * 0.18));
    const bin = Math.floor(end * BINS);
    const scale = 0.6 + random() * 0.45;
    const shade = random();
    const p = {
      born, x, drift: end - x,
      dur: 11 + random() * 8,
      swayA: 18 + random() * 40, swayF: 0.5 + random() * 0.6, phase: random() * Math.PI * 2,
      wobbleA: 6 + random() * 14, wobbleF: 1.3 + random() * 1.4, phase2: random() * Math.PI * 2,
      gust: 0.5 + random() * 0.8, gusts: 2 + Math.floor(random() * 3),
      spin: (random() - 0.5) * 140,
      flipF: 1.4 + random() * 2.6, tumbleF: 0.8 + random() * 1.6,
      scale,
      // 積もったときは、表か裏をこちらに向けて重なる（真横を向いて線にならないように）
      restRot: random() * Math.PI * 2,
      restYaw: (random() - 0.5) * 1.6 + (random() < 0.4 ? Math.PI : 0),
      restPitch: (random() - 0.5) * 1.1,
      alpha: 0.82 + shade * 0.14, // 花びらごとのわずかな濃淡
      sprite: Math.floor(shade * SPRITES) % SPRITES,
      jitter: (random() - 0.5) * 6,
      piled: false, lift: 0
    };
    p.bin = bin;
    settle(p, petals);
    petals.push(p);
  }

  // 一生の長さ（経過時間）。積もらない花びらは落ちきったら、積もったものは消えきったら終わる
  const life = (p) => p.dur + (p.piled ? STAY + FADE : 0);

  // 積もるかどうかと高さは、それより前に散って、着地の時点でまだ残っている花びらだけで決まる
  function settle(p, prior) {
    const lands = p.born + p.dur;
    let count = 0, height = 0;
    for (const q of prior) {
      if (!q.piled || q.born + life(q) <= lands) continue;
      count++;
      if (q.bin === p.bin) height += LAYER * q.scale;
    }
    p.piled = count < PILE_MAX;
    p.lift = p.piled ? Math.min(height, HEAP_MAX) + p.jitter : 0;
  }

  const ease = (q) => (q < 0.5 ? 4 * q * q * q : 1 - Math.pow(-2 * q + 2, 3) / 2);

  // --- 状態: 経過時間 t の花びらの位置と向き（イベントと経過時間から決まる純粋な関数） ---
  function place(p, t) {
    const q = Math.max(0, Math.min(1, t / p.dur));
    const baseY = -60 + (H + 120) * q;
    const restY = p.piled ? docH - 10 - p.lift - scrollY : Infinity;
    const near = Math.max(0, Math.min(1, (restY - baseY) / 160));
    const calm = 1 - Math.max(Math.pow(q, 4), 1 - near); // 山に近づくほど舞いが収まる
    const n = p.gusts * 2 * Math.PI;
    const gustY = (H + 120) * p.gust * Math.sin(n * q) / n * calm; // 0 と 1 で 0 になる緩急
    const swayX = (p.swayA * Math.sin(p.swayF * t + p.phase) + p.wobbleA * Math.sin(p.wobbleF * t + p.phase2)) * calm;
    const landed = p.piled && baseY >= restY;
    return {
      x: (p.x + p.drift * Math.max(q, 1 - near)) * W + swayX,
      y: landed ? restY : Math.min(baseY + gustY, restY),
      rotZ: p.restRot + (p.spin * t + 28 * Math.sin(p.swayF * t + p.phase)) * calm * Math.PI / 180,
      rotY: p.restYaw * (1 - calm) + p.flipF * t * calm,                 // 翻る
      rotX: p.restPitch * (1 - calm) + 0.9 * Math.sin(p.tumbleF * t) * calm, // 前後に揺れる
      visible: t >= 0
    };
  }

  // 再生の時計: 実際の経過秒 s → 元の時間 τ。全員に同じ τ を使うので、順番も間隔も崩れない。
  // 速さは 1 → V（加速 RAMP 秒）→ V のまま → 1（減速 RAMP 秒）→ 最後の CATCH_UP 秒ぶんは等速。
  // 加減速は smoothstep で、その積分 u³ - u⁴/2 を使って τ を出す
  function replayTime(s) {
    const F = Math.max(0, replayLength - CATCH_UP); // 早送りで進める元の時間
    const V = Math.min(MAX_SPEED, Math.max(1, F / RAMP - 1));
    if (F === 0 || V === 1) return s;
    const plateau = Math.max(0, (F - RAMP * (1 + V)) / V);
    const ramped = (u) => u * u * u - u * u * u * u / 2;
    const rampUp = RAMP * (1 + V) / 2;
    if (s < RAMP) return s + (V - 1) * RAMP * ramped(s / RAMP);
    if (s < RAMP + plateau) return rampUp + V * (s - RAMP);
    if (s < 2 * RAMP + plateau) {
      const w = (s - RAMP - plateau) / RAMP;
      return rampUp + V * plateau + V * w * RAMP - (V - 1) * RAMP * ramped(w);
    }
    return F + (s - 2 * RAMP - plateau);
  }

  function elapsed(p, i) {
    if (mode === 'live') return clock - p.born;
    if (mode === 'rewind') {
      const q = ease(Math.max(0, Math.min(1, (clock - modeStart - p.rewindDelay) / LIFT)));
      return p.rewindFrom * (1 - q);
    }
    return replayTime(clock - modeStart) - (p.born - replayFrom);
  }

  // 花びら一枚を描く。翻る（rotY）と横幅が縮み、裏を向くと淡くなる
  function draw(p, s, fade) {
    const flip = Math.cos(s.rotY);
    const k = SIZE * p.scale;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.translate(s.x, s.y);
    ctx.rotate(s.rotZ);
    ctx.scale(k * Math.max(0.08, Math.abs(flip)), k);
    ctx.globalAlpha = p.alpha * fade * (flip >= 0 ? 1 : 0.7);
    ctx.drawImage(sprites[p.sprite], -20 - PAD, -26 - PAD, 40 + PAD * 2, 52 + PAD * 2);
  }

  // 波紋: 水面を斜めから見た平たい楕円。墨の細い線と、その周りの淡いにじみ
  function ripple(p, s, since) {
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.strokeStyle = INK;
    for (const delay of RINGS) {
      const u = (since - delay) / RIPPLE;
      if (u <= 0 || u >= 1) continue;
      const r = (6 + 46 * (1 - Math.pow(1 - u, 2.2))) * (0.7 + 0.5 * p.scale);
      const a = 0.3 * Math.pow(1 - u, 1.6) * (1 - delay);
      ctx.beginPath();
      ctx.ellipse(s.x, s.y + 4, r, r * 0.26, 0, 0, Math.PI * 2);
      ctx.globalAlpha = a * 0.25;
      ctx.lineWidth = 3;
      ctx.stroke();
      ctx.globalAlpha = a;
      ctx.lineWidth = 0.8;
      ctx.stroke();
    }
  }

  let drawn = 0;

  // draw が false なら状態だけ進める（テストの早送りで、途中のフレームは描かない）
  function frame(paint = true) {
    docH = document.documentElement.scrollHeight;
    scrollY = window.scrollY || window.pageYOffset || 0;

    if (paint) {
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      drawn = 0;
    }
    // 着地した花びらの波紋（花びらより下に描く）。着地からの経過時間だけで決まるので、
    // 巻き戻しでは輪が縮んで消え、再生では同じ波紋がもう一度広がる
    if (paint) {
      for (let i = 0; i < petals.length; i++) {
        const p = petals[i];
        if (!p.piled) continue;
        const since = elapsed(p, i) - p.dur;
        if (since < 0 || since > RIPPLE + RINGS[RINGS.length - 1]) continue;
        const s = place(p, p.dur);
        if (s.y > H + 40 || s.y < -40) continue;
        ripple(p, s, since);
      }
    }

    let done = true;
    for (let i = 0; i < petals.length; i++) {
      const p = petals[i];
      const t = elapsed(p, i);
      if (t < p.dur) done = false;
      if (!paint) continue;
      const s = place(p, t);
      if (!s.visible || s.y > H + 40 || s.y < -60) continue;
      const fade = p.piled ? 1 - Math.max(0, Math.min(1, (t - p.dur - STAY) / FADE)) : 1;
      if (fade <= 0) continue;
      draw(p, s, fade);
      drawn++;
    }

    if (mode === 'rewind' && clock - modeStart >= REWIND + 0.3) startReplay();
    else if (mode === 'replay' && done) finishReplay();
    if (mode === 'live') {
      while (clock >= nextSpawn) {
        spawn(nextSpawn);
        nextSpawn += 6.5 + random() * 5; // 同時に舞うのは2枚ほど
      }
      petals = petals.filter((p) => clock - p.born < life(p)); // 一生を終えた花びらは捨てる
    }
  }

  // --- 巻き戻して、同じイベントを再生する ---
  function rewind() {
    if (mode !== 'live' || !petals.length) return;
    petals = petals.filter((p) => clock - p.born < life(p));
    if (!petals.length) return;
    const n = petals.length;
    petals.forEach((p, i) => {
      p.rewindFrom = Math.min(clock - p.born, p.dur);
      p.rewindDelay = (REWIND - LIFT) * (n - 1 - i) / Math.max(1, n - 1); // 新しいものから
    });
    mode = 'rewind';
    modeStart = clock;
    document.documentElement.classList.add('is-replaying');
  }

  function startReplay() {
    replayFrom = petals[0].born;
    replayLength = Math.max(...petals.map((p) => p.born - replayFrom + p.dur));
    mode = 'replay';
    modeStart = clock;
  }

  function finishReplay() {
    // 再生した時刻を今の時計に付け替えて live に戻す（積もる位置は変わらない）
    const tau = replayTime(clock - modeStart);
    petals.forEach((p) => { p.born = clock - (tau - (p.born - replayFrom)); });
    nextSpawn = clock + 2;
    mode = 'live';
    document.documentElement.classList.remove('is-replaying');
  }

  let dpr = 1;
  function resize() {
    W = window.innerWidth;
    H = window.innerHeight;
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(W * dpr); // 表示の大きさは CSS で画面に合わせる
    canvas.height = Math.round(H * dpr);
    frame();
  }

  let last = null, running = false;
  function tick(now) {
    if (!running) return;
    const dt = last === null ? 0 : Math.min(0.05, (now - last) / 1000);
    last = now;
    clock += dt;
    frame();
    requestAnimationFrame(tick);
  }
  const play = () => { if (!running) { running = true; last = null; requestAnimationFrame(tick); } };
  const pause = () => { running = false; };

  // 開いた時点で、何枚かはもう宙にある
  for (let n = 0; n < 4; n++) spawn(-n * 4.5 - random() * 2);
  petals.sort((a, b) => a.born - b.born);
  petals.forEach((p, i) => settle(p, petals.slice(0, i))); // 並べ替えた順番が散った順番。その順に山へ載せ直す
  nextSpawn = 1.5;

  document.body.insertBefore(canvas, document.body.firstChild);
  document.documentElement.classList.add('petal-canvas-on');
  resize();
  addEventListener('resize', resize);
  document.addEventListener('visibilitychange', () => (document.hidden ? pause() : play()));
  play();

  // フッターの一言を、巻き戻しのボタンにする（押せることは主張しない）
  const trigger = document.querySelector('.footer__poem');
  if (trigger) {
    trigger.setAttribute('role', 'button');
    trigger.setAttribute('tabindex', '0');
    if (trigger.dataset.replayLabel) trigger.setAttribute('aria-label', trigger.dataset.replayLabel);
    trigger.addEventListener('click', rewind);
    trigger.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); rewind(); }
    });
  }

  // テスト・デバッグ用（時間を進める・状態を見る）
  window.__rakkaPetals = {
    advance(seconds) {
      for (let s = 0; s < seconds; s += 0.05) { clock += 0.05; frame(false); }
      frame();
    },
    state() {
      const flying = petals.filter((p, i) => { const t = mode === 'rewind' ? -1 : elapsed(p, i); return t >= 0 && t < p.dur; }).length;
      return {
        mode, count: petals.length, piled: countPiled(), flying, drawn,
        justLanded: petals.some((p, i) => { const d = elapsed(p, i) - p.dur; return p.piled && d >= 0 && d < 0.1; }),
        replayTime: mode === 'replay' ? replayTime(clock - modeStart) : null, replayLength,
        // 積もる位置（ページ上の座標。スクロール位置によらない）
        rests: petals.filter((p) => p.piled).map((p) => [Math.round((p.x + p.drift) * W), Math.round(docH - 10 - p.lift)]),
        // 画面の下端 80px に描かれている、積もった花びらの数
        pileInBottom: petals.filter((p, i) => p.piled && elapsed(p, i) >= p.dur).map((p) => docH - 10 - p.lift - scrollY).filter((y) => y > H - 80 && y < H + 20).length
      };
    },
    rewind
  };
}

try {
  start();
} catch (e) {
  // 描けない環境。ヒーローの静止した花びらが残る
}
})();
