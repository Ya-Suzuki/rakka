/*
 * 落花: Ruby の宝石のような花びらが舞いながら散り、ページの底（フッターの下）に積もる。
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
import {
  BufferGeometry, Color, DirectionalLight, DoubleSide, DynamicDrawUsage, Float32BufferAttribute,
  HemisphereLight, InstancedMesh, MeshPhongMaterial, Object3D, OrthographicCamera,
  Scene, WebGLRenderer
} from 'three';

const BINS = 72;          // 積もる位置の区切り（画面幅によらず一定。幅を変えても同じ山になる）
const LAYER = 3.4;        // 1枚積もるごとに山が高くなる量（px）
const HEAP_MAX = 40;      // 山の高さの上限（px）
const PILE_MAX = 180;     // 積もらせる枚数の上限。超えたら画面の外へ落ちて消える
const REWIND = 2.4;       // 巻き戻しにかける秒数（全体）
const LIFT = 1.2;         // 一枚が舞い上がるのにかける秒数。最後に散ったものから順に、ずらして上がる
const MAX_SPEED = 50;     // 早送りの上限（倍）。これより速いと、落ちる途中が見えず下端に突然現れて見える
const RAMP = 1.2;         // 等速と上限の間を加速・減速するのにかける秒数
const CATCH_UP = 10;      // 最後に等速で再生する長さ（元の時間で秒）
const SIZE = 22;          // 花びらの大きさ（幅 1.24 に掛ける px）
const CAPACITY = 256;

// --- 花びらの形 ---
// 輪郭は Ruby のロゴに寄せ（上辺はほぼ平ら、両側は真っすぐ先端へ。横に広い）、上辺の中央に
// 桜の花びらの浅い切れ込み。表面は宝石のようなカット（ローポリゴンの面）。薄い一枚で、縁が
// 後ろへ反っている。色は根元の深い赤から先端の明るい赤へ。
// 形のデータは shape.py が作る（_layouts/landing.html の SVG は、これを正面から見た形）
const PETAL_POSITIONS = [0, 0.45, 0.05, 0.07, 0.52, 0.0414, 0, 0.22, 0.05, 0.07, 0.52, 0.0414, 0.3, 0.54, -0.025, 0.32, 0.26, -0.0336, 0.07, 0.52, 0.0414, 0.32, 0.26, -0.0336, 0, 0.22, 0.05, 0.3, 0.54, -0.025, 0.5, 0.52, -0.1306, 0.32, 0.26, -0.0336, 0.5, 0.52, -0.1306, 0.6, 0.42, -0.2, 0.32, 0.26, -0.0336, 0.6, 0.42, -0.2, 0.57, 0.24, -0.178, 0.32, 0.26, -0.0336, 0.32, 0.26, -0.0336, 0.57, 0.24, -0.178, 0, -0.12, 0.05, 0.57, 0.24, -0.178, 0.45, 0.02, -0.1, 0, -0.12, 0.05, 0.45, 0.02, -0.1, 0.27, -0.25, -0.013, 0, -0.12, 0.05, 0.27, -0.25, -0.013, 0, -0.5, 0.05, 0, -0.12, 0.05, 0, 0.22, 0.05, 0.32, 0.26, -0.0336, 0, -0.12, 0.05, 0, 0.45, 0.05, -0.07, 0.52, 0.0414, 0, 0.22, 0.05, -0.07, 0.52, 0.0414, -0.3, 0.54, -0.025, -0.32, 0.26, -0.0336, -0.07, 0.52, 0.0414, -0.32, 0.26, -0.0336, 0, 0.22, 0.05, -0.3, 0.54, -0.025, -0.5, 0.52, -0.1306, -0.32, 0.26, -0.0336, -0.5, 0.52, -0.1306, -0.6, 0.42, -0.2, -0.32, 0.26, -0.0336, -0.6, 0.42, -0.2, -0.57, 0.24, -0.178, -0.32, 0.26, -0.0336, -0.32, 0.26, -0.0336, -0.57, 0.24, -0.178, 0, -0.12, 0.05, -0.57, 0.24, -0.178, -0.45, 0.02, -0.1, 0, -0.12, 0.05, -0.45, 0.02, -0.1, -0.27, -0.25, -0.013, 0, -0.12, 0.05, -0.27, -0.25, -0.013, 0, -0.5, 0.05, 0, -0.12, 0.05, 0, 0.22, 0.05, -0.32, 0.26, -0.0336, 0, -0.12, 0.05];
const PETAL_COLORS = [0.6867, 0.0887, 0.1144, 0.7454, 0.1144, 0.1441, 0.5583, 0.0343, 0.0513, 0.7454, 0.1144, 0.1441, 0.8148, 0.1413, 0.1746, 0.6445, 0.0561, 0.0782, 0.7454, 0.1144, 0.1441, 0.6445, 0.0561, 0.0782, 0.5583, 0.0343, 0.0513, 0.8148, 0.1413, 0.1746, 0.8469, 0.15, 0.1845, 0.6445, 0.0561, 0.0782, 0.8469, 0.15, 0.1845, 0.807, 0.1221, 0.1529, 0.6445, 0.0561, 0.0782, 0.807, 0.1221, 0.1529, 0.6795, 0.0648, 0.0887, 0.6445, 0.0561, 0.0782, 0.6445, 0.0561, 0.0782, 0.6795, 0.0648, 0.0887, 0.3763, 0.011, 0.0194, 0.6795, 0.0648, 0.0887, 0.5271, 0.0252, 0.0395, 0.3763, 0.011, 0.0194, 0.5271, 0.0252, 0.0395, 0.3467, 0.0137, 0.0242, 0.3763, 0.011, 0.0194, 0.3467, 0.0137, 0.0242, 0.2086, 0.0052, 0.011, 0.3763, 0.011, 0.0194, 0.5583, 0.0343, 0.0513, 0.6445, 0.0561, 0.0782, 0.3763, 0.011, 0.0194, 0.6867, 0.0887, 0.1144, 0.7454, 0.1144, 0.1441, 0.5583, 0.0343, 0.0513, 0.7454, 0.1144, 0.1441, 0.8148, 0.1413, 0.1746, 0.6445, 0.0561, 0.0782, 0.7454, 0.1144, 0.1441, 0.6445, 0.0561, 0.0782, 0.5583, 0.0343, 0.0513, 0.8148, 0.1413, 0.1746, 0.8469, 0.15, 0.1845, 0.6445, 0.0561, 0.0782, 0.8469, 0.15, 0.1845, 0.807, 0.1221, 0.1529, 0.6445, 0.0561, 0.0782, 0.807, 0.1221, 0.1529, 0.6795, 0.0648, 0.0887, 0.6445, 0.0561, 0.0782, 0.6445, 0.0561, 0.0782, 0.6795, 0.0648, 0.0887, 0.3763, 0.011, 0.0194, 0.6795, 0.0648, 0.0887, 0.5271, 0.0252, 0.0395, 0.3763, 0.011, 0.0194, 0.5271, 0.0252, 0.0395, 0.3467, 0.0137, 0.0242, 0.3763, 0.011, 0.0194, 0.3467, 0.0137, 0.0242, 0.2086, 0.0052, 0.011, 0.3763, 0.011, 0.0194, 0.5583, 0.0343, 0.0513, 0.6445, 0.0561, 0.0782, 0.3763, 0.011, 0.0194];

function petalGeometry() {
  const g = new BufferGeometry();
  g.setAttribute('position', new Float32BufferAttribute(PETAL_POSITIONS, 3));
  g.setAttribute('color', new Float32BufferAttribute(PETAL_COLORS, 3));
  g.computeVertexNormals();
  return g;
}

function start() {
  const renderer = new WebGLRenderer({ alpha: true, antialias: true, powerPreference: 'low-power' });
  const canvas = renderer.domElement;
  canvas.className = 'petal-canvas';
  canvas.setAttribute('aria-hidden', 'true');
  renderer.setClearColor(0x000000, 0);

  const scene = new Scene();
  // 面ごとに光り方が変わる（カット）が、きらめきは花びらの艶ていどに抑える
  scene.add(new HemisphereLight(0xfff3ee, 0x3a0a10, 1.2));
  const key = new DirectionalLight(0xffffff, 1.9);
  key.position.set(-1, 1.5, 2);
  scene.add(key);
  const rim = new DirectionalLight(0xffb0ba, 0.7);
  rim.position.set(1.3, -0.8, 1);
  scene.add(rim);

  const material = new MeshPhongMaterial({
    vertexColors: true, specular: 0x6a3a3e, shininess: 36, flatShading: true, side: DoubleSide
  });
  const gems = new InstancedMesh(petalGeometry(), material, CAPACITY);
  gems.instanceMatrix.setUsage(DynamicDrawUsage);
  gems.frustumCulled = false;
  scene.add(gems);

  const camera = new OrthographicCamera(0, 1, 0, -1, -100, 100); // 1 単位 = 1 CSS px（y は下向きを負に）
  camera.position.z = 50;

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
      color: new Color().setScalar(0.82 + shade * 0.18), // 花びらごとの濃淡（頂点の色に掛ける）
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

  const dummy = new Object3D();

  // draw が false なら状態だけ進める（テストの早送りで、途中のフレームは描かない）
  function frame(draw = true) {
    docH = document.documentElement.scrollHeight;
    scrollY = window.scrollY || window.pageYOffset || 0;

    let done = true, count = 0;
    for (let i = 0; i < petals.length; i++) {
      const p = petals[i];
      const t = elapsed(p, i);
      if (t < p.dur) done = false;
      if (!draw || count >= CAPACITY) continue;
      const s = place(p, t);
      if (!s.visible || s.y > H + 60 || s.y < -80) continue;
      dummy.position.set(s.x, -s.y, 0);
      dummy.rotation.set(s.rotX, s.rotY, s.rotZ, 'ZXY');
      dummy.scale.setScalar(SIZE * p.scale);
      dummy.updateMatrix();
      gems.setMatrixAt(count, dummy.matrix);
      gems.setColorAt(count, p.color);
      count++;
    }
    if (draw) {
      gems.count = count;
      gems.instanceMatrix.needsUpdate = true;
      if (gems.instanceColor) gems.instanceColor.needsUpdate = true;
      renderer.render(scene, camera);
    }

    if (mode === 'rewind' && clock - modeStart >= REWIND + 0.3) startReplay();
    else if (mode === 'replay' && done) finishReplay();
    if (mode === 'live') {
      while (clock >= nextSpawn) {
        spawn(nextSpawn);
        nextSpawn += 3 + random() * 3.5; // 同時に舞うのは3〜4枚ほど
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

  function resize() {
    W = window.innerWidth;
    H = window.innerHeight;
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.setSize(W, H); // 表示の大きさ（CSS）もここで画面に合わせる
    camera.right = W;
    camera.bottom = -H;
    camera.updateProjectionMatrix();
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
        mode, count: petals.length, piled: countPiled(), flying, drawn: gems.count,
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
  // WebGL が使えないなど。ヒーローの静止した花びらが残る
}
