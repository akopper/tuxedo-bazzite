#!/usr/bin/env python3
"""Kumiko Deco wallpaper generator.

Ink wall, brass arches and kikko background lattice. The default motif is an
asanoha medallion with long radiating rays; asanoha, kagome and a hybrid of
the two are also available. Motif lines are cream, brass arcs stay brass.
"""
import argparse
import math

W, H = 3840, 2160
BG_TOP = "#1a2027"
BG_BOT = "#0a0d11"
INK = "#07090c"
GLOW_COOL = "#2c343f"
GLOW_WARM = "#6b5327"

PALETTES = {
    "brass": {
        "dark": "#5b4620",
        "mid": "#c09a58",
        "light": "#ecd7a4",
        "lattice": "#e8e2d8",
        "lattice_dark": "#8a7f6d",
        "kikko": "#c09a58",
    },
    "cream": {
        "dark": "#6f6658",
        "mid": "#e8e2d8",
        "light": "#fbf7f0",
        "lattice": "#e8e2d8",
        "lattice_dark": "#8a7f6d",
        "kikko": "#e8e2d8",
    },
}

TW, TH = 640, H
CX = TW / 2


def hex_path(cx, cy, r):
    pts = [(cx + r * math.cos(math.radians(60 * k)),
            cy + r * math.sin(math.radians(60 * k))) for k in range(6)]
    return "M " + " L ".join(f"{x:.2f} {y:.2f}" for x, y in pts) + " Z"


def arch_path(cx, w, top, bottom, flat=0.86):
    ry = w * flat
    cy = top + ry
    return (f"M {cx - w:.2f} {bottom:.2f} L {cx - w:.2f} {cy:.2f} "
            f"A {w:.2f} {ry:.2f} 0 0 1 {cx + w:.2f} {cy:.2f} "
            f"L {cx + w:.2f} {bottom:.2f}")


def kagome(cx, cy, size, top, bottom):
    h = size * math.sqrt(3) / 2.0
    parts = []
    k = -4
    while cx + k * h <= 2 * cx + 10:
        x = cx + k * h
        parts.append(f"M {x:.2f} {top:.2f} L {x:.2f} {bottom:.2f}")
        k += 1
    root = math.sqrt(3)
    k = -12
    while k <= 12:
        c = cy + k * 2 * h
        parts.append(f"M {-200:.2f} {root * (-200 - cx) + c:.2f} "
                     f"L {640 + 200:.2f} {root * (640 + 200 - cx) + c:.2f}")
        parts.append(f"M {-200:.2f} {-root * (-200 - cx) + c:.2f} "
                     f"L {640 + 200:.2f} {-root * (640 + 200 - cx) + c:.2f}")
        k += 1
    return " ".join(parts)


def asanoha_geometry(r, ox=0.0, oy=0.0):
    """Return (spokes, hexagon edges) for a continuous asanoha lattice."""
    spokes, edges = [], []
    dx = 1.5 * r
    dy = math.sqrt(3) * r
    for i in range(-1, 4):
        for j in range(-1, 4):
            x = ox + i * dx
            y = oy + (j + (i % 2) * 0.5) * dy
            pts = [(x + r * math.cos(math.radians(60 * k)),
                    y + r * math.sin(math.radians(60 * k))) for k in range(6)]
            for px, py in pts:
                spokes.append(f"M {x:.2f} {y:.2f} L {px:.2f} {py:.2f}")
            edges.append("M " + " L ".join(f"{px:.2f} {py:.2f}" for px, py in pts) + " Z")
    return " ".join(spokes), " ".join(edges)


def medallion_paths(cx, cy, r, ray_r):
    """Star-like asanoha medallion with long radiating rays."""
    parts = []
    pts = [(cx + r * math.cos(math.radians(60 * k)),
            cy + r * math.sin(math.radians(60 * k))) for k in range(6)]
    parts.append("M " + " L ".join(f"{x:.2f} {y:.2f}" for x, y in pts) + " Z")
    for k, (px, py) in enumerate(pts):
        a = math.radians(60 * k)
        # spoke to the vertex, then a thin ray continuing outward
        parts.append(f"M {cx:.2f} {cy:.2f} L {px:.2f} {py:.2f}")
        parts.append(f"M {px:.2f} {py:.2f} "
                     f"L {cx + ray_r * math.cos(a):.2f} {cy + ray_r * math.sin(a):.2f}")
    # inner hexagon gives the medallion a little depth
    parts.append(hex_path(cx, cy, r * 0.34))
    return " ".join(parts)


def build(motif, palette):
    p = PALETTES[palette]
    gold_dark, gold, gold_light = p["dark"], p["mid"], p["light"]
    lat, lat_dark, kikko = p["lattice"], p["lattice_dark"], p["kikko"]

    out = []
    add = out.append
    add(f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0.3" y2="1">
      <stop offset="0" stop-color="{BG_TOP}"/>
      <stop offset="0.5" stop-color="#12171d"/>
      <stop offset="1" stop-color="{BG_BOT}"/>
    </linearGradient>
    <radialGradient id="cool" cx="0.5" cy="0.16" r="0.7">
      <stop offset="0" stop-color="{GLOW_COOL}" stop-opacity="0.5"/>
      <stop offset="0.55" stop-color="{GLOW_COOL}" stop-opacity="0.12"/>
      <stop offset="1" stop-color="{GLOW_COOL}" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="warm" cx="0.28" cy="0.10" r="0.5">
      <stop offset="0" stop-color="{GLOW_WARM}" stop-opacity="0.26"/>
      <stop offset="0.5" stop-color="{GLOW_WARM}" stop-opacity="0.07"/>
      <stop offset="1" stop-color="{GLOW_WARM}" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="vig" cx="0.5" cy="0.45" r="0.78">
      <stop offset="0.48" stop-color="{INK}" stop-opacity="0"/>
      <stop offset="0.8" stop-color="{INK}" stop-opacity="0.26"/>
      <stop offset="1" stop-color="#04060a" stop-opacity="0.6"/>
    </radialGradient>
    <filter id="bloom" x="-5%" y="-5%" width="110%" height="110%">
      <feGaussianBlur stdDeviation="7"/>
    </filter>
''')

    # kikko background lattice
    R = 96
    th = math.sqrt(3) * R
    gw, gh = 3 * R, th
    add(f'    <pattern id="kikko" width="{gw:.3f}" height="{gh:.3f}" patternUnits="userSpaceOnUse">')
    for cx, cy in [(0, 0), (gw, 0), (1.5 * R, gh / 2), (0, gh), (gw, gh)]:
        add(f'      <path d="{hex_path(cx, cy, R)}" fill="none" stroke="{kikko}" '
            f'stroke-width="1.5" stroke-opacity="0.10"/>')
    add('    </pattern>')

    layers = [(278, 210), (246, 250), (214, 290)]
    inner_w, inner_top = layers[-1]
    inner_arc_cy = inner_top + inner_w * 0.86

    panel_w, panel_top = 196, 312

    motif_paths = []

    def emit(d, role):
        motif_paths.append((d, role))

    emit(f"M 0 0 L 0 {TH} M {TW} 0 L {TW} {TH}", "seam")
    for w, top in layers:
        emit(arch_path(CX, w, top, TH), "arch")
    emit(f"M {CX} {inner_arc_cy:.2f} L {CX} {TH}", "mullion")
    for k in range(-4, 5):
        t = math.radians(90 + k * 17)
        x2 = CX + inner_w * math.cos(t)
        y2 = inner_arc_cy + inner_w * 0.86 * math.sin(t)
        emit(f"M {CX} {inner_arc_cy:.2f} L {x2:.2f} {y2:.2f}", "fan")
    emit(arch_path(CX, panel_w, panel_top, TH), "innerframe")

    styles = {
        "seam": (7.0, 2.0, 0.0, 0.50),
        "arch": (8.5, 2.8, 1.0, 0.95),
        "mullion": (5.5, 1.9, 0.8, 0.80),
        "fan": (0.0, 1.2, 0.0, 0.24),
        "innerframe": (4.0, 1.3, 0.0, 0.55),
    }

    # --- motif fills, all masked to the arch panels -----------------------
    ar = 84.0
    spoke_d, edge_d = asanoha_geometry(ar)
    period_w = 3 * ar
    period_h = math.sqrt(3) * ar

    add(f'    <pattern id="asanoha" width="{period_w:.3f}" height="{period_h:.3f}" '
        f'patternUnits="userSpaceOnUse" patternTransform="translate({CX} {inner_arc_cy:.2f})">')
    add(f'      <path d="{spoke_d}" fill="none" stroke="{lat}" stroke-width="1.25" stroke-opacity="0.24"/>')
    add(f'      <path d="{edge_d}" fill="none" stroke="{lat}" stroke-width="0.9" stroke-opacity="0.10"/>')
    add('    </pattern>')

    add(f'    <pattern id="kagome" width="{TW}" height="{TH}" patternUnits="userSpaceOnUse">')
    add(f'      <path d="{kagome(CX, inner_arc_cy + 160, 168, inner_arc_cy, TH)}" '
        f'fill="none" stroke="{lat}" stroke-width="1.15" stroke-opacity="0.22"/>')
    add('    </pattern>')

    # medallions: big under the arch, then two smaller down the panel
    add(f'    <pattern id="medallion" width="{TW}" height="{TH}" patternUnits="userSpaceOnUse">')
    for cy, rr, ray in ((inner_arc_cy + 250, 150, 305),
                        (inner_arc_cy + 980, 112, 235),
                        (inner_arc_cy + 1620, 84, 175)):
        add(f'      <path d="{medallion_paths(CX, cy, rr, ray)}" fill="none" '
            f'stroke="{lat}" stroke-width="1.35" stroke-opacity="0.24"/>')
        add(f'      <path d="{hex_path(CX, cy, rr)}" fill="none" '
            f'stroke="{lat}" stroke-width="2.2" stroke-opacity="0.10"/>')
    add('    </pattern>')

    hybrid_split = inner_arc_cy + 760
    add(f'    <pattern id="kagome-hybrid" width="{TW}" height="{TH}" patternUnits="userSpaceOnUse">')
    add(f'      <path d="{kagome(CX, hybrid_split + 160, 168, hybrid_split, TH)}" '
        f'fill="none" stroke="{lat}" stroke-width="1.15" stroke-opacity="0.22"/>')
    add(f'      <path d="M 0 {hybrid_split:.2f} L {TW} {hybrid_split:.2f}" '
        f'fill="none" stroke="{lat}" stroke-width="1.6" stroke-opacity="0.34"/>')
    add('    </pattern>')

    # --- one mask for the whole wall --------------------------------------
    add('    <mask id="panel-mask">')
    add(f'      <rect width="{W}" height="{H}" fill="black"/>')
    for col in range(W // TW):
        px = col * TW
        add(f'      <path transform="translate({px} 0)" '
            f'd="{arch_path(CX, panel_w, panel_top, TH)} Z" fill="white"/>')
    add('    </mask>')

    # --- arches ----------------------------------------------------------
    add(f'    <pattern id="arches" width="{TW}" height="{TH}" patternUnits="userSpaceOnUse">')
    add('      <g fill="none" stroke-linecap="round" stroke-linejoin="round">')
    add(f'        <g filter="url(#bloom)" stroke="{gold}" opacity="0.22">')
    for d, role in motif_paths:
        wdark, wgold, wlight, op = styles[role]
        add(f'          <path d="{d}" stroke-width="{max(wgold, wdark * 0.6):.2f}"/>')
    add('        </g>')
    for d, role in motif_paths:
        wdark, wgold, wlight, op = styles[role]
        if wdark:
            add(f'        <path d="{d}" stroke="{gold_dark}" stroke-width="{wdark}" '
                f'stroke-opacity="{op * 0.45:.2f}"/>')
        add(f'        <path d="{d}" stroke="{gold}" stroke-width="{wgold}" '
            f'stroke-opacity="{op:.2f}"/>')
        if wlight:
            add(f'        <path d="{d}" stroke="{gold_light}" stroke-width="{wlight}" '
                f'stroke-opacity="{op * 0.58:.2f}"/>')
    add('      </g>')
    add('    </pattern>')
    add('  </defs>')

    add(f'  <rect width="{W}" height="{H}" fill="url(#bg)"/>')
    add(f'  <rect width="{W}" height="{H}" fill="url(#cool)"/>')
    add(f'  <rect width="{W}" height="{H}" fill="url(#warm)"/>')
    add(f'  <rect width="{W}" height="{H}" fill="url(#kikko)"/>')

    if motif == "asanoha":
        add(f'  <rect width="{W}" height="{H}" fill="url(#asanoha)" mask="url(#panel-mask)"/>')
    elif motif == "medallion":
        add(f'  <rect width="{W}" height="{H}" fill="url(#medallion)" mask="url(#panel-mask)"/>')
    elif motif == "kagome":
        add(f'  <rect width="{W}" height="{H}" fill="url(#kagome)" mask="url(#panel-mask)"/>')
    elif motif == "hybrid":
        add(f'  <rect x="0" y="{inner_arc_cy:.2f}" width="{W}" '
            f'height="{hybrid_split - inner_arc_cy:.2f}" fill="url(#asanoha)" mask="url(#panel-mask)"/>')
        add(f'  <rect x="0" y="{hybrid_split:.2f}" width="{W}" '
            f'height="{TH - hybrid_split:.2f}" fill="url(#kagome-hybrid)" mask="url(#panel-mask)"/>')
    else:
        raise SystemExit(f"unknown motif {motif}")

    add(f'  <rect width="{W}" height="{H}" fill="url(#arches)"/>')
    add(f'  <rect width="{W}" height="{H}" fill="url(#vig)"/>')
    add('</svg>')
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("motif", nargs="?", default="medallion",
                    choices=["asanoha", "medallion", "kagome", "hybrid"])
    ap.add_argument("--palette", choices=["brass", "cream"], default="brass")
    ap.add_argument("-o", "--out", default="kumiko-deco.svg",
                    help="output SVG path (default: kumiko-deco.svg)")
    args = ap.parse_args()
    svg = build(args.motif, args.palette)
    with open(args.out, "w") as fh:
        fh.write(svg)
    print(args.out)


if __name__ == "__main__":
    main()
