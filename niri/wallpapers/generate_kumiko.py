#!/usr/bin/env python3
"""Kumiko Deco wallpaper - ink wall, brass arches, kikko lattice, asanoha stars."""
import math
import sys

W, H = 3840, 2160

BG_TOP = "#1a2027"
BG_BOT = "#0a0d11"
INK = "#07090c"
GLOW_COOL = "#2c343f"
GLOW_WARM = "#6b5327"
GOLD_DARK = "#5b4620"
GOLD = "#c09a58"
GOLD_LIGHT = "#ecd7a4"

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


def hex_path(cx, cy, r):
    pts = []
    for k in range(6):
        a = math.radians(60 * k)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return "M " + " L ".join(f"{x:.2f} {y:.2f}" for x, y in pts) + " Z"


R = 96
th = math.sqrt(3) * R
gw, gh = 3 * R, th
add(f'    <pattern id="kikko" width="{gw:.3f}" height="{gh:.3f}" patternUnits="userSpaceOnUse">')
for cx, cy in [(0, 0), (gw, 0), (1.5 * R, gh / 2), (0, gh), (gw, gh)]:
    add(f'      <path d="{hex_path(cx, cy, R)}" fill="none" stroke="{GOLD}" stroke-width="1.5" stroke-opacity="0.10"/>')
add('    </pattern>')


def arch_path(cx, w, top, bottom, flat=0.86):
    ry = w * flat
    cy = top + ry
    return (f"M {cx - w:.2f} {bottom:.2f} L {cx - w:.2f} {cy:.2f} "
            f"A {w:.2f} {ry:.2f} 0 0 1 {cx + w:.2f} {cy:.2f} "
            f"L {cx + w:.2f} {bottom:.2f}")


def asanoha(cx, cy, r, spike=1.9):
    hexes = []
    for k in range(6):
        a = math.radians(60 * k)
        hexes.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    parts = ["M " + " L ".join(f"{x:.2f} {y:.2f}" for x, y in hexes) + " Z"]
    for x, y in hexes:
        parts.append(f"M {cx} {cy} L {x:.2f} {y:.2f}")
    # outer tips sit between two hexagon vertices
    for k in range(6):
        a = math.radians(30 + 60 * k)
        tx, ty = cx + r * spike * math.cos(a), cy + r * spike * math.sin(a)
        v1, v2 = hexes[k], hexes[(k + 1) % 6]
        parts.append(f"M {v1[0]:.2f} {v1[1]:.2f} L {tx:.2f} {ty:.2f} L {v2[0]:.2f} {v2[1]:.2f}")
    return " ".join(parts)


TW, TH = 640, H
CX = TW / 2
layers = [(278, 210), (246, 250), (214, 290)]
inner_w, inner_top = layers[-1]
inner_arc_cy = inner_top + inner_w * 0.86

# Build the motif as data first so it can be drawn twice (bloom + crisp).
motif = []  # (path_d, role) roles: seam, arch, mullion, star, fan


def emit(d, role):
    motif.append((d, role))


emit(f"M 0 0 L 0 {TH} M {TW} 0 L {TW} {TH}", "seam")
for w, top in layers:
    emit(arch_path(CX, w, top, TH), "arch")
emit(f"M {CX} {inner_arc_cy:.2f} L {CX} {TH}", "mullion")
for k in range(-4, 5):
    t = math.radians(90 + k * 17)
    x2 = CX + inner_w * math.cos(t)
    y2 = inner_arc_cy + inner_w * 0.86 * math.sin(t)
    emit(f"M {CX} {inner_arc_cy:.2f} L {x2:.2f} {y2:.2f}", "fan")
for cy, r in ((900, 56), (1440, 64), (1940, 50)):
    emit(asanoha(CX, cy, r), "star")

styles = {
    # role: (dark width, gold width, light width, base opacity)
    "seam":    (7.0, 2.0, 0.0, 0.50),
    "arch":    (8.5, 2.8, 1.0, 0.95),
    "mullion": (5.5, 1.9, 0.8, 0.80),
    "fan":     (0.0, 1.2, 0.0, 0.24),
    "star":    (5.0, 1.6, 0.0, 0.72),
}

add(f'    <pattern id="arches" width="{TW}" height="{TH}" patternUnits="userSpaceOnUse">')
add('      <g fill="none" stroke-linecap="round" stroke-linejoin="round">')

# soft bloom pass
add(f'        <g filter="url(#bloom)" stroke="{GOLD}" opacity="0.22">')
for d, role in motif:
    wdark, wgold, wlight, op = styles[role]
    width = max(wgold, wdark * 0.6)
    add(f'          <path d="{d}" stroke-width="{width:.2f}"/>')
add('        </g>')

# crisp pass
for d, role in motif:
    wdark, wgold, wlight, op = styles[role]
    if wdark:
        add(f'        <path d="{d}" stroke="{GOLD_DARK}" stroke-width="{wdark}" stroke-opacity="{op * 0.45:.2f}"/>')
    add(f'        <path d="{d}" stroke="{GOLD}" stroke-width="{wgold}" stroke-opacity="{op:.2f}"/>')
    if wlight:
        add(f'        <path d="{d}" stroke="{GOLD_LIGHT}" stroke-width="{wlight}" stroke-opacity="{op * 0.58:.2f}"/>')

add('      </g>')
add('    </pattern>')
add('  </defs>')
add(f'  <rect width="{W}" height="{H}" fill="url(#bg)"/>')
add(f'  <rect width="{W}" height="{H}" fill="url(#cool)"/>')
add(f'  <rect width="{W}" height="{H}" fill="url(#warm)"/>')
add(f'  <rect width="{W}" height="{H}" fill="url(#kikko)"/>')
add(f'  <rect width="{W}" height="{H}" fill="url(#arches)"/>')
add(f'  <rect width="{W}" height="{H}" fill="url(#vig)"/>')
add('</svg>')

path = sys.argv[1] if len(sys.argv) > 1 else "kumiko-deco.svg"
with open(path, "w") as fh:
    fh.write("\n".join(out) + "\n")
print(path)
