#!/usr/bin/env python3
"""Generate the keyd Extend-layer diagram used in README.md.

Writes pictures/keyd-extend-layer.svg and renders a 2x PNG next to it.
Keep the mapping in sync with keyd/default.conf. Requires ImageMagick (`magick`).
"""

from html import escape
from pathlib import Path
import subprocess

OUT_DIR = Path(__file__).resolve().parent.parent / "pictures"
SVG = OUT_DIR / "keyd-extend-layer.svg"
PNG = OUT_DIR / "keyd-extend-layer.png"

W, H = 1500, 880
UNIT = 78.0
GAP = 6.0
KEY_H = 78.0
ROW_GAP = 8.0
LEFT = (W - (15 * UNIT + 14 * GAP)) / 2
TOP = 145.0

# Colors
BG = "#f8fafc"
INK = "#0f172a"
MUTED = "#64748b"
SUBTLE = "#475569"
BORDER = "#cbd5e1"
KEY_FILL = "#ffffff"

PALETTE = {
    "nav": ("#eff6ff", "#93c5fd", "#1d4ed8"),
    "mouse": ("#ecfdf5", "#6ee7b7", "#047857"),
    "wheel": ("#ecfeff", "#67e8f9", "#0e7490"),
    "edit": ("#f5f3ff", "#c4b5fd", "#6d28d9"),
    "browser": ("#fff7ed", "#fdba74", "#c2410c"),
    "media": ("#fff1f2", "#fda4af", "#be123c"),
    "mod": ("#fefce8", "#fde047", "#a16207"),
}
TRIG_FILL = "#fffbeb"
TRIG_BORDER = "#f59e0b"
TRIG_INK = "#b45309"
BADGE = "#f59e0b"

# Row definition: (physical label, width_units, layer action, kind)
# kind: normal | nav | mouse | wheel | edit | browser | media | mod
#       | trigger_caps | trigger_altgr
rows = [
    [
        ("Esc", 1, None, "normal"),
        ("F1", 1, "Prev", "media"),
        ("F2", 1, "Play/Pause", "media"),
        ("F3", 1, "Next", "media"),
        ("F4", 1, None, "normal"),
        ("F5", 1, None, "normal"),
        ("F6", 1, None, "normal"),
        ("F7", 1, None, "normal"),
        ("F8", 1, None, "normal"),
        ("F9", 1, None, "normal"),
        ("F10", 1, None, "normal"),
        ("F11", 1, None, "normal"),
        ("F12", 1, None, "normal"),
    ],
    [
        ("~", 1, None, "normal"),
        ("1", 1, None, "normal"),
        ("2", 1, None, "normal"),
        ("3", 1, None, "normal"),
        ("4", 1, None, "normal"),
        ("5", 1, None, "normal"),
        ("6", 1, None, "normal"),
        ("7", 1, None, "normal"),
        ("8", 1, None, "normal"),
        ("9", 1, None, "normal"),
        ("0", 1, None, "normal"),
        ("-", 1, None, "normal"),
        ("=", 1, None, "normal"),
        ("Bksp", 2, None, "normal"),
    ],
    [
        ("Tab", 1.5, None, "normal"),
        ("Q", 1, "Esc", "nav"),
        ("W", 1, "Wheel ↑", "wheel"),
        ("E", 1, "Back", "browser"),
        ("R", 1, "Fwd", "browser"),
        ("T", 1, "↑", "nav"),
        ("Y", 1, "PgUp", "nav"),
        ("U", 1, "Home", "nav"),
        ("I", 1, "↑", "nav"),
        ("O", 1, "End", "nav"),
        ("P", 1, "PgDn", "nav"),
        ("[", 1, "Esc", "nav"),
        ("]", 1, "Ins", "nav"),
        ("\\", 1.5, "Fav", "browser"),
    ],
    [
        ("Caps", 1.75, None, "trigger_caps"),
        ("A", 1, "Alt", "mod"),
        ("S", 1, "Wheel ↓", "wheel"),
        ("D", 1, "Shift", "mod"),
        ("F", 1, "Ctrl", "mod"),
        ("G", 1, "↓", "nav"),
        ("H", 1, "Bksp", "nav"),
        ("J", 1, "←", "nav"),
        ("K", 1, "↓", "nav"),
        ("L", 1, "→", "nav"),
        (";", 1, "Del", "nav"),
        ("Quote", 1, None, "normal"),
        ("Enter", 2.25, None, "normal"),
    ],
    [
        ("Shift", 2.25, None, "normal"),
        ("Z", 1, "Undo", "edit"),
        ("X", 1, "Cut", "edit"),
        ("C", 1, "Copy", "edit"),
        ("V", 1, "Paste", "edit"),
        ("B", 1, "MMB", "mouse"),
        ("N", 1, "RMB", "mouse"),
        ("M", 1, "LMB", "mouse"),
        (",", 1, "←", "nav"),
        (".", 1, "→", "nav"),
        ("/", 1, "Compose", "nav"),
        ("Shift", 2.75, None, "normal"),
    ],
    [
        ("Ctrl", 1.25, None, "normal"),
        ("Win", 1.25, None, "normal"),
        ("Alt", 1.25, None, "normal"),
        ("Space", 6.25, "Enter", "nav"),
        ("AltGr", 1.25, None, "trigger_altgr"),
        ("Win", 1.25, None, "normal"),
        ("Menu", 1.25, None, "normal"),
        ("Ctrl", 1.25, None, "normal"),
    ],
]


def key_width(units: float) -> float:
    return units * UNIT + (units - 1) * GAP


def text(x, y, value, size=20, fill=INK, weight="500", anchor="middle", extra=""):
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-family="Noto Sans, Liberation Sans, sans-serif" '
        f'font-size="{size}" font-weight="{weight}" fill="{fill}" text-anchor="{anchor}" '
        f'{extra}>{escape(value)}</text>'
    )


def action_size(value: str) -> float:
    if len(value) <= 2:
        return 21
    if len(value) <= 4:
        return 19
    if len(value) <= 6:
        return 16
    if len(value) <= 9:
        return 13.5
    return 12


parts = []
parts.append(
    f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
    f'viewBox="0 0 {W} {H}" role="img" aria-label="keyd Extend layer keyboard layout">'
)
parts.append("<defs>")
parts.append(
    '<filter id="shadow" x="-20%" y="-20%" width="140%" height="150%">'
    '<feDropShadow dx="0" dy="2" stdDeviation="1.6" flood-color="#0f172a" flood-opacity="0.12"/>'
    "</filter>"
)
parts.append("</defs>")
parts.append(f'<rect width="{W}" height="{H}" fill="{BG}"/>')

# Header
parts.append(text(W / 2, 52, "keyd Extend Layer", size=36, fill=INK, weight="700"))
parts.append(
    text(
        W / 2,
        90,
        "Right-hand navigation, editing, mouse and media · hold CapsLock or Right Alt",
        size=18,
        fill=SUBTLE,
        weight="400",
    )
)
parts.append(
    f'<rect x="{W / 2 - 52:.1f}" y="106" width="104" height="4" rx="2" fill="#3b82f6"/>'
)

# Keyboard
y = TOP
for row in rows:
    row_width = sum(key_width(units) for _, units, _, _ in row) + GAP * (len(row) - 1)
    x = (W - row_width) / 2
    for label, units, action, kind in row:
        w = key_width(units)
        is_trigger = kind in ("trigger_caps", "trigger_altgr")

        if kind in PALETTE:
            fill, border, accent = PALETTE[kind]
            stroke_w = 2
        elif is_trigger:
            fill, border, accent = TRIG_FILL, TRIG_BORDER, TRIG_INK
            stroke_w = 3
        else:
            fill, border, accent = KEY_FILL, BORDER, INK
            stroke_w = 1.5

        parts.append(
            f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{KEY_H}" rx="10" '
            f'fill="{fill}" stroke="{border}" stroke-width="{stroke_w}" filter="url(#shadow)"/>'
        )

        if is_trigger:
            trigger_label = "Caps" if kind == "trigger_caps" else "R.Alt"
            tap_label = "Esc (tap)" if kind == "trigger_caps" else "AltGr (tap)"
            parts.append(text(x + 11, y + 25, trigger_label, size=15, fill=TRIG_INK, weight="600", anchor="start"))
            parts.append(text(x + w / 2, y + KEY_H - 15, tap_label, size=11.5, fill=TRIG_INK, weight="500"))
            bx, by, bw, bh = x + w - 48, y + 9, 38, 18
            parts.append(f'<rect x="{bx:.1f}" y="{by:.1f}" width="{bw}" height="{bh}" rx="5" fill="{BADGE}"/>')
            parts.append(text(bx + bw / 2, by + 13, "NAV", size=10, fill="#ffffff", weight="700"))
        elif action:
            parts.append(text(x + 11, y + 24, label, size=15, fill=MUTED, weight="500", anchor="start"))
            parts.append(
                text(
                    x + w / 2,
                    y + KEY_H - 16,
                    action,
                    size=action_size(action),
                    fill=accent,
                    weight="700",
                )
            )
        else:
            size = 20 if len(label) <= 5 else 17
            parts.append(text(x + w / 2, y + KEY_H / 2 + 7, label, size=size, fill=INK, weight="500"))

        x += w + GAP
    y += KEY_H + ROW_GAP

# Legend
legend = [
    ("nav", "Nav & system"),
    ("mouse", "Mouse button"),
    ("wheel", "Wheel scroll"),
    ("edit", "Edit shortcuts"),
    ("browser", "Browser"),
    ("media", "Media"),
    ("mod", "Modifier"),
    ("trigger", "Layer trigger"),
]

legend_y = 690
for i, (kind, label) in enumerate(legend):
    col = i % 4
    line = i // 4
    lx = LEFT + col * 300
    ly = legend_y + line * 32
    if kind == "trigger":
        parts.append(
            f'<rect x="{lx:.1f}" y="{ly - 13}" width="14" height="14" rx="4" '
            f'fill="{TRIG_FILL}" stroke="{TRIG_BORDER}" stroke-width="2"/>'
        )
    else:
        fill, border, _ = PALETTE[kind]
        parts.append(
            f'<rect x="{lx:.1f}" y="{ly - 13}" width="14" height="14" rx="4" '
            f'fill="{fill}" stroke="{border}" stroke-width="2"/>'
        )
    parts.append(text(lx + 24, ly, label, size=15, fill=SUBTLE, weight="600", anchor="start"))

# Notes
notes = [
    "Hold CapsLock or Right Alt for the layer. Tap CapsLock = Esc · tap Right Alt = AltGr.",
    "keyd cannot move the pointer, so T/G and comma/period become the arrow keys; W/S remain wheel up/down.",
    "Number row stays numbers; F4-F12 stay F4-F12. Space = Enter.",
]
for i, note in enumerate(notes):
    parts.append(text(LEFT, 772 + i * 26, note, size=15, fill=SUBTLE if i == 0 else MUTED, weight="500" if i == 0 else "400", anchor="start"))

# Footer
parts.append(text(W / 2, H - 18, "keyd · Linux · GNOME + niri", size=12, fill="#94a3b8", weight="400"))
parts.append("</svg>")

OUT_DIR.mkdir(parents=True, exist_ok=True)
SVG.write_text("\n".join(parts), encoding="utf-8")
subprocess.run(
    ["magick", "-background", "none", "-density", "192", str(SVG), str(PNG)],
    check=True,
)
print(SVG)
print(PNG)
