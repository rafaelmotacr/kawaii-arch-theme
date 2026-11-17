#!/usr/bin/env python3
# =====================================================================
#  make_light_assets.py - gera as pecas do tom "light" (wallpaper claro)
#  a partir das do tom "dark" (script extra, nao versionado; os PNGs
#  gerados e que fazem parte do tema)
#
#  Uso: python3 tools/make_light_assets.py [--theme DIR]
#
#  Le de DIR (padrao: grub-theme/ do pacote) e grava:
#    tones/dark/select_{w,c,e}.png          -> tones/light/ (preto, mesma forma)
#    tones/dark/progress_highlight_c.png    -> tones/light/ (faixa escura)
#    icon-sets/dark/*.png                   -> icon-sets/light/
#
#  Icones em tons de cinza (os glifos brancos do tema) tem a luminosidade
#  invertida (branco -> #1c1c22, detalhes escuros -> claros); icones
#  coloridos sao copiados sem alteracao. As molduras (terminal_box_*,
#  boot_menu_box_*) sao geradas por make_glass.py --tone light.
#  Requer Python 3 com Pillow e NumPy.
# =====================================================================
import argparse
import os
import shutil

import numpy as np
from PIL import Image

DARK = np.array([28, 28, 34], dtype=float)   # #1c1c22
SPREAD_MAX = 24        # diferenca maxima entre canais para "cinza"


def load(path):
    return np.asarray(Image.open(path).convert("RGBA")).astype(float)


def save(arr, path):
    Image.fromarray(arr.round().clip(0, 255).astype(np.uint8), "RGBA").save(path, optimize=True)
    print(path)


def flat_dark(src, dst, alpha_scale=1.0):
    """Mesma forma (alfa), cor escura solida."""
    a = load(src)
    a[..., :3] = DARK
    a[..., 3] *= alpha_scale
    save(a, dst)


def is_gray(a):
    vis = a[..., 3] > 25
    if not vis.any():
        return True
    rgb = a[..., :3][vis]
    return float((rgb.max(axis=1) - rgb.min(axis=1)).mean()) < SPREAD_MAX


def invert_gray(a):
    v = a[..., :3].mean(axis=2, keepdims=True)
    a = a.copy()
    a[..., :3] = DARK + (255 - v) * ((255 - DARK) / 255)
    return a


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Gera as pecas do tom light.")
    ap.add_argument("--theme", default=os.path.join(here, "..", "grub-theme"),
                    help="diretorio do tema (padrao: grub-theme/)")
    t = ap.parse_args().theme
    src, dst = os.path.join(t, "tones", "dark"), os.path.join(t, "tones", "light")
    os.makedirs(dst, exist_ok=True)

    # selecao: branco a ~15% -> preto a ~12% (o preto pesa mais no claro)
    for n in ("w", "c", "e"):
        flat_dark(os.path.join(src, f"select_{n}.png"), os.path.join(dst, f"select_{n}.png"), 0.8)
    flat_dark(os.path.join(src, "progress_highlight_c.png"), os.path.join(dst, "progress_highlight_c.png"))

    isrc, idst = os.path.join(t, "icon-sets", "dark"), os.path.join(t, "icon-sets", "light")
    os.makedirs(idst, exist_ok=True)
    for name in sorted(os.listdir(isrc)):
        if not name.endswith(".png"):
            continue
        a = load(os.path.join(isrc, name))
        if is_gray(a):
            save(invert_gray(a), os.path.join(idst, name))
        else:
            shutil.copyfile(os.path.join(isrc, name), os.path.join(idst, name))
            print(os.path.join(idst, name), "(colorido, copiado)")


if __name__ == "__main__":
    main()
