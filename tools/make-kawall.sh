#!/usr/bin/env bash
# =====================================================================
#  make-kawall.sh - empacota um diretorio de bundle em <id>.kawall
#
#  Uso: tools/make-kawall.sh DIRETORIO_DO_BUNDLE [SAIDA.kawall]
#
#  DIRETORIO_DO_BUNDLE deve conter manifest.conf e backgrounds/*.png.
#  Somente esses arquivos entram no pacote, sob o
#  diretorio raiz <ID> (lido do manifest.conf). O pacote e um tar com
#  compressao zstd (ou gzip, se zstd nao estiver disponivel), com dono
#  root, permissoes 0644/0755 e ordem deterministica.
# =====================================================================
set -euo pipefail
export LC_ALL=C

die() { echo "make-kawall: erro: $*" >&2; exit 1; }

[[ $# -ge 1 && $# -le 2 ]] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
src="$(cd "$1" && pwd)" || die "diretorio invalido: $1"

[[ -f "$src/manifest.conf" ]] || die "manifest.conf ausente em $src"
[[ -d "$src/backgrounds" ]] || die "backgrounds/ ausente em $src"

id="$(sed -n -E 's/^ID="?([^"]*)"?[[:space:]]*$/\1/p' "$src/manifest.conf" | tail -n1)"
version="$(sed -n -E 's/^VERSION="?([^"]*)"?[[:space:]]*$/\1/p' "$src/manifest.conf" | tail -n1)"
[[ "$id" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || die "ID invalido no manifest.conf: \"$id\""
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] \
    || die "VERSION invalida no manifest.conf: \"$version\""

out="${2:-$PWD/$id.kawall}"
[[ "$out" == /* ]] || out="$PWD/$out"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$id/backgrounds"
cp "$src/manifest.conf" "$stage/$id/"
n=0
shopt -s nullglob
for f in "$src/backgrounds/"*.png; do
    name="${f##*/}"
    [[ -f "$f" && ! -L "$f" && "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.png$ ]] || {
        echo "make-kawall: aviso: ignorado: $name" >&2; continue; }
    cp "$f" "$stage/$id/backgrounds/"
    n=$((n + 1))
done
((n > 0)) || die "nenhuma imagem .png em $src/backgrounds"

if command -v zstd >/dev/null; then comp=(--zstd); else comp=(--gzip); fi
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='@0' \
    --mode='u=rwX,go=rX' "${comp[@]}" -C "$stage" -cf "$out.tmp" "$id"
mv -f "$out.tmp" "$out"
echo "make-kawall: $out ($id $version, $n imagens, $(du -h "$out" | cut -f1))"
