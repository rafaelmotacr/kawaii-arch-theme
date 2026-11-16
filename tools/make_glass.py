#!/usr/bin/env python3
# =====================================================================
#  make_glass.py - gera as molduras "liquid glass" do tema (script extra,
#  nao versionado; os PNGs gerados e que fazem parte do tema)
#
#  Uso: python3 tools/make_glass.py [--out DIR] [--opacity A]
#
#  Gera em DIR (padrao: grub-theme/ do pacote):
#    terminal_box_{nw,n,ne,w,c,e,sw,s,se}.png   caixa do terminal (theme.txt:
#        terminal-box): vidro escuro neutro + contorno claro
#    boot_menu_box_{nw,n,ne,w,e,sw,s,se}.png    contorno do menu de boot
#        (theme.txt: menu_pixmap_style): mesma geometria e contorno do
#        terminal, sem o preenchimento escuro (o menu ja e transparente;
#        sem menu_c, o GRUB nao desenha nada no centro)
#
#  --opacity: opacidade do vidro do terminal (padrao 0.72, calibrada para
#  manter o texto do GRUB legivel ate sobre areas brancas do wallpaper).
#  Requer Python 3 com Pillow e NumPy.
# =====================================================================
import argparse
import os
import sys

import numpy as np
from PIL import Image

B = 16           # borda: tiles de canto 16x16 (= padding usado pelo GRUB)
CW, CH = 64, 34  # tile central
SS = 8           # supersampling para antialiasing
INSET = 2.0      # distancia do retangulo arredondado ate a borda externa do tile
RADIUS = 12.0

# Tom NEUTRO (sem matiz): os wallpapers mudam (bundles com paletas
# diferentes), entao o vidro so escurece o que esta atras.
FILL = np.array([10, 10, 12]) / 255.0

W, H = B * 2 + CW, B * 2 + CH

TILES = {
    "nw": (0, 0, B, B), "n": (B, 0, B + CW, B), "ne": (B + CW, 0, W, B),
    "w": (0, B, B, B + CH), "c": (B, B, B + CW, B + CH), "e": (B + CW, B, W, B + CH),
    "sw": (0, B + CH, B, H), "s": (B, B + CH, B + CW, H), "se": (B + CW, B + CH, W, H),
}


def sdf_round_rect(x, y):
    """Distancia assinada ao retangulo arredondado (negativa = dentro)."""
    cx, cy = W / 2, H / 2
    hx, hy = W / 2 - INSET - RADIUS, H / 2 - INSET - RADIUS
    qx = np.abs(x - cx) - hx
    qy = np.abs(y - cy) - hy
    outside = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0))
    inside = np.minimum(np.maximum(qx, qy), 0)
    return outside + inside - RADIUS


def render(fill_alpha):
    """Renderiza a caixa completa (W x H) em RGBA."""
    ys, xs = np.mgrid[0:H * SS, 0:W * SS]
    x = (xs + 0.5) / SS
    y = (ys + 0.5) / SS
    d = sdf_round_rect(x, y)

    rgb = np.zeros(d.shape + (3,))   # premultiplicado
    a = np.zeros(d.shape)

    def over(color, alpha):
        nonlocal rgb, a
        alpha = np.clip(alpha, 0, 1)
        rgb = color * alpha[..., None] + rgb * (1 - alpha[..., None])
        a = alpha + a * (1 - alpha)

    # sombra externa suave: destaca o contorno sobre wallpapers claros
    over(np.zeros(3), np.where(d > 0, 0.22 * np.clip(1 - d / 2.0, 0, 1), 0))

    inside = (d <= 0).astype(float)
    if fill_alpha > 0:
        over(FILL, fill_alpha * inside)

    # luz vinda de cima: aro superior mais brilhante, inferior mais discreto
    # (varia so na vertical perto das bordas: tiles e/w ficam uniformes)
    t = np.clip((y - INSET) / (B - INSET), 0, 1)
    b = np.clip((H - INSET - y) / (B - INSET), 0, 1)
    rim_a = 0.38 + 0.22 * (1 - t) - 0.16 * (1 - b)

    # aro externo brilhante (~1.3px)
    over(np.ones(3), rim_a * inside * np.clip(1 - (-d) / 1.3, 0, 1))
    # reflexo interno fraco (espessura do vidro), ~3px para dentro
    over(np.ones(3), 0.10 * inside * np.exp(-((-d - 3.0) ** 2) / 1.5))

    def down(arr):
        return arr.reshape(H, SS, W, SS, *arr.shape[2:]).mean(axis=(1, 3))

    rgb_s, a_s = down(rgb), down(a)
    col = np.where(a_s[..., None] > 0, rgb_s / np.maximum(a_s[..., None], 1e-9), 0)
    img = np.dstack([col * 255, a_s * 255]).round().clip(0, 255).astype(np.uint8)
    return Image.fromarray(img, "RGBA")


def save_tiles(full, out, prefix, names):
    for name in names:
        path = os.path.join(out, f"{prefix}_{name}.png")
        full.crop(TILES[name]).save(path, optimize=True)
        print(path)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Gera as molduras liquid glass do tema.")
    ap.add_argument("--out", default=os.path.join(here, "..", "grub-theme"),
                    help="diretorio de saida (padrao: grub-theme/)")
    ap.add_argument("--opacity", type=float, default=0.72,
                    help="opacidade do vidro do terminal, 0..1 (padrao 0.72)")
    args = ap.parse_args()
    if not 0 <= args.opacity <= 1:
        sys.exit("make_glass: --opacity deve estar entre 0 e 1")
    os.makedirs(args.out, exist_ok=True)

    save_tiles(render(args.opacity), args.out, "terminal_box", TILES)
    save_tiles(render(0.0), args.out, "boot_menu_box",
               [n for n in TILES if n != "c"])


if __name__ == "__main__":
    main()
