/*
 * 屏風に花びらが散り、水面に落ちて波紋が広がる。トップページの背景に、繰り返し流す。
 *
 * 背景は長谷川等伯「松林図屏風」左隻（パブリックドメイン）。花びらは鉤勒（墨の細い輪郭）に
 * 胡粉と淡い臙脂を差した、古い絵の桜。波紋は墨の細い線。
 * 花びらも波紋も時刻 t の関数で、LOOP 秒で元に戻る（最後のフレームから最初へ継ぎ目なくつながる）。
 */
import { AbsoluteFill, Img, staticFile, useCurrentFrame } from 'remotion';

export const FPS = 30;
export const LOOP = 24;     // 一巡りの秒数
const W = 1920, H = 1080;
const FOLDS = [22, 446, 872, 1294, 1718]; // 扇の継ぎ目（x）

// 決まった種から作る乱数（毎回同じ花びらになる）
const rng = (seed) => () => (seed = (seed * 16807) % 2147483647) / 2147483647;

const PETALS = (() => {
  const r = rng(20261126);
  const n = 8, list = [];
  for (let i = 0; i < n; i++) {
    const x0 = 140 + r() * (W - 420);
    list.push({
      start: (i + r() * 0.6) * LOOP / n,
      fall: 10 + r() * 3,           // 落ちるのにかける秒数
      float: 5 + r() * 1.5,         // 水に浮いて消えるまで
      x0, drift: 60 + r() * 140,
      land: 870 + r() * 150,        // 水面に落ちる高さ
      size: 0.95 + r() * 0.45,
      swayA: 30 + r() * 45, swayF: 0.45 + r() * 0.35, phase: r() * 6.28,
      spin: (r() - 0.5) * 50, rot0: r() * 360,
      flipF: 0.9 + r() * 1.2, phase2: r() * 6.28,
      gust: 0.04 + r() * 0.05,
      variant: i % 3,
      rings: [0, 0.45 + r() * 0.15, 0.95 + r() * 0.2]
    });
  }
  return list;
})();

const RIPPLE = 3.4; // 輪がひとつ広がって消えるまでの秒数

const clamp = (v) => Math.max(0, Math.min(1, v));
const smooth = (v) => v * v * (3 - 2 * v);
const local = (t, start) => ((t - start) % LOOP + LOOP) % LOOP;

// 花びら一枚の位置と向き
function petalAt(p, t) {
  const u = local(t, p.start);
  if (u < p.fall) {
    const q = u / p.fall;
    const calm = 1 - Math.pow(q, 3);
    const y = -90 + (p.land + 90) * (q * (1.12 - 0.12 * q)) - H * p.gust * Math.sin(q * Math.PI * 2) * calm;
    const x = p.x0 + p.drift * q + p.swayA * Math.sin(p.swayF * u * 2 + p.phase) * calm;
    return {
      x, y, rot: p.rot0 + p.spin * u + 22 * Math.sin(p.swayF * u * 2 + p.phase) * calm,
      flip: Math.cos(p.flipF * u * 2 + p.phase2), lie: 0, alpha: 1
    };
  }
  const v = u - p.fall;
  if (v > p.float) return null;
  // 水に浮かぶ: 斜めから見るので平たくなり、ゆっくり流れて消える
  const end = petalAt({ ...p, fall: p.fall }, p.start + p.fall - 0.0001);
  const settle = smooth(clamp(v / 0.6));
  return {
    x: end.x + 10 * v, y: p.land + 1.5 * Math.sin(v * 2.2),
    rot: end.rot + 4 * v, flip: end.flip * (1 - settle) + (end.flip >= 0 ? 1 : -1) * settle,
    lie: settle, alpha: 1 - smooth(clamp((v - p.float * 0.45) / (p.float * 0.55)))
  };
}

// 鉤勒の桜の花びら（40 × 52、根元が下）。種の違う3枚を用意して描き分ける
const OUTLINE = 'M20 51C13 48.5 4.5 39 3 27 1.6 15 6 4.5 14 3.6 17 3.3 19 5 20 8.5 21 5 23 3.3 26 3.6 34 4.5 38.4 15 37 27 35.5 39 27 48.5 20 51Z';
const PetalDefs = () => (
  <defs>
    {/* 胡粉（古びて少し黄ばんだ白）から、根元の淡い臙脂へ */}
    <linearGradient id="gofun" x1="0.2" y1="0" x2="0.5" y2="1">
      <stop offset="0" stopColor="#efe4d1" />
      <stop offset="0.35" stopColor="#ecdccb" />
      <stop offset="0.62" stopColor="#e6cdbf" />
      <stop offset="0.85" stopColor="#d4a69e" />
      <stop offset="1" stopColor="#b4716f" />
    </linearGradient>
    <clipPath id="petal-clip"><path d={OUTLINE} /></clipPath>
    <filter id="pool" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="1.6" /></filter>
    {[0, 1, 2].map((v) => (
      <g key={v}>
        {/* 胡粉の地: 紙に擦れて粒立ち、縁がにじむ */}
        <filter id={`wash${v}`} x="-20%" y="-20%" width="140%" height="140%">
          <feTurbulence type="fractalNoise" baseFrequency="0.45" numOctaves="3" seed={3 + v} result="n" />
          <feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -0.55 1.12" result="grain" />
          <feComposite in="SourceGraphic" in2="grain" operator="in" result="w" />
          <feTurbulence type="fractalNoise" baseFrequency="0.09" numOctaves="2" seed={11 + v} result="d" />
          <feDisplacementMap in="w" in2="d" scale="2.4" xChannelSelector="R" yChannelSelector="G" />
          <feGaussianBlur stdDeviation="0.35" />
        </filter>
        {/* 墨の線: 筆の揺れ */}
        <filter id={`brush${v}`} x="-20%" y="-20%" width="140%" height="140%">
          <feTurbulence type="fractalNoise" baseFrequency="0.14" numOctaves="2" seed={21 + v} result="d" />
          <feDisplacementMap in="SourceGraphic" in2="d" scale="1.6" xChannelSelector="R" yChannelSelector="G" />
          <feGaussianBlur stdDeviation="0.18" />
        </filter>
        <symbol id={`petal${v}`} viewBox="-4 -4 48 60" overflow="visible">
          <g filter={`url(#wash${v})`}>
            <path d={OUTLINE} fill="url(#gofun)" opacity="0.9" />
            {/* 縁に溜まる顔料 */}
            <g clipPath="url(#petal-clip)">
              <path d={OUTLINE} fill="none" stroke="#b47472" strokeWidth="3.2" opacity="0.4" filter="url(#pool)" />
            </g>
          </g>
          <g filter={`url(#brush${v})`} fill="none" stroke="#2b2420" strokeLinecap="round">
            <path d={OUTLINE} strokeWidth="1.15" opacity="0.82" strokeDasharray={['70 2.4 34 1.6 90', '44 1.8 60 2.6 80', '90 2 26 1.4 70'][v]} />
            <path d="M20 49Q18 34 13 17M20 49Q20.5 32 20 14M20 49Q22.5 34 27 17" strokeWidth="0.5" opacity="0.32" />
            <ellipse cx="20" cy="50.2" rx="1.3" ry="1" fill="#3a2a26" stroke="none" opacity="0.6" />
          </g>
        </symbol>
      </g>
    ))}
    {/* 波紋の筆: 縁を揺らし、かすれで途切れさせる */}
    <filter id="ripple-brush" x="-10%" y="-60%" width="120%" height="220%">
      <feTurbulence type="fractalNoise" baseFrequency="0.035 0.25" numOctaves="2" seed="5" result="d" />
      <feDisplacementMap in="SourceGraphic" in2="d" scale="3.5" xChannelSelector="R" yChannelSelector="G" result="s" />
      <feTurbulence type="fractalNoise" baseFrequency="0.018 0.6" numOctaves="3" seed="9" result="n" />
      <feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 4 -1.4" result="dry" />
      <feComposite in="s" in2="dry" operator="in" />
      <feGaussianBlur stdDeviation="0.5" />
    </filter>
  </defs>
);

function Ripples({ p, t }) {
  const v = local(t, p.start) - p.fall;
  if (v < 0) return null;
  const end = petalAt(p, p.start + p.fall - 0.0001);
  return p.rings.map((delay, i) => {
    const w = (v - delay) / RIPPLE;
    if (w <= 0 || w >= 1) return null;
    const rx = (10 + 150 * (1 - Math.pow(1 - w, 2.4))) * p.size;
    const ry = rx * 0.2;
    const a = 0.62 * Math.pow(1 - w, 1.4) * (1 - i * 0.2);
    // 輪は手前が太く奥が細い（斜めから見た水面）。外の楕円から、上へずらした内の楕円を抜く
    const th = (5 * (1 - w) + 1.4) * (1 - i * 0.15);
    const cx = end.x, cy = p.land + 6;
    const ring = (x, y, ex, ey) => `M${x - ex} ${y}a${ex} ${ey} 0 1 0 ${2 * ex} 0a${ex} ${ey} 0 1 0 ${-2 * ex} 0Z`;
    return (
      <path key={i} d={ring(cx, cy, rx, ry) + ring(cx, cy - th * 0.55, rx - th * 0.5, ry - th * 0.5)}
        fillRule="evenodd" fill="#2b2420" opacity={a} filter="url(#ripple-brush)" />
    );
  });
}

function Petal({ p, t }) {
  const s = petalAt(p, t);
  if (!s) return null;
  const k = 0.95 * p.size;
  const back = s.flip < 0;
  // 水に浮くと、斜めから見て縦に平たくなる（回転の後に潰す）
  return (
    <g transform={`translate(${s.x} ${s.y}) scale(1 ${1 - 0.5 * s.lie}) rotate(${s.rot}) scale(${k * Math.max(0.1, Math.abs(s.flip))} ${k})`}
      opacity={s.alpha * (back ? 0.78 : 1)}>
      <use href={`#petal${p.variant}`} x={-24} y={-30} width={48} height={60} />
    </g>
  );
}

// 屏風の折れ: 扇ごとに光の当たり方が違う（山折り・谷折りが交互）
const Folds = () => {
  const edges = [0, ...FOLDS, W];
  return (
    <svg width={W} height={H} style={{ position: 'absolute', inset: 0 }}>
      <defs>
        <linearGradient id="fold-a" x1="0" x2="1"><stop offset="0" stopColor="#fff" stopOpacity="0.07" /><stop offset="1" stopColor="#000" stopOpacity="0.05" /></linearGradient>
        <linearGradient id="fold-b" x1="0" x2="1"><stop offset="0" stopColor="#000" stopOpacity="0.06" /><stop offset="1" stopColor="#fff" stopOpacity="0.05" /></linearGradient>
      </defs>
      {edges.slice(0, -1).map((x, i) => (
        <rect key={i} x={x} y={0} width={edges[i + 1] - x} height={H} fill={`url(#fold-${i % 2 ? 'b' : 'a'})`} />
      ))}
    </svg>
  );
};

// 霞: ゆっくり流れる（一巡りで元の位置に戻る）
const Mist = ({ t }) => {
  const a = Math.sin((t / LOOP) * Math.PI * 2);
  const b = Math.cos((t / LOOP) * Math.PI * 2);
  const blob = (x, y, w, h, o) => ({
    position: 'absolute', left: x - w / 2, top: y - h / 2, width: w, height: h, borderRadius: '50%',
    background: `radial-gradient(closest-side, rgba(246,240,229,${o}), rgba(246,240,229,0))`
  });
  return (
    <>
      <div style={blob(700 + 120 * a, 780, 1500, 300, 0.32)} />
      <div style={blob(1350 - 140 * b, 560, 1300, 260, 0.22)} />
      <div style={blob(400 - 90 * b, 950, 1200, 240, 0.3)} />
    </>
  );
};

export const Rakka = () => {
  const t = useCurrentFrame() / FPS;
  return (
    <AbsoluteFill style={{ backgroundColor: '#e9dcc6' }}>
      <Img src={staticFile('byobu.jpg')} style={{ width: W, height: H }} />
      <Folds />
      <Mist t={t} />
      <svg width={W} height={H} viewBox={`0 0 ${W} ${H}`} style={{ position: 'absolute', inset: 0 }}>
        <PetalDefs />
        {PETALS.map((p, i) => <Ripples key={`r${i}`} p={p} t={t} />)}
        {PETALS.map((p, i) => <Petal key={`p${i}`} p={p} t={t} />)}
      </svg>
    </AbsoluteFill>
  );
};
