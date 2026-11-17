/*
 * 落花: 花びらが舞いながら散り、ページの底（フッターの下）に積もる。途中を読んでいる
 * 間は画面の下を通り抜けて見えなくなり、最後までスクロールすると山が見える。
 * フッターの一言を押すと、全部が巻き戻ってから同じように散り直し、同じ場所に積もる。
 *
 * 花びらの動きは「生まれた時刻と乱数から決まる値（イベント）」と「経過時間」だけで
 * 決まる純粋な関数（place）なので、巻き戻しも再生も、時間を動かすだけでできる。
 * 積もる位置も、散った順番だけで決まる。Rakka がイベントから状態を作り直すのと同じ。
 *
 * 描画はすべてベクター。積もった山は、変わったときだけ実寸の裏画面に描き直して貼る。
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

  // 桜の花びらの輪郭を、宝石のカットのように切り分ける（40x52 の座標）。
  // 上の明るい面（クラウン）と、先端へ集まる深い赤の面（パビリオン）。
  // _layouts/landing.html の SVG（#petal）と同じ形
  var OUTLINE = new Path2D('M20 52 5 17C4 9 7 2 12 1c3-.5 6 1.5 8 6 2-4.5 5-6.5 8-6 5 1 8 8 7 16Z');
  var FACETS = [
    [[5, 0, 12, 1, 5, 17], '#e9868d'],
    [[12, 1, 12.5, 17, 5, 17], '#d9535c'],
    [[12, 1, 20, 7, 12.5, 17], '#f2b3b5'],
    [[20, 7, 20, 17, 12.5, 17], '#e46a73'],
    [[20, 7, 27.5, 17, 20, 17], '#c63a44'],
    [[20, 7, 28, 1, 27.5, 17], '#ee9aa0'],
    [[28, 1, 35, 17, 27.5, 17], '#d0444e'],
    [[28, 1, 35, 0, 35, 17], '#f4c0c1'],
    [[5, 17, 12.5, 17, 20, 52], '#9e1b25'],
    [[12.5, 17, 20, 17, 20, 52], '#c23040'],
    [[20, 17, 27.5, 17, 20, 52], '#a81f2a'],
    [[27.5, 17, 35, 17, 20, 52], '#86131c']
  ].map(function (f) {
    var pts = f[0], path = new Path2D();
    path.moveTo(pts[0], pts[1]);
    for (var i = 2; i < pts.length; i += 2) path.lineTo(pts[i], pts[i + 1]);
    path.closePath();
    return { path: path, color: f[1] };
  });

  var BINS = 72;          // 積もる位置の区切り（画面幅によらず一定。幅を変えても同じ山になる）
  var LAYER = 3.2;        // 1枚積もるごとに山が高くなる量（px）
  var HEAP_MAX = 40;      // 山の高さの上限（px）
  var PILE_MAX = 180;     // 積もらせる枚数の上限。超えたら画面の外へ落ちて消える
  var PILE_ZONE = 120;    // ページの底から、山を描く範囲の高さ（px）
  var REWIND = 2.4;       // 巻き戻しにかける秒数（全体）
  var LIFT = 1.1;         // 一枚が舞い上がるのにかける秒数。最後に散ったものから順に、ずらして上がる
  var REPLAY_SPAN = 4.5;  // 再生で、最後の花びらが散り始めるまでの秒数
  var SIZE = 0.74;        // 花びらの大きさ（40x52 に掛ける）

  var seed = 20261117;
  function random() {
    seed = (seed * 16807) % 2147483647;
    return seed / 2147483647;
  }

  var W = 0, H = 0, dpr = 1;
  var docH = 0, scrollY = 0;
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
    var scale = 0.55 + random() * 0.45;
    var p = {
      born: born,
      x: x, drift: end - x,
      dur: 11 + random() * 8,
      // 舞い方: 二つの揺れを重ね、落ちる速さにも緩急（ときどき風で持ち上がる）をつける
      swayA: 18 + random() * 40, swayF: 0.5 + random() * 0.6, phase: random() * Math.PI * 2,
      wobbleA: 6 + random() * 14, wobbleF: 1.3 + random() * 1.4, phase2: random() * Math.PI * 2,
      gust: 0.5 + random() * 0.8, gusts: 2 + Math.floor(random() * 3),
      spin: (random() - 0.5) * 140,
      flipF: 1.4 + random() * 2.6,
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

  // --- 状態: 経過時間 t の花びらの位置（イベントと経過時間から決まる純粋な関数） ---
  // 画面の上から下へ抜けるように舞い落ちる。ページの底の山が画面に見えていれば、その上で
  // 止まる。見えていなければ画面の外へ抜け、底に積もったことになる
  function place(p, t) {
    var q = Math.max(0, Math.min(1, t / p.dur));
    var baseY = -60 + (H + 120) * q;
    var restY = p.piled ? docH - 10 - p.lift - scrollY : Infinity;
    var near = Math.max(0, Math.min(1, (restY - baseY) / 160));
    var calm = 1 - Math.max(Math.pow(q, 4), 1 - near); // 山に近づくほど舞いが収まる
    var n = p.gusts * 2 * Math.PI;
    var gustY = (H + 120) * p.gust * Math.sin(n * q) / n * calm; // 0 と 1 で 0 になる緩急
    var swayX = (p.swayA * Math.sin(p.swayF * t + p.phase) + p.wobbleA * Math.sin(p.wobbleF * t + p.phase2)) * calm;
    var landed = p.piled && baseY >= restY;
    return {
      x: (p.x + p.drift * Math.max(q, 1 - near)) * W + swayX,
      y: landed ? restY : Math.min(baseY + gustY, restY),
      rot: (p.restRot + (p.spin * t + 28 * Math.sin(p.swayF * t + p.phase)) * calm) * Math.PI / 180,
      flip: Math.cos(p.flipF * t) * calm + p.restFlip * (1 - calm),
      settled: landed && calm === 0,
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

  // ベクターで一枚描く。g は描き先、(x, y) はその描き先での位置（CSS px）
  function paint(g, p, s, x, y) {
    var k = SIZE * p.scale;
    var sx = (s.flip < 0 ? -1 : 1) * Math.max(0.06, Math.abs(s.flip)); // 裏返るときは左右も反転
    g.setTransform(dpr * k * sx, 0, 0, dpr * k, x * dpr, y * dpr);
    g.rotate(s.rot);
    g.translate(-20, -26);
    g.globalAlpha = s.settled ? 0.85 : 0.97;
    g.save();
    g.clip(OUTLINE);
    for (var i = 0; i < FACETS.length; i++) {
      g.fillStyle = FACETS[i].color;
      g.fill(FACETS[i].path);
    }
    if (s.flip < 0) {
      g.fillStyle = 'rgba(70, 0, 12, 0.3)';
      g.fill(OUTLINE);
    }
    g.restore();
  }

  // --- 積もった山の裏画面（ページの底から PILE_ZONE の範囲） ---
  var pile = document.createElement('canvas');
  var pileCtx = pile.getContext('2d');
  var pileKey = '';

  function pileLanded(p) { return p.piled && clock - p.born >= p.dur; }

  function refreshPile() {
    var landed = 0;
    for (var i = 0; i < petals.length; i++) if (pileLanded(petals[i])) landed++;
    var key = [landed, W, dpr, docH].join(',');
    if (key === pileKey) return;
    pileKey = key;
    pile.width = Math.round(W * dpr);
    pile.height = Math.round(PILE_ZONE * dpr);
    pileCtx.setTransform(1, 0, 0, 1, 0, 0);
    pileCtx.clearRect(0, 0, pile.width, pile.height);
    var top = docH - PILE_ZONE; // 裏画面の上端（ページ上の座標）
    var savedScroll = scrollY;
    scrollY = top;               // place が返す y を裏画面の座標にする
    petals.forEach(function (p) {
      if (!pileLanded(p)) return;
      var s = place(p, p.dur);
      paint(pileCtx, p, s, s.x, s.y);
    });
    scrollY = savedScroll;
  }

  function frame() {
    docH = document.documentElement.scrollHeight;
    scrollY = window.scrollY || window.pageYOffset || 0;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    var cached = mode === 'live';
    if (cached) {
      refreshPile();
      var pileTop = docH - PILE_ZONE - scrollY;
      if (pileTop < H) ctx.drawImage(pile, 0, Math.round(pileTop * dpr));
    }

    var done = true;
    for (var i = 0; i < petals.length; i++) {
      var p = petals[i];
      var t = elapsed(p, i);
      if (t < p.dur) done = false;
      if (cached && pileLanded(p)) continue; // 裏画面に描いてある
      var s = place(p, t);
      if (!s.visible || s.y > H + 60 || s.y < -80) continue;
      paint(ctx, p, s, s.x, s.y);
    }

    if (mode === 'rewind' && clock - modeStart >= REWIND + 0.15) startReplay();
    if (mode === 'replay' && done) finishReplay();
    if (mode === 'live') {
      while (clock >= nextSpawn) {
        spawn(nextSpawn);
        nextSpawn += 3 + random() * 3.5; // 同時に舞うのは3〜4枚ほど
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
    petals.forEach(function (p, i) { p.born = modeStart + replayOffsets[i]; });
    nextSpawn = clock + 2;
    pileKey = '';
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
  for (var n = 0; n < 4; n++) spawn(-n * 4.5 - random() * 2);
  petals.sort(function (a, b) { return a.born - b.born; });
  // 先に生まれたものから山に載せ直す（並べ替えた順番が、散った順番）
  heap = [];
  petals.forEach(function (p) {
    if (!p.piled) return;
    var bin = Math.floor((p.x + p.drift) * BINS);
    p.lift = Math.min(heap[bin] || 0, HEAP_MAX) + p.jitter;
    heap[bin] = (heap[bin] || 0) + LAYER * p.scale;
  });
  nextSpawn = 1.5;

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
    state: function () {
      var flying = 0;
      petals.forEach(function (p) { var t = clock - p.born; if (mode === 'live' && t >= 0 && t < p.dur) flying++; });
      return { mode: mode, count: petals.length, piled: countPiled(), flying: flying,
        // 積もる位置（ページ上の座標。スクロール位置によらない）
        rests: petals.filter(function (p) { return p.piled; }).map(function (p) { return [Math.round((p.x + p.drift) * W), Math.round(docH - 10 - p.lift)]; }) };
    },
    rewind: rewind
  };
})();
