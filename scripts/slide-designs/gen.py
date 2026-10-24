#!/usr/bin/env python3
"""Builds the SVG pictures (lines, waves, contours, branches, …) inside some of Presenter Studio's slide designs
and fills them into the CSS templates, so the designs stay plain CSS files.

    python3 scripts/slide-designs/gen.py [output folder, default Resources/SlideDesigns]

Every `@@NAME@@` in templates/*.css is replaced by `url("data:image/svg+xml;utf8,…")`. To look at the result as the
app draws it (WebKit), with sample text, and at a later moment of the animations:

    swift scripts/slide-designs/render.swift Resources/SlideDesigns /tmp/designs text [seconds] [name,name]
    python3 scripts/slide-designs/sheet.py /tmp/designs /tmp/sheet.png seide,wellen
"""
import math
import pathlib
import random
import re
import sys

import contourpy
import numpy as np

HERE = pathlib.Path(__file__).parent
OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent.parent / "Resources" / "SlideDesigns"
W, H = 1600, 900


# ---------------------------------------------------------------- helpers

def n(v, d=0):
    s = f"{v:.{d}f}"
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def uri(svg):
    svg = re.sub(r"\s+", " ", svg).strip().replace("> <", "><")
    svg = svg.replace("%", "%25").replace("#", "%23").replace('"', "'")
    return f'url("data:image/svg+xml;utf8,{svg}")'


def svg(body, w=W, h=H, par="xMidYMid slice", defs=""):
    d = f"<defs>{defs}</defs>" if defs else ""
    return f"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 {w} {h}' preserveAspectRatio='{par}'>{d}{body}</svg>"


def line_path(pts, closed=False, d=0):
    """M x y l dx dy … with deltas of the rounded points, so nothing drifts."""
    r = [(round(x, d), round(y, d)) for x, y in pts]
    parts = [f"M{n(r[0][0], d)} {n(r[0][1], d)}"]
    deltas = [f"{n(b[0] - a[0], d)} {n(b[1] - a[1], d)}" for a, b in zip(r, r[1:])]
    if deltas:
        parts.append("l" + " ".join(deltas))
    s = "".join(parts).replace(" -", "-")
    return s + ("z" if closed else "")


def smooth_path(pts, closed=False):
    """A smooth curve through the midpoints of the points (quadratic pieces)."""
    p = [(round(x), round(y)) for x, y in pts]
    if closed:
        p = p + p[:2]
    mid = lambda a, b: ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
    start = p[0] if not closed else mid(p[0], p[1])
    s = f"M{n(start[0])} {n(start[1])}"
    rng = range(1, len(p) - 1)
    for i in rng:
        m = mid(p[i], p[i + 1])
        s += f"Q{n(p[i][0])} {n(p[i][1])} {n(m[0])} {n(m[1])}"
    if not closed:
        s += f"L{n(p[-1][0])} {n(p[-1][1])}"
    else:
        s += "z"
    return s.replace(" -", "-")


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def lerp_color(a, b, t):
    a, b = hexrgb(a), hexrgb(b)
    return "#" + "".join(f"{round(x + (y - x) * t):02x}" for x, y in zip(a, b))


def bezier(p, t):
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = p
    u = 1 - t
    x = u**3 * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t**3 * x3
    y = u**3 * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t**3 * y3
    return x, y


def bezier_tangent(p, t):
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = p
    u = 1 - t
    dx = 3 * u * u * (x1 - x0) + 6 * u * t * (x2 - x1) + 3 * t * t * (x3 - x2)
    dy = 3 * u * u * (y1 - y0) + 6 * u * t * (y2 - y1) + 3 * t * t * (y3 - y2)
    length = math.hypot(dx, dy) or 1
    return dx / length, dy / length


def simplify(points, tolerance):
    """Douglas–Peucker."""
    pts = np.asarray(points)
    if len(pts) < 3:
        return pts
    keep = np.zeros(len(pts), bool)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        seg = pts[b] - pts[a]
        length = np.hypot(*seg)
        rel = pts[a + 1:b] - pts[a]
        if length == 0:
            dist = np.hypot(rel[:, 0], rel[:, 1])
        else:
            dist = np.abs(seg[0] * rel[:, 1] - seg[1] * rel[:, 0]) / length
        i = int(np.argmax(dist))
        if dist[i] > tolerance:
            keep[a + 1 + i] = True
            stack += [(a, a + 1 + i), (a + 1 + i, b)]
    return pts[keep]


# ---------------------------------------------------------------- Seide: silk folds

def silk(edge0, edge1, count, op_lo, op_hi, width=1.6, color="#ffffff", folds=2.5):
    paths = []
    for i in range(count):
        s = i / (count - 1)
        pts = [(a[0] + (b[0] - a[0]) * s, a[1] + (b[1] - a[1]) * s) for a, b in zip(edge0, edge1)]
        sheen = math.sin(math.pi * s) ** 1.2 * (0.55 + 0.45 * math.cos(2 * math.pi * folds * s))
        op = op_lo + (op_hi - op_lo) * sheen
        d = f"M{n(pts[0][0])} {n(pts[0][1])}C{n(pts[1][0])} {n(pts[1][1])} {n(pts[2][0])} {n(pts[2][1])} {n(pts[3][0])} {n(pts[3][1])}"
        paths.append(f"<path d='{d.replace(' -', '-')}' stroke-opacity='{n(op, 2)}'/>")
    return svg(f"<g fill='none' stroke='{color}' stroke-width='{width}' stroke-linecap='round'>{''.join(paths)}</g>")


# ---------------------------------------------------------------- Wellen: periodic wave lines

def waves(count, top, spread, amp, k, color0, color1, op0, op1, width=1.4, phase=(0.6, 2.2, 1.9, -1.4)):
    paths = []
    for i in range(count):
        s = i / (count - 1)
        y0 = top + spread * s
        a = amp * (0.35 + 0.65 * math.sin(math.pi * (0.1 + 0.8 * s)))
        ph1 = phase[0] + phase[1] * s
        ph2 = phase[2] + phase[3] * s
        pts = [(x, y0 + a * math.sin(2 * math.pi * k[0] * x / W + ph1) + 0.5 * a * math.sin(2 * math.pi * k[1] * x / W + ph2))
               for x in range(-100, W + 101, 50)]
        op = op0 + (op1 - op0) * math.sin(math.pi * s)
        paths.append(f"<path d='{smooth_path(pts)}' stroke='{lerp_color(color0, color1, s)}' stroke-opacity='{n(op, 2)}'/>")
    return svg(f"<g fill='none' stroke-width='{width}'>{''.join(paths)}</g>", par="none")


# ---------------------------------------------------------------- Höhenlinien: contour lines

def contours(bumps, levels, seed, color, width=1.1, index_width=2, op=0.5, index_op=0.8, every=5, noise=0.05, extent=(-160, -90, 1760, 990)):
    rnd = random.Random(seed)
    x0, y0, x1, y1 = extent
    xs = np.linspace(x0, x1, 241)
    ys = np.linspace(y0, y1, 136)
    X, Y = np.meshgrid(xs, ys)
    Z = np.zeros_like(X)
    for cx, cy, rx, ry, h in bumps:
        Z += h * np.exp(-(((X - cx) / rx) ** 2 + ((Y - cy) / ry) ** 2) / 2)
    for _ in range(7):
        fx, fy = rnd.uniform(0.002, 0.007), rnd.uniform(0.002, 0.007)
        Z += noise * rnd.uniform(0.5, 1) * np.sin(fx * X + rnd.uniform(0, 6.3)) * np.sin(fy * Y + rnd.uniform(0, 6.3))
    gen = contourpy.contour_generator(X, Y, Z, line_type="Separate")
    thin, thick = [], []
    for li, level in enumerate(levels):
        for line in gen.lines(level):
            pts = simplify(line, 1.4)
            if len(pts) < 3:
                continue
            closed = np.allclose(line[0], line[-1])
            d = smooth_path([tuple(p) for p in (pts[:-1] if closed else pts)], closed=closed)
            (thick if (li + 1) % every == 0 else thin).append(d)
    body = (f"<path d='{''.join(thin)}' fill='none' stroke='{color}' stroke-opacity='{op}' stroke-width='{width}' stroke-linejoin='round'/>"
            f"<path d='{''.join(thick)}' fill='none' stroke='{color}' stroke-opacity='{index_op}' stroke-width='{index_width}' stroke-linejoin='round'/>")
    return svg(body)


# ---------------------------------------------------------------- Terrazzo: stone chips

TERRAZZO = [("#d9694f", 5), ("#e8b04a", 4), ("#3f8f89", 4), ("#3c3f58", 3), ("#f0c2ae", 5), ("#b9b2a6", 6), ("#ffffff", 3)]


def chip(rnd, cx, cy, r):
    k = rnd.randint(5, 8)
    rot = rnd.uniform(0, math.tau)
    pts = []
    for i in range(k):
        a = rot + i * math.tau / k + rnd.uniform(-0.35, 0.35)
        rr = r * rnd.uniform(0.55, 1.0)
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a) * rnd.uniform(0.75, 1.0)))
    return line_path(pts, closed=True)


def terrazzo(seed, count, specks):
    rnd = random.Random(seed)
    colors = [c for c, w in TERRAZZO for _ in range(w)]
    groups = {}
    placed = []
    tries = 0
    while len(placed) < count and tries < 20000:
        tries += 1
        r = 7 + 34 * rnd.random() ** 2.6
        x, y = rnd.uniform(-20, W + 20), rnd.uniform(-20, H + 20)
        if any(math.hypot(x - px, y - py) < (r + pr) * 1.05 for px, py, pr in placed):
            continue
        placed.append((x, y, r))
        groups.setdefault(rnd.choice(colors), []).append(chip(rnd, x, y, r))
    body = "".join(f"<path fill='{c}' d='{''.join(ds)}'/>" for c, ds in groups.items())
    dots = []
    for _ in range(specks):
        x, y = rnd.uniform(0, W), rnd.uniform(0, H)
        dots.append(f"M{n(x)} {n(y)}h0")
    body += f"<path d='{''.join(dots)}' stroke='#8d857a' stroke-opacity='0.55' stroke-width='3.2' stroke-linecap='round'/>"
    return svg(body)


def big_chip(seed, color, shade):
    rnd = random.Random(seed)
    d = chip(rnd, 50, 50, 48)
    body = (f"<defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'><stop offset='0' stop-color='{color}'/><stop offset='1' stop-color='{shade}'/></linearGradient></defs>"
            f"<path d='{d}' fill='url(#g)'/>")
    return f"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'>{body}</svg>"


# ---------------------------------------------------------------- Botanik: branches

def branch(stem, leaves, length, width, rnd, start=0.06, angle=48, sizes=(1.0, 0.45), berries=0):
    out_leaves, out_ribs = [], []
    for i in range(leaves):
        t = start + (1 - start) * (i / max(leaves - 1, 1)) ** 0.92
        t = min(t, 0.985)
        px, py = bezier(stem, t)
        tx, ty = bezier_tangent(stem, t)
        side = 1 if i % 2 == 0 else -1
        a = math.radians(angle * rnd.uniform(0.8, 1.15)) * side
        dx = tx * math.cos(a) - ty * math.sin(a)
        dy = tx * math.sin(a) + ty * math.cos(a)
        size = sizes[0] + (sizes[1] - sizes[0]) * t
        L = length * size * rnd.uniform(0.85, 1.1)
        Wl = width * size * rnd.uniform(0.85, 1.1)
        bx, by = px + dx * 6, py + dy * 6
        ex, ey = bx + dx * L, by + dy * L
        mx, my = bx + dx * L * 0.42, by + dy * L * 0.42
        nx, ny = -dy, dx
        c1 = (mx + nx * Wl, my + ny * Wl)
        c2 = (mx - nx * Wl, my - ny * Wl)
        out_leaves.append(f"M{n(bx)} {n(by)}Q{n(c1[0])} {n(c1[1])} {n(ex)} {n(ey)}Q{n(c2[0])} {n(c2[1])} {n(bx)} {n(by)}z")
        out_ribs.append(f"M{n(px)} {n(py)}L{n(bx + dx * L * 0.8)} {n(by + dy * L * 0.8)}")
    tip = bezier(stem, 1)
    tdx, tdy = bezier_tangent(stem, 1)
    L = length * sizes[1] * 1.1
    bx, by = tip
    ex, ey = bx + tdx * L, by + tdy * L
    mx, my = bx + tdx * L * 0.42, by + tdy * L * 0.42
    Wl = width * sizes[1]
    out_leaves.append(f"M{n(bx)} {n(by)}Q{n(mx - tdy * Wl)} {n(my + tdx * Wl)} {n(ex)} {n(ey)}Q{n(mx + tdy * Wl)} {n(my - tdx * Wl)} {n(bx)} {n(by)}z")
    out_ribs.append(f"M{n(bx)} {n(by)}L{n(bx + tdx * L * 0.8)} {n(by + tdy * L * 0.8)}")
    dots = []
    for j in range(berries):
        t = 0.3 + 0.55 * j / max(berries - 1, 1)
        px, py = bezier(stem, t)
        tx, ty = bezier_tangent(stem, t)
        side = -1 if j % 2 == 0 else 1
        dots.append((px - ty * 22 * side, py + tx * 22 * side))
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = stem
    stem_d = f"M{n(x0)} {n(y0)}C{n(x1)} {n(y1)} {n(x2)} {n(y2)} {n(x3)} {n(y3)}"
    return stem_d, "".join(out_leaves), "".join(out_ribs), dots


def botanik(branches, seed):
    rnd = random.Random(seed)
    stems, leaves, ribs, dots = [], [], [], []
    for spec in branches:
        s, l, r, d = branch(rnd=rnd, **spec)
        stems.append(s)
        leaves.append(l)
        ribs.append(r)
        dots += d
    body = (f"<path d='{''.join(leaves)}' fill='#a9bea2' fill-opacity='0.62' stroke='#5c7a5e' stroke-width='2' stroke-linejoin='round'/>"
            f"<path d='{''.join(ribs)}' fill='none' stroke='#5c7a5e' stroke-opacity='0.8' stroke-width='1.4' stroke-linecap='round'/>"
            f"<path d='{''.join(stems)}' fill='none' stroke='#5c7a5e' stroke-width='3' stroke-linecap='round'/>")
    if dots:
        body += "<g fill='#c98466'>" + "".join(f"<circle cx='{n(x)}' cy='{n(y)}' r='{n(rnd.uniform(6, 9))}'/>" for x, y in dots) + "</g>"
    return svg(body)


# ---------------------------------------------------------------- Tusche: ink wash

def ridge(rnd, base, rough, x0=-40, x1=W + 40, steps=7):
    pts = [(x0, base + rnd.uniform(-rough, rough)), (x1, base + rnd.uniform(-rough, rough))]
    r = rough
    for _ in range(steps):
        nxt = [pts[0]]
        for a, b in zip(pts, pts[1:]):
            mx = (a[0] + b[0]) / 2
            my = (a[1] + b[1]) / 2 + rnd.uniform(-r, r)
            nxt += [(mx, my), b]
        pts = nxt
        r *= 0.55
    return pts


def mountains(layers, seed):
    rnd = random.Random(seed)
    defs = []
    body = []
    for i, (base, rough, ink, op, blur) in enumerate(layers):
        pts = ridge(rnd, base, rough)
        top = min(y for _, y in pts)
        defs.append(f"<linearGradient id='m{i}' gradientUnits='userSpaceOnUse' x1='0' y1='{n(top)}' x2='0' y2='{H}'>"
                    f"<stop offset='0' stop-color='{ink}' stop-opacity='{op}'/><stop offset='0.45' stop-color='{ink}' stop-opacity='{n(op * 0.35, 2)}'/>"
                    f"<stop offset='1' stop-color='{ink}' stop-opacity='0'/></linearGradient>")
        if blur:
            defs.append(f"<filter id='b{i}' x='-5%' y='-20%' width='110%' height='140%'><feGaussianBlur stdDeviation='{blur}'/></filter>")
        d = line_path(simplify(pts, 0.6).tolist() + [(W + 40, H + 20), (-40, H + 20)], closed=True)
        body.append(f"<path d='{d}' fill='url(#m{i})'{f' filter=\'url(#b{i})\'' if blur else ''}/>")
    return svg("".join(body), defs="".join(defs))


def enso(seed, ink="#1b1b1b", gap=38, start=-62, wmax=46, r=300):
    """A brush circle: a stroke that swells and thins, with a rough edge and dry-brush streaks."""
    rnd = random.Random(seed)
    cx = cy = 400
    sweep = 360 - gap
    outer, inner = [], []
    steps = 160
    wobble = [rnd.uniform(-1, 1) for _ in range(8)]
    for i in range(steps + 1):
        s = i / steps
        a = math.radians(start + sweep * s)
        w = wmax * (math.sin(math.pi * min(1, s * 1.15)) ** 0.55 if s < 0.87 else max(0.06, (1 - s) / 0.13) ** 0.8 * 0.72)
        w = max(w, 3) * (1 + 0.08 * math.sin(s * 23))
        rr = r * (1 + 0.012 * sum(wb * math.sin((k + 1) * a) for k, wb in enumerate(wobble)))
        outer.append((cx + (rr + w / 2) * math.cos(a), cy + (rr + w / 2) * math.sin(a)))
        inner.append((cx + (rr - w / 2) * math.cos(a), cy + (rr - w / 2) * math.sin(a)))
    shape = line_path(outer + inner[::-1], closed=True)
    streaks = []
    for _ in range(9):
        off = rnd.uniform(-wmax * 0.38, wmax * 0.38)
        a0 = start + rnd.uniform(10, 120)
        a1 = a0 + rnd.uniform(60, 190)
        rr = r + off
        p0 = (cx + rr * math.cos(math.radians(a0)), cy + rr * math.sin(math.radians(a0)))
        p1 = (cx + rr * math.cos(math.radians(a1)), cy + rr * math.sin(math.radians(a1)))
        large = 1 if a1 - a0 > 180 else 0
        streaks.append(f"M{n(p0[0])} {n(p0[1])}A{n(rr)} {n(rr)} 0 {large} 1 {n(p1[0])} {n(p1[1])}")
    defs = ("<filter id='r' x='-10%' y='-10%' width='120%' height='120%'><feTurbulence type='fractalNoise' baseFrequency='0.035' numOctaves='3' seed='4'/>"
            "<feDisplacementMap in='SourceGraphic' scale='9'/></filter>"
            f"<clipPath id='c'><path d='{shape}'/></clipPath>")
    body = (f"<g filter='url(#r)'><path d='{shape}' fill='{ink}'/>"
            f"<path d='{''.join(streaks)}' clip-path='url(#c)' fill='none' stroke='#f4efe4' stroke-opacity='0.32' stroke-width='2.2'/></g>")
    return f"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 800 800'><defs>{defs}</defs>{body}</svg>"


def seal(seed):
    return ("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><defs><filter id='r'><feTurbulence type='fractalNoise' baseFrequency='0.09' numOctaves='2' seed='7'/>"
            "<feDisplacementMap in='SourceGraphic' scale='4'/></filter></defs><g filter='url(#r)'>"
            "<rect x='8' y='8' width='84' height='84' rx='6' fill='#b8322a'/>"
            "<rect x='18' y='18' width='64' height='64' rx='2' fill='none' stroke='#f4efe4' stroke-opacity='0.75' stroke-width='3'/></g></svg>")


# ---------------------------------------------------------------- Art déco: fans

GOLD = ("<linearGradient id='g' gradientUnits='userSpaceOnUse' x1='0' y1='0' x2='1600' y2='900'>"
        "<stop offset='0' stop-color='#f1d99a'/><stop offset='0.5' stop-color='#d4ad62'/><stop offset='1' stop-color='#a07a3a'/></linearGradient>")


def fan(cx, cy, a0, a1, radii, rays, ray_from, core=None, width=2.2, op=0.85):
    parts = []
    for r in radii:
        p0 = (cx + r * math.cos(math.radians(a0)), cy + r * math.sin(math.radians(a0)))
        p1 = (cx + r * math.cos(math.radians(a1)), cy + r * math.sin(math.radians(a1)))
        large = 1 if a1 - a0 > 180 else 0
        parts.append(f"M{n(p0[0])} {n(p0[1])}A{n(r)} {n(r)} 0 {large} 1 {n(p1[0])} {n(p1[1])}")
    r_out = radii[-1]
    for i in range(rays + 1 if rays else 0):
        a = math.radians(a0 + (a1 - a0) * i / rays)
        r_in = ray_from[i % len(ray_from)]
        parts.append(f"M{n(cx + r_in * math.cos(a))} {n(cy + r_in * math.sin(a))}L{n(cx + r_out * math.cos(a))} {n(cy + r_out * math.sin(a))}")
    out = f"<path d='{''.join(parts).replace(' -', '-')}' fill='none' stroke='url(#g)' stroke-opacity='{op}' stroke-width='{width}'/>"
    if core:
        p0 = (cx + core * math.cos(math.radians(a0)), cy + core * math.sin(math.radians(a0)))
        p1 = (cx + core * math.cos(math.radians(a1)), cy + core * math.sin(math.radians(a1)))
        large = 1 if a1 - a0 > 180 else 0
        out += f"<path d='M{n(cx)} {n(cy)}L{n(p0[0])} {n(p0[1])}A{n(core)} {n(core)} 0 {large} 1 {n(p1[0])} {n(p1[1])}z' fill='url(#g)' fill-opacity='0.9'/>"
    return out


# ---------------------------------------------------------------- Orbit: stars

def stars(seed, count, op=(0.35, 1.0)):
    rnd = random.Random(seed)
    groups = {}
    for _ in range(count):
        x, y = rnd.uniform(0, W), rnd.uniform(0, H)
        size = rnd.choice([1.4, 1.4, 1.8, 1.8, 2.4, 3.2])
        alpha = round(rnd.uniform(*op), 1)
        groups.setdefault((size, alpha), []).append(f"M{n(x)} {n(y)}h0")
    body = "".join(f"<path d='{''.join(ds)}' stroke='#ffffff' stroke-opacity='{a}' stroke-width='{s}' stroke-linecap='round'/>" for (s, a), ds in groups.items())
    return svg(body)


# ---------------------------------------------------------------- Pastell: drifting threads

def threads(curves, color="#ffffff", width=2, op=0.75):
    d = "".join(f"M{n(c[0][0])} {n(c[0][1])}C{n(c[1][0])} {n(c[1][1])} {n(c[2][0])} {n(c[2][1])} {n(c[3][0])} {n(c[3][1])}" for c in curves)
    return svg(f"<path d='{d.replace(' -', '-')}' fill='none' stroke='{color}' stroke-opacity='{op}' stroke-width='{width}' stroke-linecap='round'/>")


# ---------------------------------------------------------------- the pictures

PICTURES = {}

# Seide
PICTURES["SEIDE_TITEL_A"] = silk([(-100, 860), (520, 990), (880, 330), (1700, 420)], [(-100, 560), (640, 720), (1000, 90), (1700, 120)], 34, 0.06, 0.7)
PICTURES["SEIDE_TITEL_B"] = silk([(-100, 1000), (420, 780), (1100, 1040), (1700, 700)], [(-100, 900), (520, 640), (1220, 880), (1700, 520)], 26, 0.05, 0.5, folds=1.5)
PICTURES["SEIDE_KAPITEL_A"] = silk([(980, -100), (1560, 280), (860, 620), (1480, 1000)], [(1380, -100), (1800, 360), (1260, 660), (1780, 1000)], 32, 0.06, 0.7)
PICTURES["SEIDE_KAPITEL_B"] = silk([(1700, 80), (1200, 380), (1500, 760), (900, 1000)], [(1700, 300), (1400, 520), (1640, 840), (1250, 1000)], 22, 0.05, 0.48, folds=1.5)
PICTURES["SEIDE_FOLIE_A"] = silk([(-100, 960), (520, 830), (1100, 990), (1700, 780)], [(-100, 900), (620, 760), (1200, 900), (1700, 640)], 26, 0.05, 0.5)
PICTURES["SEIDE_FOLIE_B"] = silk([(1200, 1000), (1420, 700), (1500, 420), (1700, 200)], [(1450, 1000), (1600, 760), (1650, 520), (1750, 330)], 16, 0.04, 0.36, folds=1.5)

# Wellen
PICTURES["WELLEN_A"] = waves(26, 600, 170, 46, (1, 2), "#5ee1ff", "#7c8cff", 0.18, 0.62)
PICTURES["WELLEN_B"] = waves(20, 690, 150, 60, (2, 3), "#3aa6ff", "#b48cff", 0.1, 0.38, width=1.2, phase=(2.4, -1.6, 0.3, 2.0))
PICTURES["WELLEN_OBEN"] = waves(14, 70, 90, 28, (1, 3), "#7c8cff", "#5ee1ff", 0.06, 0.26, width=1.1, phase=(4.0, 1.2, 1.0, -0.8))

# Höhenlinien
LEVELS = [0.06 + 0.055 * i for i in range(24)]
PICTURES["HOEHEN_TITEL"] = contours([(260, 780, 300, 230, 1.0), (1380, 160, 330, 240, 1.15), (1480, 800, 170, 140, 0.55), (120, 90, 150, 120, 0.45), (780, 1060, 260, 120, 0.4)], LEVELS, 3, "#7b5f43")
PICTURES["HOEHEN_KAPITEL"] = contours([(1320, 440, 300, 330, 1.25), (1560, 60, 200, 160, 0.6), (1080, 900, 220, 150, 0.55), (1700, 820, 160, 160, 0.5)], LEVELS, 11, "#7b5f43")
PICTURES["HOEHEN_FOLIE"] = contours([(1640, 930, 330, 260, 1.0), (1700, 340, 190, 200, 0.55), (1200, 1040, 200, 110, 0.4)], LEVELS, 5, "#7b5f43", op=0.42, index_op=0.65)

# Terrazzo
PICTURES["TERRAZZO"] = terrazzo(8, 230, 380)
PICTURES["TERRAZZO_KORALLE"] = big_chip(2, "#e07a5f", "#c4583d")
PICTURES["TERRAZZO_PETROL"] = big_chip(5, "#4a9a93", "#2f7570")
PICTURES["TERRAZZO_OCKER"] = big_chip(9, "#efbd5a", "#d99a2f")

# Botanik
PICTURES["BOTANIK_TITEL"] = botanik([
    dict(stem=[(-30, 960), (120, 820), (260, 760), (470, 560)], leaves=13, length=118, width=30, angle=46, berries=3),
    dict(stem=[(60, 980), (180, 900), (330, 900), (560, 820)], leaves=9, length=84, width=22, angle=52),
    dict(stem=[(1650, -40), (1520, 60), (1440, 130), (1270, 280)], leaves=11, length=110, width=28, angle=46, berries=2),
], 4)
PICTURES["BOTANIK_KAPITEL"] = botanik([
    dict(stem=[(1700, 990), (1420, 760), (1500, 380), (1250, 70)], leaves=17, length=150, width=38, angle=46, berries=4),
    dict(stem=[(1640, 960), (1560, 820), (1600, 640), (1720, 520)], leaves=8, length=96, width=26, angle=50),
], 7)
PICTURES["BOTANIK_FOLIE"] = botanik([
    dict(stem=[(1660, 940), (1560, 860), (1500, 790), (1380, 690)], leaves=9, length=74, width=19, angle=48, berries=2),
    dict(stem=[(1620, 960), (1560, 930), (1480, 930), (1400, 900)], leaves=6, length=56, width=15, angle=54),
], 9)

# Tusche
PICTURES["TUSCHE_BERGE"] = mountains([(660, 110, "#4a4a4a", 0.3, 3), (750, 80, "#333333", 0.42, 1.5), (840, 60, "#1e1e1e", 0.58, 0)], 12)
PICTURES["TUSCHE_ENSO"] = enso(3)
PICTURES["TUSCHE_SIEGEL"] = seal(1)

# Art déco
PICTURES["DECO_TITEL"] = svg(
    fan(800, 900, 180, 360, [70, 120, 180, 235, 290], 28, [80, 130, 80, 190]) + fan(800, 900, 180, 360, [44], 0, [0], core=44)
    + fan(0, 0, 0, 90, [60, 100, 140, 168], 8, [70, 110]) + fan(1600, 0, 90, 180, [60, 100, 140, 168], 8, [70, 110])
    + fan(0, 900, 270, 360, [60, 100, 140, 168], 8, [70, 110]) + fan(1600, 900, 180, 270, [60, 100, 140, 168], 8, [70, 110]),
    defs=GOLD)
PICTURES["DECO_KAPITEL"] = svg(
    fan(1600, 450, 90, 270, [110, 200, 300, 410, 520], 34, [130, 210, 130, 310]) + fan(1600, 450, 90, 270, [70], 0, [0], core=70)
    + fan(0, 0, 0, 90, [60, 100, 140], 6, [70]) + fan(0, 900, 270, 360, [60, 100, 140], 6, [70]),
    defs=GOLD)
PICTURES["DECO_FOLIE"] = svg(fan(1600, 900, 180, 270, [70, 130, 190, 240], 10, [80, 140]) + fan(1600, 900, 180, 270, [44], 0, [0], core=44), defs=GOLD)

# Orbit
PICTURES["ORBIT_STERNE"] = stars(21, 150)
PICTURES["ORBIT_STERNE_B"] = stars(34, 70, op=(0.5, 1.0))

# Pastell
PICTURES["PASTELL_FAEDEN"] = threads([
    [(-100, 720), (420, 560), (900, 980), (1700, 640)],
    [(-100, 760), (480, 610), (940, 1010), (1700, 690)],
    [(-100, 170), (500, 30), (1000, 330), (1700, 120)],
])
PICTURES["PASTELL_FAEDEN_KAPITEL"] = threads([
    [(1000, 1000), (1300, 700), (1100, 300), (1500, -100)],
    [(1060, 1000), (1360, 720), (1170, 300), (1570, -100)],
])
PICTURES["PASTELL_FAEDEN_FOLIE"] = threads([
    [(-100, 880), (500, 800), (1000, 960), (1700, 760)],
    [(-100, 910), (520, 840), (1020, 990), (1700, 800)],
], op=0.85)

# Graphit: folded planes with copper edges
COPPER = ("<linearGradient id='k' gradientUnits='userSpaceOnUse' x1='0' y1='0' x2='1600' y2='900'><stop offset='0' stop-color='#f2b48a'/><stop offset='0.55' stop-color='#d0814f'/><stop offset='1' stop-color='#8f4f2c'/></linearGradient>"
          "<linearGradient id='p' x1='0' y1='0' x2='1' y2='1'><stop offset='0' stop-color='#3a3e45'/><stop offset='1' stop-color='#22252a'/></linearGradient>"
          "<linearGradient id='q' x1='1' y1='0' x2='0' y2='1'><stop offset='0' stop-color='#2d3036'/><stop offset='1' stop-color='#17181c'/></linearGradient>")


def planes(polys, edges, fine=()):
    out = []
    for pts, fill, op in polys:
        out.append(f"<path d='{line_path(pts, closed=True)}' fill='url(#{fill})' fill-opacity='{op}'/>")
    for (a, b, w, op) in edges:
        out.append(f"<path d='M{n(a[0])} {n(a[1])}L{n(b[0])} {n(b[1])}' stroke='url(#k)' stroke-width='{w}' stroke-opacity='{op}'/>")
    for (a, b) in fine:
        out.append(f"<path d='M{n(a[0])} {n(a[1])}L{n(b[0])} {n(b[1])}' stroke='#ffffff' stroke-opacity='0.12' stroke-width='1.2'/>")
    return svg("".join(out), defs=COPPER)


PICTURES["GRAPHIT_TITEL"] = planes(
    [([(1020, -10), (1610, -10), (1610, 560)], "p", 0.95), ([(1260, -10), (1610, -10), (1610, 300)], "q", 0.9),
     ([(-10, 600), (-10, 910), (560, 910)], "p", 0.9), ([(-10, 760), (-10, 910), (260, 910)], "q", 0.95)],
    [((1020, -10), (1610, 560), 3, 0.95), ((1260, -10), (1610, 300), 1.6, 0.6), ((-10, 600), (560, 910), 3, 0.95)],
    [((960, -10), (1610, 620)), ((-10, 540), (620, 910))])
PICTURES["GRAPHIT_KAPITEL"] = planes(
    [([(1140, -10), (1610, -10), (1610, 910), (1380, 910)], "p", 0.95), ([(1330, -10), (1610, -10), (1610, 520)], "q", 0.9),
     ([(1480, 910), (1610, 640), (1610, 910)], "q", 0.95)],
    [((1140, -10), (1380, 910), 3, 0.95), ((1330, -10), (1610, 520), 1.6, 0.6)],
    [((1080, -10), (1320, 910))])
PICTURES["GRAPHIT_FOLIE"] = planes(
    [([(1310, 910), (1610, 600), (1610, 910)], "p", 0.95), ([(1470, 910), (1610, 760), (1610, 910)], "q", 0.95)],
    [((1310, 910), (1610, 600), 2.4, 0.9)],
    [((1250, 910), (1610, 540))])


# ---------------------------------------------------------------- shared bits

def noise(freq, octaves, matrix, size=300, kind="fractalNoise"):
    return (f"<svg xmlns='http://www.w3.org/2000/svg' width='{size}' height='{size}'><filter id='n'><feTurbulence type='{kind}' baseFrequency='{freq}' numOctaves='{octaves}' stitchTiles='stitch'/>"
            f"<feColorMatrix values='{matrix}'/></filter><rect width='100%' height='100%' filter='url(#n)'/></svg>")


def trail(curve, color="#2f7f7a"):
    (a, b, c, d) = curve
    path = f"M{n(a[0])} {n(a[1])}C{n(b[0])} {n(b[1])} {n(c[0])} {n(c[1])} {n(d[0])} {n(d[1])}"
    return svg(f"<path d='{path}' fill='none' stroke='{color}' stroke-opacity='0.8' stroke-width='3.2' stroke-dasharray='12 10' stroke-linecap='round'/>"
               f"<circle cx='{n(a[0])}' cy='{n(a[1])}' r='6' fill='{color}'/>"
               f"<circle cx='{n(d[0])}' cy='{n(d[1])}' r='12' fill='none' stroke='{color}' stroke-width='3.2'/><circle cx='{n(d[0])}' cy='{n(d[1])}' r='4.5' fill='{color}'/>")


def orbit_arc(part, stroke, moon=None, ratio=0.3, color="#ffd9b0", op=0.5):
    """Half an orbit seen from the side (back: the upper half, front: the lower), in a 1000 × 1000 box."""
    rx, ry = 496, 496 * ratio
    if part == "back":
        d = f"M4 500A{rx} {n(ry)} 0 0 1 996 500"
    elif part == "front":
        d = f"M996 500A{rx} {n(ry)} 0 0 1 4 500"
    else:
        d = f"M4 500A{rx} {n(ry)} 0 0 1 996 500A{rx} {n(ry)} 0 0 1 4 500"
    body = f"<path d='{d}' fill='none' stroke='{color}' stroke-opacity='{op}' stroke-width='{stroke}'/>"
    if moon is not None:
        a = math.radians(moon)
        body += f"<circle cx='{n(500 + rx * math.cos(a))}' cy='{n(500 + ry * math.sin(a))}' r='{n(stroke * 3.2, 1)}' fill='#fff1dc'/>"
    return f"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1000 1000'>{body}</svg>"


PICTURES["NOISE_GRAIN"] = noise("0.85", 3, "0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 0.5 0")
PICTURES["NOISE_PAPIER"] = noise("0.7", 4, "0 0 0 0 0.35 0 0 0 0 0.27 0 0 0 0 0.18 0 0 0 0.9 -0.3", 320)
PICTURES["NOISE_STEIN"] = noise("0.9", 3, "0 0 0 0 0.3 0 0 0 0 0.27 0 0 0 0 0.24 0 0 0 0.7 -0.25", 260)
PICTURES["NOISE_FASER"] = noise("0.006 0.11", 3, "0 0 0 0 0.42 0 0 0 0 0.36 0 0 0 0 0.27 0 0 0 1.1 -0.45", 420)
PICTURES["HOEHEN_WEG_TITEL"] = trail([(96, 868), (210, 800), (196, 700), (300, 640)])
PICTURES["HOEHEN_WEG_KAPITEL"] = trail([(1130, 890), (1190, 740), (1380, 650), (1322, 448)])
PICTURES["ORBIT_1_HINTEN"] = orbit_arc("back", 3.6)
PICTURES["ORBIT_1_VORNE"] = orbit_arc("front", 3.6, moon=38)
PICTURES["ORBIT_2_HINTEN"] = orbit_arc("back", 2.4, moon=232)
PICTURES["ORBIT_2_VORNE"] = orbit_arc("front", 2.4)
PICTURES["ORBIT_3"] = orbit_arc("whole", 1.7, moon=158, op=0.34)


# ---------------------------------------------------------------- fill the templates

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for template in sorted((HERE / "templates").glob("*.css")):
        css = template.read_text()
        for key in set(re.findall(r"@@([A-Z0-9_]+)@@", css)):
            if key not in PICTURES:
                sys.exit(f"{template.name}: unknown picture {key}")
            css = css.replace(f"@@{key}@@", uri(PICTURES[key]))
        (OUT / template.name).write_text(css)
        print(f"{template.name}: {len(css) / 1024:.1f} KB")


if __name__ == "__main__":
    main()
