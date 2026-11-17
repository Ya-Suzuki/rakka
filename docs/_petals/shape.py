"""花びらの形を作り、petals.js（立体）と _layouts/landing.html（正面から見た SVG）に書き込む。

    python3 shape.py && npm run build

輪郭は Ruby のロゴに寄せる（上辺はほぼ平らで、両側は真っすぐ先端へ絞る。横に広い比率）。
桜の花びららしさは、上辺中央の浅く小さな切れ込みと、立体の反り・根元から先端への色の移ろいで出す。
表面はローポリゴンの面（宝石のカット）。
"""
import pathlib, re

HERE = pathlib.Path(__file__).parent
WIDTH, TOP, BOTTOM = 0.6, 0.54, -0.5

# 右半分の輪郭（上の切れ込み → 肩 → 先端）。左は左右反転
RIGHT = [(0, 0.45), (0.07, 0.52), (0.3, 0.54), (0.5, 0.52), (0.6, 0.42),
         (0.57, 0.24), (0.45, 0.02), (0.27, -0.25), (0, BOTTOM)]
INNER = {'A': (0, 0.22), 'B': (0, -0.12), 'SR': (0.32, 0.26), 'SL': (-0.32, 0.26)}
HALF = [('R0', 'R1', 'A'), ('R1', 'R2', 'SR'), ('R1', 'SR', 'A'), ('R2', 'R3', 'SR'),
        ('R3', 'R4', 'SR'), ('R4', 'R5', 'SR'), ('SR', 'R5', 'B'), ('R5', 'R6', 'B'),
        ('R6', 'R7', 'B'), ('R7', 'R8', 'B'), ('A', 'SR', 'B')]

points = dict(INNER)
for i, (x, y) in enumerate(RIGHT):
    points['R%d' % i] = (x, y)
    points['L%d' % i] = (-x, y)
mirror = lambda v: v if v in ('A', 'B') else ('SL' if v == 'SR' else 'L' + v[1:])
triangles = HALF + [tuple(mirror(v) for v in t) for t in HALF]


def depth(x, y):
    a = abs(x) / WIDTH
    return round(0.05 * (1 - a) - 0.2 * a * a, 4)  # 中心が少し盛り上がり、縁が後ろへ反る


def color(x, y):
    t = (y - BOTTOM) / (TOP - BOTTOM)  # 根元 0 → 先端 1
    stops = [(0.0, (0x7e, 0x10, 0x1b)), (0.55, (0xb8, 0x20, 0x2c)), (1.0, (0xe0, 0x60, 0x6b))]
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        if t <= t1:
            k = (t - t0) / (t1 - t0)
            c = [c0[i] + (c1[i] - c0[i]) * k for i in range(3)]
            break
    lift = abs(x) / WIDTH * 18  # 縁は少し明るい
    return [round(min(255, v + lift)) for v in c]


def linear(c):
    """three.js は頂点の色をリニアの値として扱うので、画面用（sRGB）の値を変換して渡す。
    変換しないと一段明るく表示され、赤がピンクに浮く"""
    c /= 255
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


pos, cols, polys = [], [], []
to_svg = lambda x, y: (round((x + WIDTH) / (2 * WIDTH) * 48, 2), round((TOP - y) / (TOP - BOTTOM) * 40, 2))
for t in triangles:
    for v in t:
        x, y = points[v]
        pos += [x, y, depth(x, y)]
        cols += [round(linear(c), 4) for c in color(x, y)]
    avg = [sum(color(*points[v])[i] for v in t) // 3 for i in range(3)]
    polys.append('        <polygon fill="#%02x%02x%02x" points="%s"/>' % (
        *avg, ' '.join('%g,%g' % to_svg(*points[v]) for v in t)))

js = HERE / 'petals.js'
src = js.read_text()
src = re.sub(r'const PETAL_POSITIONS = \[.*?\];', 'const PETAL_POSITIONS = [%s];' % ', '.join('%g' % v for v in pos), src)
src = re.sub(r'const PETAL_COLORS = \[.*?\];', 'const PETAL_COLORS = [%s];' % ', '.join('%g' % v for v in cols), src)
js.write_text(src)

layout = HERE.parent / '_layouts' / 'landing.html'
html = layout.read_text()
html = re.sub(r'(<symbol id="petal" viewBox="0 0 48 40">\n        <g[^>]*>\n).*?(\n        </g>)',
              lambda m: m.group(1) + '\n'.join(polys) + m.group(2), html, flags=re.S)
layout.write_text(html)
print('%d triangles' % len(triangles))
