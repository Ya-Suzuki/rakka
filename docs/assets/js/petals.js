/*
 * 落花: 桜の花びらが舞いながら散り、ページの底（フッターの下）に積もる。
 * 途中を読んでいる間は画面の下を通り抜けて見えなくなり、最後までスクロールすると山が見える。
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
const PILE_MAX = 90;      // 積もらせる枚数の上限。超えたら画面の外へ落ちて消える
const REWIND = 2.4;       // 巻き戻しにかける秒数（全体）
const LIFT = 1.2;         // 一枚が舞い上がるのにかける秒数。最後に散ったものから順に、ずらして上がる
const MAX_SPEED = 50;     // 早送りの上限（倍）。これより速いと、落ちる途中が見えず下端に突然現れて見える
const RAMP = 1.2;         // 等速と上限の間を加速・減速するのにかける秒数
const CATCH_UP = 10;      // 最後に等速で再生する長さ（元の時間で秒）
const SIZE = 0.62;        // 花びらの大きさ（40 × 52 の形に掛ける倍率）

// 桜の花びら。左右で色を変え、Ruby の宝石のような面をひとつだけつける（40 × 52）
const LEFT = new Path2D('M20 52C6 40 0 26 4 12 7 4 14 1 18 6l2 4Z');
const RIGHT = new Path2D('M20 10l2-4c4-5 11-2 14 6 4 14-2 28-16 40Z');
const FACET = new Path2D('M20 10l-7 11 7 15Z');
const FRONT = ['#b42833', '#ee9aa0']; // 表（濃い面・明るい面）
const BACK = ['#e9868d', '#c23a45'];  // 裏は濃淡が入れ替わる

function start() {
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  canvas.className = 'petal-canvas';
  canvas.setAttribute('aria-hidden', 'true');

  // --- イベントの列 ---
  let seed = 20261117;
  const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;

  let W = 0, H = 0, docH = 0, scrollY = 0;
  let clock = 0;
  let petals = [];
  let heap = [];
  let nextSpawn = 0;
  let mode = 'live';       // live / rewind / replay
  let modeStart = 0;
  let replayFrom = 0;      // 再生の基準（最初の花びらが散った時刻）
  let replayLength = 0;    // 再生する元の時間の長さ（最初の花びらから、最後の花びらが積もるまで）

  const countPiled = () => petals.reduce((n, p) => n + (p.piled ? 1 : 0), 0);

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
      alpha: 0.88 + shade * 0.07, // 花びらごとのわずかな濃淡
      jitter: (random() - 0.5) * 6,
      piled: false, lift: 0
    };
    if (countPiled() < PILE_MAX) {
      p.piled = true;
      p.lift = Math.min(heap[bin] || 0, HEAP_MAX) + p.jitter;
      heap[bin] = (heap[bin] || 0) + LAYER * scale;
    }
    petals.push(p);
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

  // 花びら一枚を描く。翻る（rotY）と横幅が縮み、裏返ると裏の色になる
  function draw(p, s) {
    const flip = Math.cos(s.rotY);
    const k = SIZE * p.scale;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.translate(s.x, s.y);
    ctx.rotate(s.rotZ);
    ctx.scale(k * Math.max(0.08, Math.abs(flip)), k);
    ctx.translate(-20, -26);
    ctx.globalAlpha = p.alpha;
    const front = flip >= 0;
    ctx.fillStyle = front ? FRONT[0] : BACK[0];
    ctx.fill(LEFT);
    ctx.fillStyle = front ? FRONT[1] : BACK[1];
    ctx.fill(RIGHT);
    ctx.globalAlpha = 0.25;
    ctx.fillStyle = '#fff';
    ctx.fill(FACET);
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
    let done = true;
    for (let i = 0; i < petals.length; i++) {
      const p = petals[i];
      const t = elapsed(p, i);
      if (t < p.dur) done = false;
      if (!paint) continue;
      const s = place(p, t);
      if (!s.visible || s.y > H + 40 || s.y < -60) continue;
      draw(p, s);
      drawn++;
    }

    if (mode === 'rewind' && clock - modeStart >= REWIND + 0.3) startReplay();
    else if (mode === 'replay' && done) finishReplay();
    if (mode === 'live') {
      while (clock >= nextSpawn) {
        spawn(nextSpawn);
        nextSpawn += 6.5 + random() * 5; // 同時に舞うのは2枚ほど
      }
      petals = petals.filter((p) => p.piled || clock - p.born < p.dur); // 積もらない花びらは落ちきったら捨てる
    }
  }

  // --- 巻き戻して、同じイベントを再生する ---
  function rewind() {
    if (mode !== 'live' || !petals.length) return;
    petals = petals.filter((p) => p.piled || clock - p.born < p.dur);
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
  heap = [];
  petals.forEach((p) => { // 並べ替えた順番が散った順番。その順に山へ載せ直す
    if (!p.piled) return;
    const bin = Math.floor((p.x + p.drift) * BINS);
    p.lift = Math.min(heap[bin] || 0, HEAP_MAX) + p.jitter;
    heap[bin] = (heap[bin] || 0) + LAYER * p.scale;
  });
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
