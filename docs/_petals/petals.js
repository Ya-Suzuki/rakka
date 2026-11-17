/*
 * 落花: Ruby の宝石のような花びらが舞いながら散り、ページの底（フッターの下）に積もる。
 * 途中を読んでいる間は画面の下を通り抜けて見えなくなり、最後までスクロールすると山が見える。
 * フッターの一言を押すと、全部が巻き戻ってから同じように散り直し、同じ場所に積もる。
 *
 * 花びらの動きは「生まれた時刻と乱数から決まる値（イベント）」と「経過時間」だけで
 * 決まる純粋な関数（place）なので、巻き戻しも再生も、時間を動かすだけでできる。
 * 積もる位置も、散った順番だけで決まる。Rakka がイベントから状態を作り直すのと同じ。
 */
import {
  BufferGeometry, Color, DirectionalLight, DynamicDrawUsage, Float32BufferAttribute,
  HemisphereLight, InstancedMesh, MeshPhongMaterial, Object3D, OrthographicCamera,
  Scene, Vector3, WebGLRenderer
} from 'three';

const BINS = 72;          // 積もる位置の区切り（画面幅によらず一定。幅を変えても同じ山になる）
const LAYER = 3.4;        // 1枚積もるごとに山が高くなる量（px）
const HEAP_MAX = 40;      // 山の高さの上限（px）
const PILE_MAX = 180;     // 積もらせる枚数の上限。超えたら画面の外へ落ちて消える
const REWIND = 2.4;       // 巻き戻しにかける秒数（全体）
const LIFT = 1.1;         // 一枚が舞い上がるのにかける秒数。最後に散ったものから順に、ずらして上がる
const REPLAY_SPAN = 4.5;  // 再生で、最後の花びらが散り始めるまでの秒数
const SIZE = 21;          // 宝石の大きさ（幅 1.2 に掛ける px）
const CAPACITY = 256;

// --- 宝石の形: 正面から見ると Ruby のロゴの比率（横に広い上部と、下に尖る部分） ---
function gemGeometry() {
  const n = 8, depth = 0.42; // 薄くして、回ると花びらのように翻る
  const ring = (r, y) => Array.from({ length: n }, (_, i) => {
    const a = (i + 0.5) / n * Math.PI * 2;
    return new Vector3(r * Math.cos(a), y, r * depth * Math.sin(a));
  });
  const girdle = ring(0.6, 0), table = ring(0.38, 0.3);
  const top = new Vector3(0, 0.3, 0), tip = new Vector3(0, -0.72, 0);
  const center = new Vector3(0, -0.1, 0);
  const pos = [];
  const tri = (a, b, c) => {
    // 外向きの面になるように向きをそろえる（平らな陰影で面ごとに光り方が変わる）
    const normal = new Vector3().subVectors(b, a).cross(new Vector3().subVectors(c, a));
    const mid = new Vector3().add(a).add(b).add(c).divideScalar(3).sub(center);
    if (normal.dot(mid) < 0) [b, c] = [c, b];
    pos.push(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z);
  };
  for (let i = 0; i < n; i++) {
    const j = (i + 1) % n;
    tri(top, table[i], table[j]);               // テーブル
    tri(table[i], table[j], girdle[j]);         // クラウン
    tri(table[i], girdle[j], girdle[i]);
    tri(tip, girdle[i], girdle[j]);             // パビリオン
  }
  const g = new BufferGeometry();
  g.setAttribute('position', new Float32BufferAttribute(pos, 3));
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
  // 深い赤の地に、面ごとの鋭いきらめき（Ruby の宝石のように）
  scene.add(new HemisphereLight(0xfff1ec, 0x2a0408, 1.1));
  const key = new DirectionalLight(0xffffff, 2.4);
  key.position.set(-1, 1.5, 2);
  scene.add(key);
  const rim = new DirectionalLight(0xff8090, 0.9);
  rim.position.set(1.3, -0.8, 1);
  scene.add(rim);

  const material = new MeshPhongMaterial({ color: 0xffffff, specular: 0xffffff, shininess: 90, flatShading: true });
  const gems = new InstancedMesh(gemGeometry(), material, CAPACITY);
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
  let mode = 'live';
  let modeStart = 0;
  let replayOffsets = null;

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
      restRot: random() * Math.PI * 2, restYaw: random() * Math.PI * 2, restPitch: (random() - 0.5) * 1.2,
      color: new Color().setHSL(0.988 + shade * 0.015, 0.82, 0.3 + shade * 0.1),
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

  function elapsed(p, i) {
    if (mode === 'live') return clock - p.born;
    if (mode === 'rewind') {
      const q = ease(Math.max(0, Math.min(1, (clock - modeStart - p.rewindDelay) / LIFT)));
      return p.rewindFrom * (1 - q);
    }
    return clock - modeStart - replayOffsets[i];
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

    if (mode === 'rewind' && clock - modeStart >= REWIND + 0.15) startReplay();
    if (mode === 'replay' && done) finishReplay();
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
    const first = petals[0].born, last = petals[petals.length - 1].born;
    const k = last > first ? Math.min(1, REPLAY_SPAN / (last - first)) : 1;
    replayOffsets = petals.map((p) => (p.born - first) * k);
    mode = 'replay';
    modeStart = clock;
  }

  function finishReplay() {
    petals.forEach((p, i) => { p.born = modeStart + replayOffsets[i]; });
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
      const flying = mode === 'live' ? petals.filter((p) => { const t = clock - p.born; return t >= 0 && t < p.dur; }).length : null;
      return {
        mode, count: petals.length, piled: countPiled(), flying, drawn: gems.count,
        // 積もる位置（ページ上の座標。スクロール位置によらない）
        rests: petals.filter((p) => p.piled).map((p) => [Math.round((p.x + p.drift) * W), Math.round(docH - 10 - p.lift)]),
        // 画面の下端 80px に描かれている、積もった花びらの数
        pileInBottom: petals.filter((p) => p.piled && clock - p.born >= p.dur).map((p) => docH - 10 - p.lift - scrollY).filter((y) => y > H - 80 && y < H + 20).length
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
