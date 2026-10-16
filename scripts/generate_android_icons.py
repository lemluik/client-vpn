#!/usr/bin/env python3
"""
Генерация иконок «Нейтрино» (атом) для Android mipmap densities,
Play Store icon и favicon-набора.
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw

DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

COLOR_LIGHT_FG = (21, 101, 192)   # #1565C0
COLOR_DARK_FG = (100, 181, 246)   # #64B5F6
COLOR_LIGHT_BG = (255, 255, 255)  # #FFFFFF
COLOR_DARK_BG = (26, 26, 26)      # #1A1A1A


def draw_ellipse_rotated(draw, cx, cy, rx, ry, angle_deg, color, width):
    """Рисует повёрнутый эллипс по точкам."""
    angle = math.radians(angle_deg)
    cos_a = math.cos(angle)
    sin_a = math.sin(angle)
    steps = max(120, int(rx * 4))
    points = []
    for i in range(steps + 1):
        t = 2 * math.pi * i / steps
        ex = rx * math.cos(t)
        ey = ry * math.sin(t)
        px = cx + ex * cos_a - ey * sin_a
        py = cy + ex * sin_a + ey * cos_a
        points.append((px, py))
    for i in range(len(points) - 1):
        draw.line([points[i], points[i + 1]], fill=color, width=width)


def draw_atom(size, fg_color):
    """Возвращает RGBA-изображение атома на прозрачном фоне."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    center = size / 2
    scale = size / 108.0
    
    particle_r = 8 * scale
    draw.ellipse(
        [center - particle_r, center - particle_r,
         center + particle_r, center + particle_r],
        fill=(*fg_color, 255)
    )
    
    rx = 24 * scale
    ry = 12 * scale
    stroke_w = max(1, int(2.5 * scale))
    
    for angle in [0, 60, 120]:
        draw_ellipse_rotated(draw, center, center, rx, ry, angle,
                             (*fg_color, 255), stroke_w)
    
    return img


def generate_icon(size, fg_color, bg_color, output_path):
    """Генерирует одну иконку."""
    bg = Image.new("RGBA", (size, size), (*bg_color, 255))
    atom = draw_atom(size, fg_color)
    bg.paste(atom, (0, 0), atom)
    
    output_path.parent.mkdir(parents=True, exist_ok=True)
    bg.convert("RGB").save(output_path, "PNG")


def generate_favicon(size, output_path):
    """Генерирует favicon (атом на белом фоне)."""
    generate_icon(size, COLOR_LIGHT_FG, COLOR_LIGHT_BG, output_path)


def main():
    base = Path("android/app/src/main/res")
    
    print("Android mipmap:")
    for density, size in DENSITIES.items():
        for name in ["ic_launcher.png", "ic_launcher_round.png"]:
            path = base / f"mipmap-{density}" / name
            generate_icon(size, COLOR_LIGHT_FG, COLOR_LIGHT_BG, path)
            print(f"  {path} ({size}x{size})")
    
    print("\nPlay Store icon:")
    play_store = Path("play-store-icon-512.png")
    generate_icon(512, COLOR_LIGHT_FG, COLOR_LIGHT_BG, play_store)
    print(f"  {play_store} (512x512)")
    
    print("\nFavicon:")
    favicon_dir = Path("assets/favicon")
    for size in [16, 32, 180, 192, 512]:
        name = {16: "favicon-16x16.png", 32: "favicon-32x32.png",
                180: "apple-touch-icon.png", 192: "android-chrome-192x192.png",
                512: "android-chrome-512x512.png"}[size]
        path = favicon_dir / name
        generate_favicon(size, path)
        print(f"  {path} ({size}x{size})")
    
    print("\nГотово!")


if __name__ == "__main__":
    main()
