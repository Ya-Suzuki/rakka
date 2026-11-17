/*
 * 落花: 花びらが散り続けて画面の下に積もる。フッターの一言を押すと、全部が
 * 巻き戻ってから同じように散り直し、同じ場所に積もる。
 *
 * 花びらの動きは「生まれた時刻と乱数から決まる値（イベント）」と「経過時間」だけで
 * 決まる純粋な関数（place）なので、巻き戻しも再生も、時間を動かすだけでできる。
 * 積もる位置も、散った順番だけで決まる。Rakka がイベントから状態を作り直すのと同じ。
 */
(function () {
  'use strict';

  if (!window.matchMedia || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  var canvas = document.createElement('canvas');
  var ctx = canvas.getContext && canvas.getContext('2d');
  if (!ctx || !window.Path2D) return;

  canvas.className = 'petal-canvas';
  canvas.setAttribute('aria-hidden', 'true');
  document.body.insertBefore(canvas, document.body.firstChild);
  document.documentElement.classList.add('petal-canvas-on');

  // 桜の花びら（左右で色を変えて、Ruby の宝石のような面をつける）。40x52 の座標
  var LEFT = new Path2D('M20 52C6 40 0 26 4 12 7 4 14 1 18 6l2 4Z');
  var RIGHT = new Path2D('M20 10l2-4c4-5 11-2 14 6 4 14-2 28-16 40Z');
  var FACET = new Path2D('M20 10l-7 11 7 15Z');

  var BINS = 72;          // 積もる位置の区切り（画面幅によらず一定。幅を変えても同じ山になる）
  var LAYER = 3.2;        // 1枚積もるごとに山が高くなる量（px）
  var HEAP_MAX = 64;      // 山の高さの上限（px）
  var PILE_MAX = 180;     // 積もらせる枚数の上限。超えたら画面の外へ落ちて消える
  var REWIND = 2.4;       // 巻き戻しにかける秒数（全体）
  var LIFT = 1.1;         // 一枚が舞い上がるのにかける秒数。最後に散ったものから順に、ずらして上がる
  var REPLAY_SPAN = 4.5;  // 再生で、最後の花びらが散り始めるまでの秒数

  var seed = 20261117;
  function random() {
    seed = (seed * 16807) % 2147483647;
    return seed / 2147483647;
  }

  var W = 0, H = 0, dpr = 1;
  var clock = 0;          // ページが見えている間だけ進む時計（秒）
  var petals = [];        // 散った花びら（イベントの列）
  var heap = [];          // 区切りごとの山の高さ
  var nextSpawn = 0;
  var mode = 'live';      // live / rewind / replay
  var modeStart = 0;
  var replayOffsets = null;

  // --- イベント: 花びらが一枚散った ---
  function spawn(born) {
    // 風は右へ吹いている。落ちる先は右下に寄り、吹き溜まりになる
    var end = Math.min(0.995, 1 - 0.97 * Math.pow(random(), 1.7));
    var x = Math.max(0.005, end - (0.04 + random() * 0.18));
    var bin = Math.floor(end * BINS);
    var scale = 0.5 + random() * 0.5;
    var p = {
      born: born,
      x: x, drift: end - x,
      dur: 9 + random() * 7,
      swayAmp: 10 + random() * 26,
      swayF: 0.6 + random() * 0.8,
      phase: random() * Math.PI * 2,
      spin: (random() - 0.5) * 220,
      flipF: 1.2 + random() * 2.2,
      scale: scale,
      restRot: random() * 360,
      restFlip: 0.35 + random() * 0.65,
      jitter: (random() - 0.5) * 6,
      piled: false,
      lift: 0
    };
    // 積もる高さは、それまでに散った順番だけで決まる
    if (countPiled() < PILE_MAX) {
      p.piled = true;
      p.lift = Math.min(heap[bin] || 0, HEAP_MAX) + p.jitter;
      heap[bin] = (heap[bin] || 0) + LAYER * scale;
    }
    petals.push(p);
  }

  function countPiled() {
    var n = 0;
    for (var i = 0; i < petals.length; i++) if (petals[i].piled) n++;
    return n;
  }

  function ease(q) { return q < 0.5 ? 4 * q * q * q : 1 - Math.pow(-2 * q + 2, 3) / 2; }

  // --- 状態: 経過時間 t の花びらの位置（純粋な関数） ---
  function place(p, t) {
    var q = Math.max(0, Math.min(1, t / p.dur));
    var restY = p.piled ? H - 8 - p.lift : H + 80;
    var settle = Math.pow(q, 4);
    return {
      x: (p.x + p.drift * q) * W + p.swayAmp * Math.sin(p.swayF * t + p.phase) * (1 - settle),
      y: -60 + (restY + 60) * q,
      rot: (p.restRot + p.spin * (p.dur - Math.min(t, p.dur)) / 10) * Math.PI / 180,
      flip: Math.cos(p.flipF * t) * (1 - settle) + p.restFlip * settle,
      settled: q >= 1,
      visible: t >= 0
    };
  }

  // 各モードで、花びらごとの経過時間を返す
  function elapsed(p, i) {
    if (mode === 'live') return clock - p.born;
    if (mode === 'rewind') {
      var q = ease(Math.max(0, Math.min(1, (clock - modeStart - p.rewindDelay) / LIFT)));
      return p.rewindFrom * (1 - q);
    }
    return clock - modeStart - replayOffsets[i];
  }

  function draw(p, s) {
    if (!s.visible) return;
    var k = 0.62 * p.scale;
    ctx.setTransform(dpr * k * Math.max(0.08, Math.abs(s.flip)), 0, 0, dpr * k, s.x * dpr, s.y * dpr);
    ctx.rotate(s.rot);
    ctx.translate(-20, -26);
    ctx.globalAlpha = p.piled && s.settled ? 0.8 : 0.95;
    ctx.fillStyle = s.flip >= 0 ? '#b42833' : '#e9868d';
    ctx.fill(LEFT);
    ctx.fillStyle = s.flip >= 0 ? '#ee9aa0' : '#c23a45';
    ctx.fill(RIGHT);
    ctx.globalAlpha = 0.25;
    ctx.fillStyle = '#fff';
    ctx.fill(FACET);
  }

  function frame() {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    var done = true;
    for (var i = 0; i < petals.length; i++) {
      var p = petals[i];
      var t = elapsed(p, i);
      if (t < p.dur) done = false;
      draw(p, place(p, t));
    }

    if (mode === 'rewind' && clock - modeStart >= REWIND + 0.15) startReplay();
    if (mode === 'replay' && done) finishReplay();
    if (mode === 'live') {
      while (clock >= nextSpawn) {
        spawn(nextSpawn);
        nextSpawn += 0.9 + random() * 1.4;
      }
      // 積もらない花びらは、落ちきったら捨てる
      petals = petals.filter(function (p) { return p.piled || clock - p.born < p.dur; });
    }
  }

  // --- 巻き戻して、同じイベントを再生する ---
  function rewind() {
    if (mode !== 'live' || !petals.length) return;
    petals = petals.filter(function (p) { return p.piled || clock - p.born < p.dur; });
    var n = petals.length;
    petals.forEach(function (p, i) {
      p.rewindFrom = Math.min(clock - p.born, p.dur);
      p.rewindDelay = (REWIND - LIFT) * (n - 1 - i) / Math.max(1, n - 1); // 新しいものから
    });
    mode = 'rewind';
    modeStart = clock;
    document.documentElement.classList.add('is-replaying');
  }

  function startReplay() {
    var first = petals[0].born, last = petals[petals.length - 1].born;
    var k = last > first ? Math.min(1, REPLAY_SPAN / (last - first)) : 1;
    replayOffsets = petals.map(function (p) { return (p.born - first) * k; });
    mode = 'replay';
    modeStart = clock;
  }

  function finishReplay() {
    // 再生が終わった時点を、それぞれが散り終えた状態として live に戻す
    petals.forEach(function (p, i) { p.born = clock - (clock - modeStart - replayOffsets[i]); });
    nextSpawn = clock + 1.2;
    mode = 'live';
    document.documentElement.classList.remove('is-replaying');
  }

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
  }

  // --- ループ（ページが見えている間だけ時計を進める） ---
  var last = null, running = false;
  function tick(now) {
    if (!running) return;
    var dt = last === null ? 0 : Math.min(0.05, (now - last) / 1000);
    last = now;
    clock += dt;
    frame();
    window.requestAnimationFrame(tick);
  }
  function start() {
    if (running) return;
    running = true;
    last = null;
    window.requestAnimationFrame(tick);
  }
  function stop() { running = false; }

  // 開いた時点で、何枚かはもう宙にある
  for (var n = 0; n < 9; n++) spawn(-n * 1.5 - random());
  petals.sort(function (a, b) { return a.born - b.born; });
  // 先に生まれたものから山に載せ直す（並べ替えた順番が、散った順番）
  heap = [];
  petals.forEach(function (p) {
    if (!p.piled) return;
    var bin = Math.floor((p.x + p.drift) * BINS);
    p.lift = Math.min(heap[bin] || 0, HEAP_MAX) + p.jitter;
    heap[bin] = (heap[bin] || 0) + LAYER * p.scale;
  });
  nextSpawn = 0.8;

  resize();
  window.addEventListener('resize', resize);
  document.addEventListener('visibilitychange', function () { document.hidden ? stop() : start(); });
  start();

  // フッターの一言を、巻き戻しのボタンにする
  var trigger = document.querySelector('.footer__poem');
  if (trigger) {
    trigger.setAttribute('role', 'button');
    trigger.setAttribute('tabindex', '0');
    if (trigger.dataset.replayLabel) trigger.setAttribute('aria-label', trigger.dataset.replayLabel);
    trigger.addEventListener('click', rewind);
    trigger.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); rewind(); }
    });
  }

  // テスト・デバッグ用（時間を進める・状態を見る）
  window.__rakkaPetals = {
    advance: function (seconds) { for (var s = 0; s < seconds; s += 0.05) { clock += 0.05; frame(); } },
    state: function () { return { mode: mode, count: petals.length, piled: countPiled(),
      rests: petals.filter(function (p) { return p.piled; }).map(function (p) { var s = place(p, p.dur); return [Math.round(s.x), Math.round(s.y)]; }) }; },
    rewind: rewind
  };
})();
