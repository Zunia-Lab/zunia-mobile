#!/usr/bin/env python3
"""Regenerate the launch-screen and app-icon artwork from the brand mark.

Every native first-run asset is drawn from the mark's construction in
zunia-brand (two chevrons on a 96 x 120 grid, 24 stroke, round caps; the
crossing is cut from the lower ribbon), so the iOS launch screen, the Android
splash, the app icons and Flutter's own ZuniaMark (lib/ui/zunia_mark.dart) all
show the same pixels. Change the geometry or colours here and in zunia_mark.dart
together.

Needs `rsvg-convert` (Homebrew: `brew install librsvg`) and python3; no Python
packages. Run from the repository root:

    python3 scripts/brand-assets.py
"""

import os
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IOS_ASSETS = os.path.join(ROOT, 'ios/Runner/Assets.xcassets')
ANDROID_RES = os.path.join(ROOT, 'android/app/src/main/res')

# Brand colours (zunia-brand tokens.css / zunia_tokens).
PAPER = '#F1F0EE'  # lightBg
INK = '#0B0A09'  # darkBg

# The mark, in its own 96 x 120 grid.
UPPER = ((26, 20), (70, 46), (26, 72))
LOWER = ((26, 48), (70, 74), (26, 100))
STROKE = 24
# The one-colour mark separates the ribbons with a gap: the upper chevron is cut
# out of the lower one at this width.
GAP_STROKE = 30
# Visual bounds of the stroked mark (caps included) and their centre.
MARK_CENTER = (48, 60)
MARK_VISUAL_HEIGHT = 104

# Gradients as zunia-mark-clean.svg declares them: objectBoundingBox fractions
# over the path geometry, then stops.
GRAD_UPPER = ((0.1, 0, 0.95, 0.9), ((0, '#FF1B0C'), (0.55, '#FF4E12'), (1, '#FF8A17')))
GRAD_LOWER = ((0.1, 1, 0.95, 0.1), ((0, '#FF9A05'), (0.55, '#FFBE14'), (1, '#FFE05C')))
GRAD_CROSS = ((0, 0, 1, 1), ((0, '#D42800'), (1, '#FF6A05')))
# App icon tile (zunia-icon-gradient-tile.svg).
TILE_STOPS = ((0, '#FF1B0C'), (0.46, '#FF6A10'), (1, '#FFC414'))

# The shipped icon puts the mark at 60% of the tile height, centred.
ICON_MARK_FRACTION = 0.6

# Launch mark box, in points / dp: the 96 x 120 grid at 1:1.
LAUNCH_W, LAUNCH_H = 96, 120


def pts(points, dx=0.0, dy=0.0, s=1.0):
    return ' L'.join(f'{x * s + dx:.3f},{y * s + dy:.3f}' for x, y in points)


def path_d(points, dx=0.0, dy=0.0, s=1.0):
    return 'M' + pts(points, dx, dy, s)


def bbox(points):
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)


def user_space_gradient(points, fractions):
    """Start and end of a userSpaceOnUse gradient equal to an objectBoundingBox one.

    SVG evaluates a bounding-box gradient in the box's own unit square, so on a
    box that is not square its colour bands are not perpendicular to the
    start-end line in user space. Android vectors and Flutter shaders only take
    user-space points, so solve for the line along which the colour actually
    changes.
    """
    bx, by, bw, bh = bbox(points)
    x1, y1, x2, y2 = fractions
    dx, dy = x2 - x1, y2 - y1
    length2 = dx * dx + dy * dy
    gx, gy = dx / (bw * length2), dy / (bh * length2)
    g2 = gx * gx + gy * gy
    sx, sy = bx + x1 * bw, by + y1 * bh
    return (sx, sy), (sx + gx / g2, sy + gy / g2)


def crossing():
    """Where the upper chevron's second arm crosses the lower one's first arm.

    Two strokes of equal width cross in a parallelogram; it lies inside both
    straight segments (not their caps), so it is exactly the mask
    zunia-mark-clean.svg paints with the crossing gradient.
    """
    def offset_line(a, b, side):
        ax, ay = a
        bx, by = b
        ux, uy = bx - ax, by - ay
        n = (ux * ux + uy * uy) ** 0.5
        nx, ny = -uy / n, ux / n
        h = STROKE / 2 * side
        return (ax + nx * h, ay + ny * h), (ux, uy)

    def intersect(l1, l2):
        (p, r), (q, s) = l1, l2
        cross = r[0] * s[1] - r[1] * s[0]
        t = ((q[0] - p[0]) * s[1] - (q[1] - p[1]) * s[0]) / cross
        return p[0] + t * r[0], p[1] + t * r[1]

    out = []
    for su, sl in ((1, 1), (1, -1), (-1, -1), (-1, 1)):
        out.append(intersect(offset_line(UPPER[1], UPPER[2], su), offset_line(LOWER[0], LOWER[1], sl)))
    return out


# --- SVG documents ----------------------------------------------------------

def svg_stops(stops):
    return ''.join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)


def gradient_mark_svg(dx, dy, s):
    """The full-colour mark, as zunia-mark-clean.svg, placed at (dx, dy) scale s."""
    (a1, a2), (b1, b2), (c1, c2) = (
        user_space_gradient(UPPER, GRAD_UPPER[0]),
        user_space_gradient(LOWER, GRAD_LOWER[0]),
        user_space_gradient(LOWER, GRAD_CROSS[0]),
    )

    def lin(gid, p1, p2, stops):
        return (
            f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" '
            f'x1="{p1[0] * s + dx:.4f}" y1="{p1[1] * s + dy:.4f}" '
            f'x2="{p2[0] * s + dx:.4f}" y2="{p2[1] * s + dy:.4f}">{svg_stops(stops)}</linearGradient>'
        )

    sw = STROKE * s
    return (
        '<defs>'
        + lin('ga', a1, a2, GRAD_UPPER[1])
        + lin('gb', b1, b2, GRAD_LOWER[1])
        + lin('gx', c1, c2, GRAD_CROSS[1])
        + '</defs>'
        f'<path d="{path_d(UPPER, dx, dy, s)}" fill="none" stroke="url(#ga)" stroke-width="{sw:.4f}" '
        'stroke-linecap="round" stroke-linejoin="round"/>'
        f'<path d="{path_d(LOWER, dx, dy, s)}" fill="none" stroke="url(#gb)" stroke-width="{sw:.4f}" '
        'stroke-linecap="round" stroke-linejoin="round"/>'
        f'<path d="M{pts(crossing(), dx, dy, s)} Z" fill="url(#gx)"/>'
    )


def mono_mark_svg(dx, dy, s, color='#FFFFFF'):
    """The one-colour mark (zunia-mark-current.svg): the upper chevron cuts a gap."""
    return (
        f'<defs><mask id="gap" maskUnits="userSpaceOnUse" x="-1e4" y="-1e4" width="2e4" height="2e4">'
        '<rect x="-1e4" y="-1e4" width="2e4" height="2e4" fill="#fff"/>'
        f'<path d="{path_d(UPPER, dx, dy, s)}" fill="none" stroke="#000" stroke-width="{GAP_STROKE * s:.4f}" '
        'stroke-linecap="round" stroke-linejoin="round"/></mask></defs>'
        f'<g mask="url(#gap)"><path d="{path_d(LOWER, dx, dy, s)}" fill="none" stroke="{color}" '
        f'stroke-width="{STROKE * s:.4f}" stroke-linecap="round" stroke-linejoin="round"/></g>'
        f'<path d="{path_d(UPPER, dx, dy, s)}" fill="none" stroke="{color}" stroke-width="{STROKE * s:.4f}" '
        'stroke-linecap="round" stroke-linejoin="round"/>'
    )


def doc(w, h, body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{body}</svg>'


def centred(size_w, size_h, mark_visual_height):
    s = mark_visual_height / MARK_VISUAL_HEIGHT
    return size_w / 2 - MARK_CENTER[0] * s, size_h / 2 - MARK_CENTER[1] * s, s


def tile_svg(size, rounded):
    rx = f' rx="{size * 120 / 512:.3f}"' if rounded else ''
    dx, dy, s = centred(size, size, size * ICON_MARK_FRACTION)
    return doc(size, size, (
        f'<defs><linearGradient id="tile" x1="0" y1="0" x2="1" y2="1">{svg_stops(TILE_STOPS)}</linearGradient></defs>'
        f'<rect width="{size}" height="{size}"{rx} fill="url(#tile)"/>'
        + mono_mark_svg(dx, dy, s)
    ))


# --- rendering ----------------------------------------------------------------

def render(svg, out_path, width, height):
    with tempfile.NamedTemporaryFile('w', suffix='.svg', delete=False) as f:
        f.write(svg)
        tmp = f.name
    try:
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        subprocess.run(
            ['rsvg-convert', '-w', str(width), '-h', str(height), '-o', out_path, tmp],
            check=True,
        )
    finally:
        os.unlink(tmp)


def assert_no_alpha(path):
    """App Store Connect rejects a marketing icon with any alpha channel, even an
    opaque one. rsvg-convert writes RGB when nothing is transparent; fail loudly if
    a change to the artwork ever makes it write RGBA."""
    with open(path, 'rb') as f:
        header = f.read(29)
    _, _, depth, color_type, _, _, _ = struct.unpack('>IIBBBBB', header[16:29])
    if (depth, color_type) != (8, 2):
        sys.exit(f'{path}: expected 8-bit RGB without alpha, got depth {depth} type {color_type}')


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(text)


# --- iOS ------------------------------------------------------------------------

def ios():
    launch = os.path.join(IOS_ASSETS, 'LaunchMark.imageset')
    mark = doc(LAUNCH_W, LAUNCH_H, gradient_mark_svg(0, 0, 1))
    for scale, suffix in ((1, ''), (2, '@2x'), (3, '@3x')):
        render(mark, os.path.join(launch, f'LaunchMark{suffix}.png'), LAUNCH_W * scale, LAUNCH_H * scale)
    write(os.path.join(launch, 'Contents.json'), '''{
  "images" : [
    { "filename" : "LaunchMark.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "LaunchMark@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "LaunchMark@3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
''')

    def rgb(hex_color):
        return tuple(f'0x{hex_color[i:i + 2]}' for i in (1, 3, 5))

    lr, lg, lb = rgb(PAPER)
    dr, dg, db = rgb(INK)
    write(os.path.join(IOS_ASSETS, 'LaunchBackground.colorset/Contents.json'), f'''{{
  "colors" : [
    {{
      "color" : {{
        "color-space" : "srgb",
        "components" : {{ "alpha" : "1.000", "blue" : "{lb}", "green" : "{lg}", "red" : "{lr}" }}
      }},
      "idiom" : "universal"
    }},
    {{
      "appearances" : [ {{ "appearance" : "luminosity", "value" : "dark" }} ],
      "color" : {{
        "color-space" : "srgb",
        "components" : {{ "alpha" : "1.000", "blue" : "{db}", "green" : "{dg}", "red" : "{dr}" }}
      }},
      "idiom" : "universal"
    }}
  ],
  "info" : {{ "author" : "xcode", "version" : 1 }}
}}
''')

    icon = os.path.join(IOS_ASSETS, 'AppIcon.appiconset')
    for name in os.listdir(icon):
        if name.endswith('.png'):
            os.unlink(os.path.join(icon, name))
    # iOS masks the icon itself: the tile is full bleed and opaque.
    render(tile_svg(1024, rounded=False), os.path.join(icon, 'AppIcon.png'), 1024, 1024)
    assert_no_alpha(os.path.join(icon, 'AppIcon.png'))
    dx, dy, s = centred(1024, 1024, 1024 * ICON_MARK_FRACTION)
    # Dark: the full-colour mark on a transparent ground; iOS supplies the dark
    # backdrop. Tinted: a white glyph whose luminance iOS maps to the tint.
    render(doc(1024, 1024, gradient_mark_svg(dx, dy, s)), os.path.join(icon, 'AppIcon-Dark.png'), 1024, 1024)
    render(doc(1024, 1024, mono_mark_svg(dx, dy, s)), os.path.join(icon, 'AppIcon-Tinted.png'), 1024, 1024)
    write(os.path.join(icon, 'Contents.json'), '''{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "filename" : "AppIcon-Dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ],
      "filename" : "AppIcon-Tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
''')


# --- Android ----------------------------------------------------------------------

DENSITIES = (('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3), ('xxxhdpi', 4))


def vector_gradient(p1, p2, stops, dx, dy):
    items = ''.join(
        f'\n                <item android:offset="{o}" android:color="#FF{c[1:]}" />' for o, c in stops
    )
    return (
        f'<gradient android:type="linear" android:startX="{p1[0] + dx:.3f}" android:startY="{p1[1] + dy:.3f}" '
        f'android:endX="{p2[0] + dx:.3f}" android:endY="{p2[1] + dy:.3f}">{items}\n            </gradient>'
    )


def android_splash_vector():
    """Android 12+ splash icon: a 288dp canvas whose middle 192dp circle shows.

    The mark sits at 1:1 (96 x 120dp) in the centre, so it lands on exactly the
    pixels Flutter's first frame draws it on.
    """
    dx, dy = (288 - LAUNCH_W) / 2, (288 - LAUNCH_H) / 2
    grads = (
        user_space_gradient(UPPER, GRAD_UPPER[0]),
        user_space_gradient(LOWER, GRAD_LOWER[0]),
        user_space_gradient(LOWER, GRAD_CROSS[0]),
    )

    def stroke(points, grad, stops):
        return f'''    <path
        android:pathData="{path_d(points, dx, dy)}"
        android:strokeWidth="{STROKE}"
        android:strokeLineCap="round"
        android:strokeLineJoin="round">
        <aapt:attr name="android:strokeColor">
            {vector_gradient(grad[0], grad[1], stops, dx, dy)}
        </aapt:attr>
    </path>
'''

    return f'''<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by scripts/brand-assets.py. The brand mark at 1:1 on the 288dp
     Android 12 splash canvas (only the middle 192dp circle shows). -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="288dp"
    android:height="288dp"
    android:viewportWidth="288"
    android:viewportHeight="288">
{stroke(UPPER, grads[0], GRAD_UPPER[1])}{stroke(LOWER, grads[1], GRAD_LOWER[1])}    <path android:pathData="M{pts(crossing(), dx, dy)} Z">
        <aapt:attr name="android:fillColor">
            {vector_gradient(grads[2][0], grads[2][1], GRAD_CROSS[1], dx, dy)}
        </aapt:attr>
    </path>
</vector>
'''


def android():
    mark = doc(LAUNCH_W, LAUNCH_H, gradient_mark_svg(0, 0, 1))
    for bucket, d in DENSITIES:
        folder = 'drawable' if bucket == 'mdpi' else f'drawable-{bucket}'
        render(mark, os.path.join(ANDROID_RES, folder, 'splash_mark.png'), round(LAUNCH_W * d), round(LAUNCH_H * d))
    write(os.path.join(ANDROID_RES, 'drawable-v31/splash_icon.xml'), android_splash_vector())

    # Adaptive icon foreground: 108dp canvas, 72dp visible; the mark keeps the
    # iOS proportion (60% of the visible tile). Doubles as the Android 13
    # monochrome layer, which only reads alpha.
    dx, dy, s = centred(108, 108, 72 * ICON_MARK_FRACTION)
    fg = doc(108, 108, mono_mark_svg(dx, dy, s))
    for bucket, d in DENSITIES:
        render(fg, os.path.join(ANDROID_RES, f'mipmap-{bucket}', 'ic_launcher_foreground.png'), round(108 * d), round(108 * d))


def flutter_assets():
    # In-app tile (app switcher shield): rounded, transparent corners.
    render(tile_svg(1024, rounded=True), os.path.join(ROOT, 'assets/brand/icon.png'), 1024, 1024)


if __name__ == '__main__':
    if subprocess.run(['which', 'rsvg-convert'], capture_output=True).returncode != 0:
        sys.exit('rsvg-convert not found (brew install librsvg)')
    ios()
    android()
    flutter_assets()
    print('crossing', [(round(x, 4), round(y, 4)) for x, y in crossing()])
    for name, pts_, grad in (('upper', UPPER, GRAD_UPPER), ('lower', LOWER, GRAD_LOWER), ('cross', LOWER, GRAD_CROSS)):
        print(name, user_space_gradient(pts_, grad[0]))
