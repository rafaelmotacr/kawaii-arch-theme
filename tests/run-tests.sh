#!/usr/bin/env bash
# =====================================================================
#  Testes do Kawaii Arch Theme (manager, helper, instalador)
#
#  Executa tudo em sandbox (KAWAII_ROOT) com um systemctl falso: nao
#  requer root e nao altera o sistema real.
#
#  Uso: tests/run-tests.sh [--keep]
# =====================================================================
set -uo pipefail
export LC_ALL=C

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0; [[ "${1:-}" == "--keep" ]] && KEEP=1
T="$(mktemp -d "${TMPDIR:-/tmp}/kawaii-tests.XXXXXX")"
((KEEP)) || trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \e[32mok\e[0m   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \e[31mFALHA\e[0m %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
# expect_rc CODIGO descricao comando...
expect_rc() {
    local want="$1" d="$2"; shift 2
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [[ "$rc" == "$want" ]]; then ok "$d (rc=$rc)"; else bad "$d (rc=$rc, esperado $want)"; printf '%s\n' "$out" | sed 's/^/        | /' | tail -n 8; fi
}
section() { printf '\n\e[1m%s\e[0m\n' "$*"; }

# --- Ferramentas de teste --------------------------------------------
cat > "$T/mkpng.py" <<'EOF'
import struct, sys, zlib
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
def png(path, w=8, h=8, color=2, interlace=0, seed=0):
    bpp = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
    raw = b"".join(b"\0" + bytes([(seed * 37 + x * 13 + y) & 255 for x in range(w * bpp)]) for y in range(h))
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, color, 0, 0, interlace))
    if color == 3:
        data += chunk(b"PLTE", bytes(range(256)) * 3)
    data += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)
args = sys.argv[1:]
png(args[0], color=int(args[1]) if len(args) > 1 else 2,
    interlace=int(args[2]) if len(args) > 2 else 0, seed=int(args[3]) if len(args) > 3 else 0)
EOF
mkpng() { python3 -I "$T/mkpng.py" "$@"; }

# PNG de cor solida para os testes de tom:
#   mksolid ARQ COR(0|2|4|6) BITS(8|16) VALOR_ESQ VALOR_DIR [ALFA] [INTERLACE]
# VALOR_ESQ preenche os 30% da esquerda (onde ficam o menu e o logo) e
# VALOR_DIR o resto; ALFA (0-255) vale para os tipos com alfa.
cat > "$T/mksolid.py" <<'EOF'
import struct, sys, zlib
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
path, color, bits, left, right = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
alpha = int(sys.argv[6]) if len(sys.argv) > 6 else 255
inter = int(sys.argv[7]) if len(sys.argv) > 7 else 0
w, h = 200, 120
def px(v):
    ch = {0: [v], 2: [v, v, v], 4: [v, alpha], 6: [v, v, v, alpha]}[color]
    return b"".join(bytes([c]) if bits == 8 else struct.pack(">H", c * 257) for c in ch)
rows = []
for y in range(h):
    rows.append(b"\0" + b"".join(px(left if x < w * 0.3 else right) for x in range(w)))
data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, bits, color, 0, 0, inter))
data += chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b"")
open(path, "wb").write(data)
EOF
mksolid() { python3 -I "$T/mksolid.py" "$@"; }

# Bundle de teste: mkbundle DIR ID VERSAO N [nome]
mkbundle() {
    local dir="$1" id="$2" ver="$3" n="$4" name="${5:-$2}" i
    mkdir -p "$dir/backgrounds"
    printf 'ID="%s"\nNAME="%s"\nVERSION="%s"\nAUTHOR="tests"\nDESCRIPTION="Bundle de teste %s."\n' "$id" "$name" "$ver" "$id" > "$dir/manifest.conf"
    for ((i = 1; i <= n; i++)); do mkpng "$dir/backgrounds/background$i.png" 2 0 "$i$RANDOM"; done
}

# systemctl falso: registra chamadas e mantem estado habilitado
cat > "$T/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/systemctl.log"
state="$T/systemctl.enabled"
args=(); for a in "\$@"; do [[ "\$a" == --* ]] || args+=("\$a"); done
case "\${args[0]}" in
  is-enabled) q=0; [[ " \$* " == *" --quiet "* ]] && q=1; if [[ -f "\$state" ]]; then ((q)) || echo enabled; exit 0; else ((q)) || echo disabled; exit 1; fi ;;
  is-active)  echo inactive; exit 3 ;;
  enable)     touch "\$state" ;;
  disable)    rm -f "\$state" ;;
  start|stop|daemon-reload) ;;
esac
exit 0
EOF
chmod +x "$T/systemctl"

# grub-mkconfig falso: nunca deve ser chamado por troca de wallpaper
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "$@" >> "%s/grub-mkconfig.log"\nexit 1\n' "$T" > "$T/bin/grub-mkconfig"
chmod +x "$T/bin/grub-mkconfig"
export PATH="$T/bin:$PATH"

# --- Build ------------------------------------------------------------
section "Build do manager"
if make -s -C "$PKG/manager" BUILD="$T/build" >"$T/build.log" 2>&1; then ok "compilacao"
else bad "compilacao"; cat "$T/build.log"; exit 1; fi
MGR="$T/build/kawaii-arch-manager"
check "binario ELF nativo" bash -c "head -c4 '$MGR' | grep -q ELF"
check "--version" bash -c "[[ \$('$MGR' --version) == 'kawaii-arch-manager 1.5.0' ]]"
check "sem avisos de compilacao" bash -c "! grep -q warning: '$T/build.log'"
expect_rc 2 "argumento invalido" "$MGR" --nao-existe
expect_rc 2 "dois comandos" "$MGR" --status --list-bundles
expect_rc 2 "modo invalido" "$MGR" --set-mode aleatorio

# --- Sandbox do manager/helper ---------------------------------------
R="$T/root"
export KAWAII_ROOT="$R" KAWAII_SKIP_ROOT_CHECK=1 KAWAII_SYSTEMCTL="$T/systemctl"
THEME="$R/boot/grub/themes/kawaii-arch-theme"
DATA="$R/var/lib/kawaii-arch-manager"
mkdir -p "$THEME" "$DATA/config" "$DATA/state" "$R/usr/share/kawaii-arch-manager/payload/bundles"
cp "$PKG/grub-theme/theme.txt" "$PKG/grub-theme/fallback.png" "$THEME/"
printf 'THEME_DIR="/boot/grub/themes/kawaii-arch-theme"\nEXPECTED_MOUNT="%s"\n' "$(stat -c %m "$THEME")" > "$DATA/config/paths.conf"
PAY="$R/usr/share/kawaii-arch-manager/payload"
cp "$PKG/helper/grub-random-bg.sh" "$PAY/"; cp "$PKG/systemd/grub-random-bg.service.in" "$PAY/"
cp "$PKG/grub-theme/VERSION" "$PAY/theme-version"
HELPER="$R/usr/lib/kawaii-arch-manager/grub-random-bg.sh"

B="$T/bundles"
mkbundle "$B/gothic" gothic 1.0.0 3 Gothic
mkbundle "$B/angelic" angelic 1.0.0 1 Angelic
mkbundle "$B/big" big 1.0.0 10 Big
for b in gothic angelic big; do "$PKG/tools/make-kawall.sh" "$B/$b" "$T/$b.kawall" >/dev/null; done

section "Importacao de bundles"
expect_rc 0 "dry-run valida sem instalar" "$MGR" --dry-run --import-bundle "$T/gothic.kawall"
check "dry-run nao criou bundle" test ! -e "$DATA/bundles/gothic"
for b in gothic angelic big; do expect_rc 0 "importa $b" "$MGR" --import-bundle "$T/$b.kawall"; done
check "imagens identicas aos originais" cmp -s "$B/gothic/backgrounds/background2.png" "$DATA/bundles/gothic/backgrounds/background2.png"
check "arquivos importados sem permissao de execucao" bash -c "! find '$DATA/bundles' -type f -perm /111 | grep -q ."
expect_rc 4 "mesma versao nao e sobrescrita" "$MGR" --import-bundle "$T/gothic.kawall"
mkbundle "$B/gothic-old" gothic 0.9.0 2; "$PKG/tools/make-kawall.sh" "$B/gothic-old" "$T/gothic-old.kawall" >/dev/null
expect_rc 4 "downgrade recusado" "$MGR" --import-bundle "$T/gothic-old.kawall"
mkbundle "$B/gothic-new" gothic 1.1.0 4; "$PKG/tools/make-kawall.sh" "$B/gothic-new" "$T/gothic-new.kawall" >/dev/null
expect_rc 4 "atualizacao sem tty e sem --yes pede confirmacao" "$MGR" --import-bundle "$T/gothic-new.kawall" </dev/null
expect_rc 0 "atualizacao para versao mais nova (--yes)" "$MGR" --yes --import-bundle "$T/gothic-new.kawall"
check "versao atualizada para 1.1.0 com 4 imagens" bash -c "grep -q 1.1.0 '$DATA/bundles/gothic/manifest.conf' && [[ \$(ls '$DATA/bundles/gothic/backgrounds' | wc -l) == 4 ]]"
check "sem diretorios temporarios restantes" bash -c "! ls -A '$DATA/bundles' | grep -q '^\.'"
expect_rc 0 "--list-bundles" "$MGR" --list-bundles
check "nome de exibicao vem do NAME do manifest" bash -c "'$MGR' --list-bundles | grep -qE 'angelic .* Angelic$'"
mkbundle "$B/noname" noname 1.0.0 1; sed -i '/^NAME=/d' "$B/noname/manifest.conf"
"$PKG/tools/make-kawall.sh" "$B/noname" "$T/noname.kawall" >/dev/null
expect_rc 0 "importa bundle sem NAME (opcional)" "$MGR" --yes --import-bundle "$T/noname.kawall"
check "sem NAME, o nome exibido e o ID" bash -c "'$MGR' --list-bundles | grep -qE 'noname +1\.0\.0 .* noname\$'"
expect_rc 0 "remove bundle sem NAME" "$MGR" --yes --remove-bundle noname
expect_rc 0 "--list-available-bundles DIR" "$MGR" --list-available-bundles "$T"

section "Importacao a partir de pasta extraida"
mkbundle "$B/folder" folder 1.0.0 3 Folder
echo "nota" > "$B/folder/LEIAME.txt"
expect_rc 0 "dry-run de pasta valida sem instalar" "$MGR" --dry-run --import-bundle "$B/folder"
check "dry-run de pasta nao criou bundle" test ! -e "$DATA/bundles/folder"
expect_rc 0 "importa a pasta do bundle" "$MGR" --yes --import-bundle "$B/folder"
check "imagens copiadas identicas" cmp -s "$B/folder/backgrounds/background3.png" "$DATA/bundles/folder/backgrounds/background3.png"
check "arquivos fora de manifest/backgrounds nao sao copiados" test ! -e "$DATA/bundles/folder/LEIAME.txt"
check "pasta de origem preservada" test -f "$B/folder/backgrounds/background1.png"
check "sem diretorios temporarios apos importar pasta" bash -c "! ls -A '$DATA/bundles' | grep -q '^\.'"
expect_rc 4 "mesma versao a partir de pasta nao e sobrescrita" "$MGR" --import-bundle "$B/folder"
expect_rc 0 "remove o bundle importado da pasta" "$MGR" --yes --remove-bundle folder
mkdir -p "$T/extraido"; tar -xf "$T/angelic.kawall" -C "$T/extraido"
sed -i 's/^VERSION=.*/VERSION="1.0.1"/' "$T/extraido/angelic/manifest.conf"
expect_rc 0 "pasta com o bundle num unico subdiretorio (tar -xf)" "$MGR" --yes --import-bundle "$T/extraido"
check "versao da pasta extraida aplicada" grep -q '1.0.1' "$DATA/bundles/angelic/manifest.conf"
mkdir -p "$T/dois"; cp -r "$B/gothic" "$B/big" "$T/dois/"
expect_rc 3 "pasta com dois bundles e recusada" "$MGR" --import-bundle "$T/dois"
mkdir -p "$T/vazia"
expect_rc 3 "pasta sem manifest.conf e recusada" "$MGR" --import-bundle "$T/vazia"
mkbundle "$B/dlink" dlink 1.0.0 1; ln -s /etc/passwd "$B/dlink/backgrounds/background9.png"
expect_rc 3 "pasta com link simbolico em backgrounds/ e recusada" "$MGR" --import-bundle "$B/dlink"
mkbundle "$B/dmlink" dmlink 1.0.0 1; mv "$B/dmlink/manifest.conf" "$T/dmlink-manifest"; ln -s "$T/dmlink-manifest" "$B/dmlink/manifest.conf"
expect_rc 3 "manifest.conf como link simbolico e recusado" "$MGR" --import-bundle "$B/dmlink"
mkbundle "$B/dfifo" dfifo 1.0.0 1; mkfifo "$B/dfifo/backgrounds/background9.png"
expect_rc 3 "pasta com fifo em backgrounds/ e recusada" "$MGR" --import-bundle "$B/dfifo"
mkbundle "$B/dbad" dbad 1.0.0 1; sed -i 's/^ID=.*/ID="..\/fora"/' "$B/dbad/manifest.conf"
expect_rc 3 "ID invalido no manifest da pasta e recusado" "$MGR" --import-bundle "$B/dbad"
check "nenhum bundle invalido instalado a partir de pasta" bash -c "! ls '$DATA/bundles' | grep -qE '^(dlink|dmlink|dfifo|dbad|fora)$'"

section "Seguranca da importacao (pacotes maliciosos)"
cat > "$T/evil.py" <<'EOF'
import io, sys, tarfile
out, kind = sys.argv[1], sys.argv[2]
png = open(sys.argv[3], "rb").read()
def add(tf, name, data=b"", type_=tarfile.REGTYPE, link="", size=None):
    ti = tarfile.TarInfo(name); ti.type = type_; ti.linkname = link; ti.mode = 0o644
    if type_ == tarfile.REGTYPE:
        ti.size = len(data) if size is None else size
        tf.addfile(ti, io.BytesIO(data))
    else:
        tf.addfile(ti)
meta = lambda i="evil", v="1.0.0": [("%s/manifest.conf" % i, ('ID="%s"\nVERSION="%s"\n' % (i, v)).encode())]
with tarfile.open(out, "w", format=tarfile.GNU_FORMAT) as tf:
    if kind == "rawsize":
        pass
    else:
        for n, d in meta(*{"badid": ("Bad_ID",), "badver": ("evil", "1.0"), "mismatch": ("other",)}.get(kind, ())):
            if kind == "mismatch": n = n.replace("other/", "evil/", 1)
            if kind == "nomanifest" and n.endswith("manifest.conf"): continue
            add(tf, n, d)
    top = "Bad_ID" if kind == "badid" else "evil"
    if kind != "noimages":
        add(tf, top + "/backgrounds/background1.png", png)
    if kind == "traversal": add(tf, "evil/backgrounds/../../../escape.png", png)
    if kind == "absolute":  add(tf, "/tmp/kawaii-escape.png", png)
    if kind == "symlink":   add(tf, "evil/backgrounds/link.png", type_=tarfile.SYMTYPE, link="/etc/passwd")
    if kind == "hardlink":  add(tf, "evil/backgrounds/hard.png", type_=tarfile.LNKTYPE, link="evil/backgrounds/background1.png")
    if kind == "fifo":      add(tf, "evil/backgrounds/fifo.png", type_=tarfile.FIFOTYPE)
    if kind == "device":    add(tf, "evil/backgrounds/dev.png", type_=tarfile.CHRTYPE)
    if kind == "twotops":   add(tf, "other/backgrounds/background1.png", png)
    if kind == "rootfile":  add(tf, "README", b"hi")
    if kind == "dup":       add(tf, "evil/backgrounds/background1.png", png)
if kind == "rawsize":
    # cabecalho declarando 600 MiB sem os dados (limite por arquivo)
    ti = tarfile.TarInfo("evil/backgrounds/huge.png"); ti.size = 600 * 1024 * 1024
    open(out, "wb").write(ti.tobuf(format=tarfile.GNU_FORMAT) + b"\0" * 1024)
EOF
mkpng "$T/ok.png"; mkpng "$T/palette.png" 3; mkpng "$T/interlaced.png" 2 1
for kind in traversal absolute symlink hardlink fifo device twotops rootfile dup badid badver mismatch nomanifest noimages rawsize; do
    python3 -I "$T/evil.py" "$T/evil-$kind.kawall" "$kind" "$T/ok.png"
    expect_rc 3 "rejeita: $kind" "$MGR" --yes --import-bundle "$T/evil-$kind.kawall"
done
python3 -I "$T/evil.py" "$T/evil-pal.kawall" noimages "$T/ok.png"
check "nenhum bundle 'evil' instalado" test ! -e "$DATA/bundles/evil"
check "nada escapou da sandbox" bash -c "[[ ! -e /tmp/kawaii-escape.png && ! -e '$DATA/escape.png' && ! -e '$T/escape.png' ]]"
mkbundle "$B/pal" pal 1.0.0 0; mkpng "$B/pal/backgrounds/background1.png" 3; mkpng "$B/pal/backgrounds/background2.png" 2 1
"$PKG/tools/make-kawall.sh" "$B/pal" "$T/pal.kawall" >/dev/null
expect_rc 3 "rejeita bundle so com PNG paleta/entrelacado (incompativeis com o GRUB)" "$MGR" --import-bundle "$T/pal.kawall"
printf 'nao sou tar' > "$T/lixo.kawall"
expect_rc 3 "rejeita arquivo corrompido" "$MGR" --import-bundle "$T/lixo.kawall"
expect_rc 2 "rejeita caminho inexistente" "$MGR" --import-bundle "$T/nao-existe.kawall"

section "Configuracao e modos (manager sem helper)"
rm -f "$DATA/config/preferences.conf"
printf 'MODE="set"\nSELECTED_BUNDLE=""\nSELECTED_BACKGROUND=""\n' > "$DATA/config/preferences.conf"
expect_rc 4 "modo set sem bundle selecionado" "$MGR" --set-mode set
expect_rc 3 "set-bundle inexistente" "$MGR" --set-bundle nada
expect_rc 0 "set-bundle gothic" "$MGR" --set-bundle gothic
expect_rc 0 "set-mode set" "$MGR" --set-mode set
expect_rc 0 "randomize sem helper (selecao interna)" "$MGR" --randomize
check "background.png veio do bundle gothic" bash -c "for f in '$DATA'/bundles/gothic/backgrounds/*; do cmp -s \"\$f\" '$THEME/background.png' && exit 0; done; exit 1"
check "last-background atualizado" grep -q '^gothic/' "$DATA/state/last-background"
prev=""; rep=0
for i in $(seq 15); do "$MGR" --randomize >/dev/null 2>&1; cur="$(cat "$DATA/state/last-background")"; [[ "$cur" == "$prev" ]] && rep=1; prev="$cur"; done
check "nao repete a ultima imagem (15 sorteios, manager)" test "$rep" = 0
expect_rc 0 "set-background angelic/background1" "$MGR" --set-background angelic/background1
check "modo fixed aplicado imediatamente" bash -c "cmp -s '$DATA/bundles/angelic/backgrounds/background1.png' '$THEME/background.png' && grep -q 'MODE=\"fixed\"' '$DATA/config/preferences.conf'"
expect_rc 3 "set-background arquivo inexistente" "$MGR" --set-background angelic/background9.png
expect_rc 4 "remocao do bundle selecionado e bloqueada" "$MGR" --yes --remove-bundle angelic
expect_rc 6 "remocao cancelada sem confirmacao" bash -c "echo n | script -qec '$MGR --remove-bundle big' /dev/null"
expect_rc 0 "--status sem helper/servico" "$MGR" --status

section "Background Helper"
expect_rc 4 "install-service sem helper e recusado" "$MGR" --install-service
expect_rc 0 "--install-helper" "$MGR" --install-helper
check "helper --version" bash -c "[[ \$('$HELPER' --version) == 2.2.0 ]]"
expect_rc 0 "--install-helper idempotente" "$MGR" --install-helper
printf 'MODE="set"\nSELECTED_BUNDLE="gothic"\nSELECTED_BACKGROUND=""\n' > "$DATA/config/preferences.conf"
prev=""; rep=0
for i in $(seq 15); do "$HELPER" -q || bad "helper rc=$?"; cur="$(cat "$DATA/state/last-background")"; [[ "$cur" == "$prev" ]] && rep=1; prev="$cur"; done
check "helper: modo set sem repeticao (15 sorteios)" test "$rep" = 0
check "helper: escolhe so do bundle selecionado" grep -q '^gothic/' "$DATA/state/last-background"
check "sem background.png.tmp residual" test ! -e "$THEME/background.png.tmp"

# Distribuicoes (dry-run, sem last-background)
rm -f "$DATA/state/last-background"
N=700
dist() { local i; for ((i = 0; i < N; i++)); do "$HELPER" --dry-run; done | sort | uniq -c; }
printf 'MODE="global"\n' > "$DATA/config/preferences.conf"
g="$(dist)"
check "global: 15 imagens elegiveis" test "$(wc -l <<< "$g")" = 15
check "global: probabilidade por imagem (angelic ~1/15, nao ~1/3)" bash -c "c=\$(awk '/angelic/{print \$1}' <<< '$g'); (( c > 15 && c < 100 ))"
printf 'MODE="balanced"\n' > "$DATA/config/preferences.conf"
bl="$(dist)"
check "balanced: angelic (1 imagem) recebe ~1/3 dos sorteios" bash -c "c=\$(awk '/angelic/{print \$1}' <<< '$bl'); (( c > 170 && c < 300 ))"
check "balanced: big (10 imagens) recebe ~1/3 no total" bash -c "c=\$(awk '/big\\//{s+=\$1} END{print s}' <<< '$bl'); (( c > 170 && c < 300 ))"

section "Falhas preservam o wallpaper valido"
printf 'MODE="set"\nSELECTED_BUNDLE="gothic"\n' > "$DATA/config/preferences.conf"
"$HELPER" -q; cp "$THEME/background.png" "$T/before.png"
printf 'MODE="set"\nSELECTED_BUNDLE="removido"\n' > "$DATA/config/preferences.conf"
expect_rc 3 "bundle selecionado ausente -> erro de configuracao" "$HELPER"
check "  wallpaper anterior preservado" cmp -s "$T/before.png" "$THEME/background.png"
printf 'MODE="xyz"\n' > "$DATA/config/preferences.conf"
expect_rc 3 "modo invalido" "$HELPER"
check "  wallpaper anterior preservado" cmp -s "$T/before.png" "$THEME/background.png"
printf 'MODE="fixed"\nSELECTED_BACKGROUND="gothic/../../etc/passwd"\n' > "$DATA/config/preferences.conf"
expect_rc 3 "SELECTED_BACKGROUND com traversal e rejeitado" "$HELPER"
rm -f "$THEME/background.png"
expect_rc 3 "sem selecao valida e sem background.png -> fallback.png" "$HELPER"
check "  fallback.png aplicado" cmp -s "$THEME/fallback.png" "$THEME/background.png"
printf 'MODE="set"\nSELECTED_BUNDLE="gothic"\n' > "$DATA/config/preferences.conf"
cp "$THEME/background.png" "$T/before.png"
sed -i 's|^EXPECTED_MOUNT=.*|EXPECTED_MOUNT="/particao-nao-montada"|' "$DATA/config/paths.conf"
expect_rc 5 "particao esperada nao montada -> nao escreve" "$HELPER"
expect_rc 5 "manager: idem (selecao interna)" env KAWAII_ROOT="$R" bash -c "mv '$HELPER' '$HELPER.off'; '$MGR' --randomize; rc=\$?; mv '$HELPER.off' '$HELPER'; exit \$rc"
check "  wallpaper anterior preservado" cmp -s "$T/before.png" "$THEME/background.png"
sed -i "s|^EXPECTED_MOUNT=.*|EXPECTED_MOUNT=\"$(stat -c %m "$THEME")\"|" "$DATA/config/paths.conf"
mkdir -p "$R/etc"; printf '/dev/sdz1 /boot vfat defaults 0 2\n' > "$R/etc/fstab"
expect_rc 5 "/boot declarado no fstab mas nao montado -> nao escreve" "$HELPER"
rm -f "$R/etc/fstab"
chmod 000 "$DATA/bundles/gothic/backgrounds/background1.png"
for i in 1 2 3 4 5 6; do "$HELPER" -q 2>/dev/null; done
check "imagem ilegivel e ignorada, outras usadas" bash -c "! grep -q 'gothic/background1.png' '$DATA/state/last-background' && png=\$(od -An -tx1 -N4 '$THEME/background.png' | tr -d ' '); [[ \$png == 89504e47 ]]"
chmod 644 "$DATA/bundles/gothic/backgrounds/background1.png"
if unshare -rm true 2>/dev/null; then
    expect_rc 0 "helper com o tema bind-montado (como ReadWritePaths= do systemd)" \
        unshare -rm bash -c "mount --bind '$THEME' '$THEME' && KAWAII_ROOT='$R' '$HELPER' -q"
    expect_rc 0 "manager com o tema bind-montado" \
        unshare -rm bash -c "mount --bind '$THEME' '$THEME' && mv '$HELPER' '$HELPER.off'; KAWAII_ROOT='$R' KAWAII_SKIP_ROOT_CHECK=1 '$MGR' --randomize; rc=\$?; mv '$HELPER.off' '$HELPER'; exit \$rc"
fi
check "troca de wallpaper nunca executa grub-mkconfig" test ! -e "$T/grub-mkconfig.log"
check "tema incompleto (sem tones/): theme.txt intacto" cmp -s "$PKG/grub-theme/theme.txt" "$THEME/theme.txt"
expect_rc 0 "helper funciona sem o manager no PATH" env -i PATH=/usr/bin:/bin KAWAII_ROOT="$R" "$HELPER" -q

section "Servico systemd"
: > "$T/systemctl.log"
expect_rc 0 "--install-service" "$MGR" --install-service
UNIT="$R/usr/lib/systemd/system/grub-random-bg.service"
check "unidade com caminho real do tema" grep -q 'RequiresMountsFor=/boot/grub/themes/kawaii-arch-theme ' "$UNIT"
check "nao habilitada automaticamente" test ! -e "$T/systemctl.enabled"
check "daemon-reload executado" grep -qx daemon-reload "$T/systemctl.log"
: > "$T/systemctl.log"
expect_rc 0 "--install-service idempotente" "$MGR" --install-service
check "sem daemon-reload quando nada muda" bash -c "! grep -q daemon-reload '$T/systemctl.log'"
expect_rc 0 "--enable-service" "$MGR" --enable-service
check "habilitado" test -e "$T/systemctl.enabled"
expect_rc 4 "--uninstall helper bloqueado pelo servico" "$MGR" --yes --uninstall helper
expect_rc 0 "--disable-service" "$MGR" --disable-service
expect_rc 0 "--update (nada a fazer)" "$MGR" --yes --update
expect_rc 0 "--uninstall service" "$MGR" --yes --uninstall service
expect_rc 0 "--uninstall helper" "$MGR" --yes --uninstall helper
check "bundles e configuracao preservados" bash -c "[[ -d '$DATA/bundles/gothic' && -f '$DATA/config/preferences.conf' ]]"
expect_rc 0 "--remove-bundle big" "$MGR" --yes --remove-bundle big
check "bundle removido" test ! -e "$DATA/bundles/big"
if command -v systemd-analyze >/dev/null; then
    sed 's|@THEME_DIR@|/boot/grub/themes/kawaii-arch-theme|g' "$PKG/systemd/grub-random-bg.service.in" > "$T/grub-random-bg.service"
    check "systemd-analyze verify (sintaxe da unidade)" bash -c "! systemd-analyze verify '$T/grub-random-bg.service' 2>&1 | grep -v -e 'not executable' -e 'No such file' -e 'not found' -e 'Failed to prepare' -e 'Command .* is not' | grep -q ."
fi
unset KAWAII_ROOT

# --- Instalador ------------------------------------------------------
# Pacote de teste: copia do pacote com bundles sinteticos (os bundles reais
# nao fazem parte do repositorio)
PKGT="$T/pkg"; mkdir -p "$PKGT"
cp -r "$PKG/install.sh" "$PKG/grub-theme" "$PKG/helper" "$PKG/systemd" "$PKG/manager" "$PKG/tools" "$PKG/config" "$PKGT/"
rm -rf "$PKGT/manager/build" "$PKGT/manager/out"
mkbundle "$PKGT/bundles/alpha" alpha 1.0.0 3 Alpha
mkbundle "$PKGT/bundles/beta" beta 1.0.0 2 Beta
mkbundle "$PKGT/bundles/gamma" gamma 1.0.0 2 Gamma

section "Tom do tema (claro/escuro) e logo"
TS="$T/tones"; mkdir -p "$TS"
mksolid "$TS/white.png" 2 8 255 255
mksolid "$TS/black.png" 2 8 0 0
expect_rc 0 "--tone funciona sem instalacao (somente leitura)" env -u KAWAII_ROOT "$MGR" --tone "$TS/white.png"
check "--tone: branco -> light" bash -c "[[ \$('$MGR' --tone '$TS/white.png') == light ]]"
check "--tone: preto -> dark" bash -c "[[ \$('$MGR' --tone '$TS/black.png') == dark ]]"
for spec in "0 8" "0 16" "2 16" "4 8" "4 16" "6 8" "6 16"; do
    set -- $spec
    mksolid "$TS/w-$1-$2.png" "$1" "$2" 255 255; mksolid "$TS/k-$1-$2.png" "$1" "$2" 0 0
    check "--tone: cor $1, $2 bits (branco light, preto dark)" bash -c "[[ \$('$MGR' --tone '$TS/w-$1-$2.png') == light && \$('$MGR' --tone '$TS/k-$1-$2.png') == dark ]]"
done
mksolid "$TS/clear.png" 6 8 255 255 0
check "--tone: branco totalmente transparente (fundo preto) -> dark" bash -c "[[ \$('$MGR' --tone '$TS/clear.png') == dark ]]"
mksolid "$TS/menu-white.png" 2 8 255 0
mksolid "$TS/menu-black.png" 2 8 0 255
check "--tone: so a area do menu/logo conta (claro a esquerda -> light)" bash -c "[[ \$('$MGR' --tone '$TS/menu-white.png') == light ]]"
check "--tone: so a area do menu/logo conta (escuro a esquerda -> dark)" bash -c "[[ \$('$MGR' --tone '$TS/menu-black.png') == dark ]]"
mksolid "$TS/mid.png" 2 8 110 110
mksolid "$TS/mid2.png" 2 8 140 140
check "--tone: limiar entre cinza medio escuro (110) e claro (140)" bash -c "[[ \$('$MGR' --tone '$TS/mid.png') == dark && \$('$MGR' --tone '$TS/mid2.png') == light ]]"
mksolid "$TS/inter.png" 2 8 255 255 255 1
expect_rc 3 "--tone: PNG entrelacado e recusado" "$MGR" --tone "$TS/inter.png"
head -c 300 "$TS/white.png" > "$TS/trunc.png"
expect_rc 3 "--tone: PNG truncado e recusado" "$MGR" --tone "$TS/trunc.png"
python3 -I -c 'import sys
d = bytearray(open(sys.argv[1], "rb").read())
i = d.find(b"IDAT") + 8
d[i:i + 40] = b"\xff" * 40
open(sys.argv[2], "wb").write(d)' "$TS/white.png" "$TS/corrupt.png"
expect_rc 3 "--tone: dados compactados corrompidos sao recusados" "$MGR" --tone "$TS/corrupt.png"
expect_rc 3 "--tone: arquivo que nao e PNG" "$MGR" --tone "$PKG/README.md"
ln -sf "$TS/white.png" "$TS/link.png"
expect_rc 3 "--tone: link simbolico e recusado" "$MGR" --tone "$TS/link.png"

# Sandbox com o tema completo do pacote
R2="$T/tone-root"
TT="$R2/boot/grub/themes/kawaii-arch-theme"
TD="$R2/var/lib/kawaii-arch-manager"
mkdir -p "$R2/boot/grub/themes" "$TD/config" "$TD/state" "$R2/usr/bin" "$R2/etc" \
    "$R2/usr/share/kawaii-arch-manager/payload"
cp -r "$PKG/grub-theme" "$TT"
cp "$MGR" "$R2/usr/bin/"
cp "$PKG/helper/grub-random-bg.sh" "$R2/usr/share/kawaii-arch-manager/payload/"
printf 'THEME_DIR="/boot/grub/themes/kawaii-arch-theme"\nEXPECTED_MOUNT="%s"\n' "$(stat -c %m "$TT")" > "$TD/config/paths.conf"
mkdir -p "$TD/bundles/tons/backgrounds"
printf 'ID="tons"\nVERSION="1.0.0"\n' > "$TD/bundles/tons/manifest.conf"
cp "$TS/white.png" "$TD/bundles/tons/backgrounds/claro.png"
cp "$TS/black.png" "$TD/bundles/tons/backgrounds/escuro.png"
printf 'ID=arch\n' > "$R2/etc/os-release"
H2="$PKG/helper/grub-random-bg.sh"
fixed() { printf 'MODE="fixed"\nSELECTED_BACKGROUND="tons/%s"\n' "$1" > "$TD/config/preferences.conf"; }
logo_of() { sed -n -E 's/^[^#]*file[[:space:]]*=[[:space:]]*"logos\/([^"]+)".*/\1/p' "$TT/theme.txt"; }
same_icons() { local f; for f in "$PKG/grub-theme/icon-sets/$1"/*.png; do cmp -s "$f" "$TT/icons/${f##*/}" || return 1; done; }

check "pacote: icons/ = icon-sets/dark (tom padrao)" bash -c "diff -r -x .tone '$PKG/grub-theme/icons' '$PKG/grub-theme/icon-sets/dark' && [[ \$(cat '$PKG/grub-theme/icons/.tone') == dark ]]"
check "pacote: tones/dark e tones/light com as mesmas pecas" bash -c "diff <(cd '$PKG/grub-theme/tones/dark' && ls) <(cd '$PKG/grub-theme/tones/light' && ls)"
check "pacote: icon-sets/dark e icon-sets/light com os mesmos icones" bash -c "diff <(cd '$PKG/grub-theme/icon-sets/dark' && ls) <(cd '$PKG/grub-theme/icon-sets/light' && ls)"
check "pacote: todos os caminhos do theme.txt existem" bash -c "cd '$PKG/grub-theme' && for p in \$(grep -v '^[[:space:]]*#' theme.txt | grep -oE '\"(tones|logos)/[^\"]+\"' | tr -d '\"'); do ls \$p >/dev/null 2>&1 || { echo \$p; exit 1; }; done"

export KAWAII_ROOT="$R2"
fixed claro.png
expect_rc 0 "wallpaper claro aplicado" "$H2" -q
check "  tom light: icons/.tone" bash -c "[[ \$(cat '$TT/icons/.tone') == light ]]"
check "  icones = icon-sets/light" same_icons light
check "  theme.txt usa tones/light/ (molduras, selecao, barra)" bash -c "[[ \$(grep -v '^[[:space:]]*#' '$TT/theme.txt' | grep -c '\"tones/light/') == 4 && \$(grep -v '^[[:space:]]*#' '$TT/theme.txt' | grep -c 'tones/dark/') == 0 ]]"
check "  cores do menu de tones/light/colors.conf" bash -c "grep -q ' item_color = \"#1c1c22\"' '$TT/theme.txt' && grep -q 'selected_item_color = \"#000000\"' '$TT/theme.txt'"
check "  logo arch-light.png" test "$(logo_of)" = arch-light.png
check "  so as 7 linhas gerenciadas mudaram" test "$(diff "$PKG/grub-theme/theme.txt" "$TT/theme.txt" | grep -c '^>')" = 7
check "  comentarios preservados" bash -c "diff <(grep '^#' '$PKG/grub-theme/theme.txt') <(grep '^#' '$TT/theme.txt')"
check "  sem temporarios no tema" bash -c "! find '$TT' -name '*.tmp' | grep -q ."
ino="$(stat -c %i "$TT/theme.txt")"; icon_ino="$(stat -c %i "$TT/icons/arch.png")"
expect_rc 0 "mesmo tom de novo" "$H2" -q
check "  theme.txt e icones nao sao reescritos sem mudanca" bash -c "[[ \$(stat -c %i '$TT/theme.txt') == $ino && \$(stat -c %i '$TT/icons/arch.png') == $icon_ino ]]"
fixed escuro.png
expect_rc 0 "wallpaper escuro aplicado" "$H2" -q
check "  tom dark: theme.txt identico ao do pacote" cmp -s "$PKG/grub-theme/theme.txt" "$TT/theme.txt"
check "  icones = icon-sets/dark" same_icons dark
check "  marcador dark" bash -c "[[ \$(cat '$TT/icons/.tone') == dark ]]"

# Copia de icones interrompida: sem marcador, a proxima execucao completa
fixed claro.png; "$H2" -q
cp "$PKG/grub-theme/icon-sets/dark/arch.png" "$TT/icons/arch.png"; rm -f "$TT/icons/.tone"
"$H2" -q
check "copia interrompida e completada na execucao seguinte" same_icons light

printf 'NAME="EndeavourOS"\nID="endeavouros"\nID_LIKE="arch"\n' > "$R2/etc/os-release"
"$H2" -q
check "distro sem logo proprio (ID_LIKE=arch) -> logo do Arch" test "$(logo_of)" = arch-light.png
cp "$TT/logos/arch-light.png" "$TT/logos/endeavouros-light.png"
"$H2" -q
check "distro com logos/<id>-<tom>.png usa o proprio logo" test "$(logo_of)" = endeavouros-light.png
rm -f "$TT/logos/endeavouros-light.png"
printf 'ID="../../x"\nID_LIKE="debian"\n' > "$R2/etc/os-release"
"$H2" -q
check "ID invalido/desconhecido -> fallback arch" test "$(logo_of)" = arch-light.png
rm -f "$R2/etc/os-release"
"$H2" -q
check "sem os-release -> fallback arch" test "$(logo_of)" = arch-light.png

sed -i '/^# >>> logo/,/^# <<< logo/{/^# >>> logo/b;/^# <<< logo/b;s/^/#[logo] /}' "$TT/theme.txt"
fixed escuro.png; "$H2" -q
check "logo desativado pelo instalador tambem acompanha o tom" bash -c "grep -q '^#\[logo\] .*file = \"logos/arch-dark.png\"' '$TT/theme.txt' && ! sed -n '/# >>> logo/,/# <<< logo/p' '$TT/theme.txt' | grep -q '^+ image'"
cp "$PKG/grub-theme/theme.txt" "$TT/theme.txt"

fixed claro.png
mv "$R2/usr/bin/kawaii-arch-manager" "$T/mgr.off"
expect_rc 0 "helper sem o manager" "$H2" -q
check "  sem o manager o tom e dark" bash -c "[[ \$(cat '$TT/icons/.tone') == dark ]] && cmp -s '$PKG/grub-theme/theme.txt' '$TT/theme.txt'"
mv "$T/mgr.off" "$R2/usr/bin/kawaii-arch-manager"
expect_rc 0 "--retone so reajusta o tom do wallpaper ativo" "$H2" --retone -q
check "  tom light sem trocar o wallpaper" bash -c "[[ \$(cat '$TT/icons/.tone') == light ]] && cmp -s '$TS/white.png' '$TT/background.png'"
expect_rc 2 "--retone --dry-run e recusado" "$H2" --retone --dry-run

expect_rc 0 "manager sem helper instalado: --set-background escuro" "$MGR" --set-background tons/escuro.png
check "  tom ajustado pelo helper do payload" bash -c "[[ \$(cat '$TT/icons/.tone') == dark ]] && cmp -s '$PKG/grub-theme/theme.txt' '$TT/theme.txt'"
check "  --status mostra o tom" bash -c "'$MGR' --status | grep -q 'Tom do tema .*dark'"
check "tom nunca executa grub-mkconfig" test ! -e "$T/grub-mkconfig.log"
export KAWAII_ROOT="$R"

section "Logo e contorno do menu (manager)"
export KAWAII_ROOT="$R2"
cp "$PKG/grub-theme/theme.txt" "$TT/theme.txt"
fixed escuro.png; "$H2" -q
menu_active() { sed -n '/^+ boot_menu/,/^}/p' "$TT/theme.txt" | grep -v '^[[:space:]]*#' | grep -E '^[[:space:]]*(left|top|width|height|menu_pixmap_style)[[:space:]]*=' | sed 's/^[[:space:]]*//' | tr '\n' ';'; }
check "pacote: contorno ligado (limites +16 e menu_pixmap_style)" test "$(menu_active)" = 'left = 5%-16;top = 36%-16;width = 522;height = 44%+32;menu_pixmap_style = "tones/dark/boot_menu_box_*.png";'
expect_rc 2 "--menu-box com valor invalido" "$MGR" --menu-box talvez
expect_rc 2 "--logo sem valor" "$MGR" --logo
if ((EUID != 0)); then
    expect_rc 5 "--menu-box exige root" env -u KAWAII_SKIP_ROOT_CHECK "$MGR" --menu-box off
fi
expect_rc 0 "--dry-run --menu-box off" "$MGR" --dry-run --menu-box off
check "  dry-run nao altera o theme.txt" cmp -s "$PKG/grub-theme/theme.txt" "$TT/theme.txt"
expect_rc 0 "--menu-box off" "$MGR" --menu-box off
check "  sem contorno: limites originais 5%, 36%, 490, 44% e sem menu_pixmap_style" test "$(menu_active)" = 'left = 5%;top = 36%;width = 490;height = 44%;'
check "  so as linhas dos dois blocos mudaram (9)" test "$(diff "$PKG/grub-theme/theme.txt" "$TT/theme.txt" | grep -c '^>')" = 9
check "  --status mostra o contorno desligado" bash -c "'$MGR' --status | grep -q 'Contorno do menu .*desligado'"
ino="$(stat -c %i "$TT/theme.txt")"
expect_rc 0 "--menu-box off de novo" "$MGR" --menu-box off
check "  sem mudanca, o theme.txt nao e reescrito" test "$(stat -c %i "$TT/theme.txt")" = "$ino"
fixed claro.png; "$H2" -q
check "contorno desligado acompanha o tom (linha comentada em tones/light/)" grep -q '^#\[menu\] .*menu_pixmap_style = "tones/light/boot_menu_box_\*.png"' "$TT/theme.txt"
expect_rc 0 "--menu-box on com o tom light" "$MGR" --menu-box on
check "  contorno religado ja no tom light" bash -c "[[ \"\$1\" == *'menu_pixmap_style = \"tones/light/boot_menu_box_*.png\";' ]]" _ "$(menu_active)"
fixed escuro.png; "$H2" -q
check "off + on devolve o theme.txt do pacote" cmp -s "$PKG/grub-theme/theme.txt" "$TT/theme.txt"
expect_rc 0 "--logo off" "$MGR" --logo off
check "  logo desativado (+ image comentado)" bash -c "! sed -n '/^# >>> logo/,/^# <<< logo/p' '$TT/theme.txt' | grep -q '^+ image' && grep -q '^#\[logo\] + image' '$TT/theme.txt'"
check "  --status mostra o logo desligado" bash -c "'$MGR' --status | grep -qE '^ +Logo +desligado'"
expect_rc 0 "--logo on" "$MGR" --logo on
check "  logo religado: theme.txt do pacote" cmp -s "$PKG/grub-theme/theme.txt" "$TT/theme.txt"
sed '/menu-box$/d' "$PKG/grub-theme/theme.txt" > "$TT/theme.txt"
expect_rc 3 "tema sem os marcadores (versao antiga) e recusado" "$MGR" --menu-box off
check "  tema antigo nao e alterado" bash -c "diff <(sed '/menu-box\$/d' '$PKG/grub-theme/theme.txt') '$TT/theme.txt'"
cp "$PKG/grub-theme/theme.txt" "$TT/theme.txt"
check "sem temporarios no tema" bash -c "! find '$TT' -name '*.tmp*' | grep -q ."
export KAWAII_ROOT="$R"

section "Preferencias (preferences.conf) e --reload-confs"
export KAWAII_ROOT="$R2"
PF="$TD/config/preferences.conf"
cp "$PKG/grub-theme/theme.txt" "$TT/theme.txt"
cp "$PKG/config/preferences.conf" "$PF"
ncom() { grep -c '^#' "$PF"; }
com_before="$(ncom)"
check "modelo do pacote: todas as chaves e valores padrao" bash -c "for kv in 'MODE=\"global\"' 'LOGO=\"on\"' 'MENU_BOX=\"on\"' 'TONE=\"auto\"' 'SELECTED_BUNDLE=\"\"' 'SELECTED_BACKGROUND=\"\"'; do grep -qx \"\$kv\" '$PF' || exit 1; done"
expect_rc 0 "--set-background grava no preferences.conf" "$MGR" --set-background tons/claro.png
check "  MODE e SELECTED_BACKGROUND gravados no lugar" bash -c "grep -qx 'MODE=\"fixed\"' '$PF' && grep -qx 'SELECTED_BACKGROUND=\"tons/claro.png\"' '$PF'"
check "  comentarios do arquivo preservados" test "$(ncom)" = "$com_before"
check "  nenhum backgrounds.conf criado" test ! -e "$TD/config/backgrounds.conf"
expect_rc 0 "--logo off grava LOGO=\"off\"" "$MGR" --logo off
check "  LOGO=\"off\" e logo desligado no tema" bash -c "grep -qx 'LOGO=\"off\"' '$PF' && grep -q '^#\[logo\] + image' '$TT/theme.txt'"
expect_rc 0 "--logo on" "$MGR" --logo on
check "  so as linhas alteradas diferem do modelo" test "$(diff "$PKG/config/preferences.conf" "$PF" | grep -c '^>')" = 2
echo 'CHAVE_EXTRA="x"' >> "$PF"
out="$("$MGR" --logo on 2>&1)"
check "ON_FRESH_INSTALL do modelo nao gera aviso de chave desconhecida" bash -c "! grep -q 'chave desconhecida' <<< \"\$1\"" _ "$out"
expect_rc 0 "--menu-box off com chave desconhecida no arquivo" "$MGR" --menu-box off
check "  chave desconhecida mantida e MENU_BOX gravado" bash -c "grep -qx 'CHAVE_EXTRA=\"x\"' '$PF' && grep -qx 'MENU_BOX=\"off\"' '$PF'"
"$MGR" --menu-box on >/dev/null 2>&1

# Edicao manual + --reload-confs
sed -i 's/^LOGO=.*/LOGO="off"/; s/^MENU_BOX=.*/MENU_BOX="off"/' "$PF"
check "--status avisa que o tema difere das preferencias" bash -c "'$MGR' --status | grep -q 'reload-confs'"
cp "$TT/theme.txt" "$T/theme.before"
out="$("$MGR" --dry-run --reload-confs 2>&1)"; rc=$?
check "--dry-run --reload-confs (rc=0) lista as mudancas" bash -c "[[ $rc == 0 ]] && grep -q 'Logo: ligado -> desligado' <<< \"\$1\" && grep -q 'Contorno do menu: ligado -> desligado' <<< \"\$1\"" _ "$out"
check "  dry-run nao altera o tema" cmp -s "$T/theme.before" "$TT/theme.txt"
out="$("$MGR" --reload-confs 2>&1)"; rc=$?
check "--reload-confs aplica (rc=0) e avisa chave desconhecida" bash -c "[[ $rc == 0 ]] && grep -q 'chave desconhecida ignorada: CHAVE_EXTRA' <<< \"\$1\"" _ "$out"
check "  logo e contorno desligados no theme.txt" bash -c "'$MGR' --status | grep -qE '^ +Logo +desligado' && '$MGR' --status | grep -qE '^ +Contorno do menu +desligado'"
check "  --status sem pendencia" bash -c "! '$MGR' --status | grep -q 'Pendente'"
ino="$(stat -c %i "$TT/theme.txt")"
out="$("$MGR" --reload-confs 2>&1)"
check "--reload-confs de novo: nada a fazer, theme.txt intacto" bash -c "grep -q 'nada a fazer' <<< \"\$1\" && [[ \$(stat -c %i '$TT/theme.txt') == $ino ]]" _ "$out"
sed -i 's/^ON_FRESH_INSTALL=.*/ON_FRESH_INSTALL="talvez"/' "$PF"
cp "$TT/theme.txt" "$T/theme.before"
expect_rc 3 "ON_FRESH_INSTALL invalido: --reload-confs recusa" "$MGR" --reload-confs
sed -i 's/^ON_FRESH_INSTALL=.*/ON_FRESH_INSTALL="backup"/' "$PF"
sed -i 's/^LOGO=.*/LOGO="on"/; s/^MENU_BOX=.*/MENU_BOX="talvez"/' "$PF"
cp "$TT/theme.txt" "$T/theme.before"
expect_rc 3 "valor invalido: --reload-confs recusa" "$MGR" --reload-confs
check "  nada aplicado (nem o LOGO valido)" cmp -s "$T/theme.before" "$TT/theme.txt"
sed -i 's/^MENU_BOX=.*/MENU_BOX="on"/; s/^MODE=.*/MODE="set"/; s/^SELECTED_BUNDLE=.*/SELECTED_BUNDLE="nao-existe"/' "$PF"
expect_rc 3 "bundle inexistente no modo set: recusa" "$MGR" --reload-confs
check "  nada aplicado" cmp -s "$T/theme.before" "$TT/theme.txt"
sed -i 's/^MODE=.*/MODE="fixed"/; s/^SELECTED_BUNDLE=.*/SELECTED_BUNDLE=""/; s/^SELECTED_BACKGROUND=.*/SELECTED_BACKGROUND="tons\/escuro.png"/' "$PF"
expect_rc 0 "modo fixed editado: --reload-confs" "$MGR" --reload-confs
check "  wallpaper fixo aplicado e tom dark" bash -c "cmp -s '$TS/black.png' '$TT/background.png' && [[ \$(cat '$TT/icons/.tone') == dark ]]"
check "  logo e contorno religados" cmp -s "$PKG/grub-theme/theme.txt" "$TT/theme.txt"
sed -i 's/^TONE=.*/TONE="light"/' "$PF"
out="$("$MGR" --reload-confs 2>&1)"
check "TONE=light forca o tom num wallpaper escuro" bash -c "[[ \$(cat '$TT/icons/.tone') == light ]] && grep -q 'Tom: dark -> light' <<< \"\$1\"" _ "$out"
"$H2" -q
check "  o helper tambem respeita TONE" bash -c "[[ \$(cat '$TT/icons/.tone') == light ]]"
sed -i 's/^TONE=.*/TONE="auto"/' "$PF"
"$MGR" --reload-confs >/dev/null 2>&1
check "TONE=auto volta a medir (dark)" bash -c "[[ \$(cat '$TT/icons/.tone') == dark ]]"
sed -i 's/^MODE=.*/MODE="global"/' "$PF"
sha_bg="$(sha256sum < "$TT/background.png")"
expect_rc 0 "modo global: --reload-confs" "$MGR" --reload-confs
check "  global nao sorteia um wallpaper novo" test "$sha_bg" = "$(sha256sum < "$TT/background.png")"
mv "$PF" "$T/prefs.off"
expect_rc 3 "sem preferences.conf: --reload-confs recusa" "$MGR" --reload-confs
expect_rc 3 "sem preferences.conf: helper da erro de configuracao" "$H2" -q
mv "$T/prefs.off" "$PF"
if ((EUID != 0)); then
    expect_rc 5 "--reload-confs exige root" env -u KAWAII_SKIP_ROOT_CHECK "$MGR" --reload-confs
fi
cp "$PKG/grub-theme/theme.txt" "$TT/theme.txt"
export KAWAII_ROOT="$R"

section "Instalador: instalacao completa"
L="$T/full-root"
LT="$L/boot/grub/themes/kawaii-arch-theme"
LD="$L/var/lib/kawaii-arch-manager"
mkdir -p "$L/boot/grub" "$L/etc/default"
printf 'GRUB_TIMEOUT=5\nGRUB_GFXMODE=auto\nGRUB_THEME="/boot/grub/themes/kawaii-arch-theme/theme.txt"\n' > "$L/etc/default/grub"
printf 'insmod gfxterm\nloadfont ($root)/grub/themes/kawaii-arch-theme/%s\n' $(cd "$PKG/grub-theme" && ls *.pf2) > "$L/boot/grub/grub.cfg"
echo 'set theme=($root)/grub/themes/kawaii-arch-theme/theme.txt' >> "$L/boot/grub/grub.cfg"
rm -f "$T/systemctl.enabled"; : > "$T/systemctl.log"
export KAWAII_ROOT="$L" KAWAII_SYSTEMCTL="$T/systemctl"
expect_rc 0 "install.sh --yes --enable-service" "$PKGT/install.sh" --yes --enable-service
check "--yes instala todos os bundles do pacote" bash -c "[[ \"\$(cd '$PKGT/bundles' && ls -d */ | tr -d / | sort)\" == \"\$(cd '$LD/bundles' && ls -d */ | tr -d / | sort)\" ]]"
check "theme.txt aponta para background.png" grep -qx 'desktop-image: "background.png"' "$LT/theme.txt"
check "fallback.png instalado" test -f "$LT/fallback.png"
check "background.png veio de um bundle instalado" bash -c "for f in '$LD'/bundles/*/backgrounds/*.png; do cmp -s \"\$f\" '$LT/background.png' && exit 0; done; exit 1"
check "configuracao inicial MODE=global" grep -qx 'MODE="global"' "$LD/config/preferences.conf"
check "preferences.conf criado a partir do modelo comentado" bash -c "grep -q 'reload-confs' '$LD/config/preferences.conf' && grep -qx 'LOGO=\"on\"' '$LD/config/preferences.conf' && grep -qx 'MENU_BOX=\"on\"' '$LD/config/preferences.conf'"
check "modelo das preferencias no payload" cmp -s "$PKG/config/preferences.conf" "$L/usr/share/kawaii-arch-manager/payload/preferences.conf"
check "manager compilado instalado em /usr/bin" bash -c "[[ \$('$L/usr/bin/kawaii-arch-manager' --version) == 'kawaii-arch-manager 1.5.0' ]]"
check "helper e unidade instalados" bash -c "[[ -x '$L/usr/lib/kawaii-arch-manager/grub-random-bg.sh' && -f '$L/usr/lib/systemd/system/grub-random-bg.service' ]]"
check "servico habilitado (--enable-service)" test -e "$T/systemctl.enabled"
check "grub-mkconfig nao executado (nada exigia)" test ! -e "$T/grub-mkconfig.log"
check "logo ativado por padrao" bash -c "sed -n '/# >>> logo/,/# <<< logo/p' '$LT/theme.txt' | grep -q '^+ image'"
check "tom do tema coerente com o wallpaper ativo" bash -c "[[ \$(cat '$LT/icons/.tone') == \$('$L/usr/bin/kawaii-arch-manager' --tone '$LT/background.png') ]]"
sha_before="$(cd "$L" && find . -type f ! -path './var/lib/kawaii-arch-manager/state/*' -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
: > "$T/systemctl.log"
expect_rc 0 "segunda execucao (idempotente)" "$PKGT/install.sh" --yes
sha_after="$(cd "$L" && find . -type f ! -path './var/lib/kawaii-arch-manager/state/*' -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
check "nenhum arquivo alterado na segunda execucao" test "$sha_before" = "$sha_after"
check "sem daemon-reload/enable/disable na segunda execucao" bash -c "! grep -qE 'daemon-reload|^enable|^disable' '$T/systemctl.log'"
check "servico continua habilitado" test -e "$T/systemctl.enabled"
check "manager instalado gerencia a sandbox" "$L/usr/bin/kawaii-arch-manager" --list-bundles

section "Instalador: atualizacao do tema"
bg_before="$(sha256sum < "$LT/background.png")"
echo 1.9.0 > "$LT/VERSION"; echo '# antigo' >> "$LT/theme.txt"
expect_rc 0 "tema v1.9.0 -> versao do pacote" "$PKGT/install.sh" --yes
check "VERSION atualizada" cmp -s "$PKG/grub-theme/VERSION" "$LT/VERSION"
check "theme.txt substituido pelo do pacote" bash -c "! grep -q '^# antigo' '$LT/theme.txt'"
check "wallpaper ativo preservado na atualizacao" test "$bg_before" = "$(sha256sum < "$LT/background.png")"
check "sem diretorios temporarios em themes/" bash -c "! ls -A '$L/boot/grub/themes' | grep -q '^\.'"
echo 9.0.0 > "$LT/VERSION"
out="$("$PKGT/install.sh" --yes 2>&1)"
check "sem downgrade do tema" grep -q 'mais novo que o do pacote' <<< "$out"
cp "$PKG/grub-theme/VERSION" "$LT/VERSION"

section "Instalador: contorno do menu"
lmenu() { sed -n '/^+ boot_menu/,/^}/p' "$LT/theme.txt" | grep -v '^[[:space:]]*#' | grep -c 'menu_pixmap_style'; }
check "contorno ligado por padrao" test "$(lmenu)" = 1
expect_rc 0 "--no-menu-box" "$PKGT/install.sh" --yes --no-menu-box
check "  contorno desligado" test "$(lmenu)" = 0
check "  MENU_BOX=\"off\" gravado nas preferencias" grep -qx 'MENU_BOX="off"' "$LD/config/preferences.conf"
check "  limites originais ativos" bash -c "sed -n '/^+ boot_menu/,/^}/p' '$LT/theme.txt' | grep -qx '  width = 490'"
sha_before="$(cd "$L" && find . -type f ! -path './var/lib/kawaii-arch-manager/state/*' -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
expect_rc 0 "nova execucao sem a opcao preserva o estado" "$PKGT/install.sh" --yes
check "  nada alterado (idempotente)" test "$sha_before" = "$(cd "$L" && find . -type f ! -path './var/lib/kawaii-arch-manager/state/*' -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
echo 1.9.0 > "$LT/VERSION"
expect_rc 0 "atualizacao do tema" "$PKGT/install.sh" --yes
check "  atualizacao preserva o contorno desligado" test "$(lmenu)" = 0
sed -i 's/^LOGO=.*/LOGO="off"/' "$LD/config/preferences.conf"
expect_rc 0 "LOGO=\"off\" editado: o instalador segue as preferencias" "$PKGT/install.sh" --yes
check "  logo desligado no tema" bash -c "! sed -n '/^# >>> logo/,/^# <<< logo/p' '$LT/theme.txt' | grep -q '^+ image'"
expect_rc 0 "--logo religa e grava" "$PKGT/install.sh" --yes --logo
check "  LOGO=\"on\"" grep -qx 'LOGO="on"' "$LD/config/preferences.conf"
if command -v script >/dev/null; then
    out="$(printf 's\n' | KAWAII_ROOT="$L" script -qec "'$PKGT/install.sh' --no-logo --bundles all --no-components" /dev/null 2>&1)"
    check "pergunta sobre o contorno no modo interativo (padrao: estado atual)" grep -q 'contorno de vidro em volta do menu de boot? \[s/N\]' <<< "$out"
fi

section "Instalador: instalacao limpa (--fresh)"
check "modelo: ON_FRESH_INSTALL=\"backup\" por padrao" grep -qx 'ON_FRESH_INSTALL="backup"' "$PKG/config/preferences.conf"
setfresh() { sed -i '/^ON_FRESH_INSTALL=/d' "$LD/config/preferences.conf"; [[ -z "$1" ]] || echo "ON_FRESH_INSTALL=\"$1\"" >> "$LD/config/preferences.conf"; }
treesum() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum); }
"$L/usr/bin/kawaii-arch-manager" --yes --import-bundle "$T/noname.kawall" >/dev/null 2>&1
printf 'MODE="set"\nSELECTED_BUNDLE="noname"\nSELECTED_BACKGROUND=""\nLOGO="on"\nMENU_BOX="off"\nTONE="auto"\n# comentario do usuario\n' > "$LD/config/preferences.conf"
echo 'noname/background1.png' > "$LD/state/last-background"
cp "$LD/bundles/noname/backgrounds/background1.png" "$LT/background.png"
echo '# personalizado' >> "$LT/theme.txt"
touch "$T/systemctl.enabled"
grub_before="$(cat "$L/etc/default/grub" "$L/boot/grub/grub.cfg" | sha256sum)"
expect_rc 1 "--fresh com --uninstall e recusado" "$PKGT/install.sh" --fresh --uninstall --yes
expect_rc 1 "--keep-config nao existe mais" "$PKGT/install.sh" --fresh --yes --keep-config
snap() { (cd "$L" && find . -print0 | sort -z | xargs -0 stat -c '%n %s %Y' 2>/dev/null; find . -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum; }
setfresh talvez
s0="$(snap)"
out="$("$PKGT/install.sh" --fresh --yes 2>&1)"; rc=$?
check "ON_FRESH_INSTALL invalido: aborta (rc=1)" bash -c "[[ $rc == 1 ]] && grep -q 'ON_FRESH_INSTALL invalido' <<< \"\$1\"" _ "$out"
check "  nada foi alterado" test "$s0" = "$(snap)"
if command -v script >/dev/null; then
    setfresh backup
    s0="$(snap)"
    printf 'n\n' | KAWAII_ROOT="$L" script -qec "'$PKGT/install.sh' --fresh --no-logo --menu-box --bundles all --no-components" /dev/null >/dev/null 2>&1
    check "--fresh cancelado na confirmacao nao altera nada" test "$s0" = "$(snap)"
fi

# backup (sem a chave: padrao do pacote)
setfresh ""
conf_before="$(sha256sum < "$LD/config/preferences.conf")"
bundles_before="$(treesum "$LD/bundles")"
out="$("$PKGT/install.sh" --fresh --yes 2>&1)"; rc=$?
check "backup (padrao): --fresh --yes (rc=0)" test "$rc" = 0
check "  resumo mostra o modo e a origem" grep -q 'ON_FRESH_INSTALL="backup" (padrao do pacote)' <<< "$out"
check "  bundles.old = bundles anteriores (inclusive o importado)" test "$bundles_before" = "$(treesum "$LD/bundles.old")"
check "  config.old/preferences.conf = preferencias anteriores" test "$conf_before" = "$(sha256sum < "$LD/config.old/preferences.conf")"
check "  bundles = exatamente os do pacote" bash -c "[[ \"\$(cd '$PKGT/bundles' && ls -d */ | tr -d / | sort)\" == \"\$(cd '$LD/bundles' && ls -d */ | tr -d / | sort)\" ]]"
check "  preferencias recriadas com os padroes" bash -c "grep -qx 'MODE=\"global\"' '$LD/config/preferences.conf' && grep -qx 'ON_FRESH_INSTALL=\"backup\"' '$LD/config/preferences.conf'"
check "  contorno do menu volta ao padrao (ligado)" bash -c "sed -n '/^+ boot_menu/,/^}/p' '$LT/theme.txt' | grep -v '^[[:space:]]*#' | grep -q menu_pixmap_style"
check "  estado anterior apagado" test ! -e "$LD/state/last-background"
check "  theme.txt igual ao do pacote (personalizacao descartada)" bash -c "! grep -q '^# personalizado' '$LT/theme.txt'"
check "  tema sem .old" bash -c "! ls -A '$L/boot/grub/themes' | grep -q old"
check "  componentes reinstalados" bash -c "[[ -x '$L/usr/bin/kawaii-arch-manager' && -x '$L/usr/lib/kawaii-arch-manager/grub-random-bg.sh' && -f '$L/usr/lib/systemd/system/grub-random-bg.service' ]]"
check "  servico nao volta habilitado sem --enable-service" test ! -e "$T/systemctl.enabled"
check "  /etc/default/grub e grub.cfg preservados" test "$grub_before" = "$(cat "$L/etc/default/grub" "$L/boot/grub/grub.cfg" | sha256sum)"
check "  sem diretorios temporarios restantes" bash -c "! ls -A '$LD' '$LD/bundles' '$L/boot/grub/themes' | grep -q '^\.'"
check "  bundles.old fora do --list-bundles" bash -c "! KAWAII_ROOT='$L' '$L/usr/bin/kawaii-arch-manager' --list-bundles | grep -q noname"
expect_rc 0 "recupera o bundle de bundles.old com --import-bundle" "$L/usr/bin/kawaii-arch-manager" --yes --import-bundle "$LD/bundles.old/noname"
check "  bundle recuperado" test -f "$LD/bundles/noname/manifest.conf"

# backup de novo: substitui os .old
bundles_before="$(treesum "$LD/bundles")"
out="$("$PKGT/install.sh" --fresh --yes --enable-service 2>&1)"; rc=$?
check "backup de novo (rc=0) avisa que substitui o backup anterior" bash -c "[[ $rc == 0 ]] && grep -q 'backup anterior .*bundles.old sera substituido' <<< \"\$1\"" _ "$out"
check "  bundles.old = bundles do backup mais recente" test "$bundles_before" = "$(treesum "$LD/bundles.old")"
check "  servico habilitado com --enable-service" test -e "$T/systemctl.enabled"

# override: apaga; os .old existentes ficam
old_sum="$(treesum "$LD/bundles.old")"
"$L/usr/bin/kawaii-arch-manager" --yes --import-bundle "$T/noname.kawall" >/dev/null 2>&1
setfresh override
out="$("$PKGT/install.sh" --fresh --yes 2>&1)"; rc=$?
check "override (rc=0) avisa que o bundle fora do pacote sera perdido" bash -c "[[ $rc == 0 ]] && grep -q 'serao perdidos: noname' <<< \"\$1\"" _ "$out"
check "  bundle importado apagado" test ! -e "$LD/bundles/noname"
check "  .old existentes intactos" test "$old_sum" = "$(treesum "$LD/bundles.old")"
check "  preferencias recriadas (MODE=global)" grep -qx 'MODE="global"' "$LD/config/preferences.conf"

# keep: nada em DATA_DIR muda
"$L/usr/bin/kawaii-arch-manager" --yes --import-bundle "$T/noname.kawall" >/dev/null 2>&1
printf 'MODE="set"\nSELECTED_BUNDLE="noname"\nSELECTED_BACKGROUND=""\nLOGO="on"\nMENU_BOX="off"\nTONE="auto"\nON_FRESH_INSTALL="keep"\n' > "$LD/config/preferences.conf"
echo 'noname/background1.png' > "$LD/state/last-background"
cp "$LD/bundles/noname/backgrounds/background1.png" "$LT/background.png"
rm -rf "$LD/bundles/$(cd "$PKGT/bundles" && ls -d */ | tr -d / | sort | head -n1)"
conf_before="$(sha256sum < "$LD/config/preferences.conf")"
nn_before="$(treesum "$LD/bundles/noname")"
bg_before="$(sha256sum < "$LT/background.png")"
out="$("$PKGT/install.sh" --fresh --yes 2>&1)"; rc=$?
check "keep (rc=0)" test "$rc" = 0
check "  preferences.conf identico" test "$conf_before" = "$(sha256sum < "$LD/config/preferences.conf")"
check "  bundle importado identico" test "$nn_before" = "$(treesum "$LD/bundles/noname")"
check "  estado da rotacao mantido" grep -qx 'noname/background1.png' "$LD/state/last-background"
check "  wallpaper ativo mantido" test "$bg_before" = "$(sha256sum < "$LT/background.png")"
check "  contorno do menu segue MENU_BOX=\"off\"" bash -c "! sed -n '/^+ boot_menu/,/^}/p' '$LT/theme.txt' | grep -v '^[[:space:]]*#' | grep -q menu_pixmap_style"
check "  bundle do pacote ausente foi instalado" bash -c "[[ \"\$(cd '$PKGT/bundles' && ls -d */ | tr -d / | sort)\" == \"\$(cd '$LD/bundles' && ls -d */ | tr -d / | grep -v noname | sort)\" ]]"
check "  componentes reinstalados" test -x "$L/usr/bin/kawaii-arch-manager"
check "  paths.conf regenerado" grep -q '^THEME_DIR="/boot/grub/themes/kawaii-arch-theme"' "$LD/config/paths.conf"
check "  copia temporaria do wallpaper removida" bash -c "! ls -A '$LD' | grep -q '^\.'"
check "  helper funciona com os dados mantidos" bash -c "KAWAII_ROOT='$L' '$L/usr/lib/kawaii-arch-manager/grub-random-bg.sh' --dry-run --quiet >/dev/null"
check "--status mostra ON_FRESH_INSTALL" bash -c "KAWAII_ROOT='$L' '$L/usr/bin/kawaii-arch-manager' --status | grep -qE 'ON_FRESH_INSTALL +keep'"
setfresh backup

expect_rc 0 "--uninstall --yes" "$PKGT/install.sh" --uninstall --yes
check "tema e componentes removidos, dados preservados" bash -c "[[ ! -e '$LT' && -d '$LD/bundles' && ! -e '$L/usr/bin/kawaii-arch-manager' && ! -e '$L/usr/lib/systemd/system/grub-random-bg.service' ]]"
check "servico desabilitado na remocao" test ! -e "$T/systemctl.enabled"
check "--uninstall preserva os .old" bash -c "[[ -d '$LD/bundles.old' && -d '$LD/config.old' ]]"

section "Instalador: dependencia servico -> helper"
S="$T/svc-root"; mkdir -p "$S/boot/grub"
export KAWAII_ROOT="$S"
expect_rc 0 "--without-helper --with-service --without-manager" "$PKGT/install.sh" --yes --without-helper --with-service --without-manager
check "servico nao instalado sem o helper" test ! -e "$S/usr/lib/systemd/system/grub-random-bg.service"
check "/boot contem so um wallpaper ativo + fallback" bash -c "[[ \$(find '$S/boot' -name '*.png' -path '*kawaii*' ! -path '*/icons/*' ! -path '*/icon-sets/*' ! -path '*/tones/*' ! -path '*/logos/*' | wc -l) == 2 ]]"
check "sem o manager o tom instalado e dark" bash -c "[[ \$(cat '$S/boot/grub/themes/kawaii-arch-theme/icons/.tone') == dark ]]"
expect_rc 0 "--with-helper --with-service sem --enable-service" "$PKGT/install.sh" --yes --with-helper --with-service --without-manager
check "servico instalado mas nao habilitado" bash -c "[[ -f '$S/usr/lib/systemd/system/grub-random-bg.service' && ! -e '$T/systemctl.enabled' ]]"
unset KAWAII_ROOT

section "Instalador: selecao de bundles"
bundle_dirs() { [[ -d "$1" ]] && (cd "$1" && ls -d */ 2>/dev/null | tr -d / | sort | tr '\n' ' '); }
K="$T/sel-none"; mkdir -p "$K/boot/grub"
export KAWAII_ROOT="$K"
expect_rc 0 "--no-bundles" "$PKGT/install.sh" --yes --no-components --no-bundles
check "nenhum bundle instalado" test -z "$(bundle_dirs "$K/var/lib/kawaii-arch-manager/bundles")"
check "background.png = wallpaper padrao do pacote" cmp -s "$PKG/grub-theme/background.png" "$K/boot/grub/themes/kawaii-arch-theme/background.png"
K="$T/sel-list"; mkdir -p "$K/boot/grub"
export KAWAII_ROOT="$K"
mkdir -p "$T/sel-src"
first="$(cd "$PKGT/bundles" && ls -d */ | tr -d / | sort | head -n1)"
last="$(cd "$PKGT/bundles" && ls -d */ | tr -d / | sort | tail -n1)"
expect_rc 0 "--bundles $last,1 (ID e numero)" "$PKGT/install.sh" --yes --no-components --bundles "$last,1"
check "somente os bundles escolhidos" test "$(bundle_dirs "$K/var/lib/kawaii-arch-manager/bundles")" = "$(printf '%s\n' "$first" "$last" | sort -u | tr '\n' ' ')"
check "background.png veio de um bundle escolhido" bash -c "for f in '$K'/var/lib/kawaii-arch-manager/bundles/*/backgrounds/*.png; do cmp -s \"\$f\" '$K/boot/grub/themes/kawaii-arch-theme/background.png' && exit 0; done; exit 1"
for id in $(bundle_dirs "$K/var/lib/kawaii-arch-manager/bundles"); do
    check "bundle $id instalado igual ao do pacote" bash -c "[[ \"\$(cd '$PKGT/bundles/$id/backgrounds' && ls *.png)\" == \"\$(cd '$K/var/lib/kawaii-arch-manager/bundles/$id/backgrounds' && ls *.png)\" ]] && cmp -s '$PKGT/bundles/$id/manifest.conf' '$K/var/lib/kawaii-arch-manager/bundles/$id/manifest.conf'"
done
K="$T/sel-bad"; mkdir -p "$K/boot/grub"
export KAWAII_ROOT="$K"
expect_rc 1 "--bundles com ID inexistente e recusado" "$PKGT/install.sh" --yes --no-components --bundles nao-existe
check "nada instalado apos a recusa" test ! -e "$K/boot/grub/themes/kawaii-arch-theme"

section "Instalador: pacote sem bundles"
P2="$T/pkg-nobundles"; mkdir -p "$P2/bundles/quebrado/backgrounds"
cp -r "$PKGT/install.sh" "$PKG/grub-theme" "$PKG/helper" "$PKG/systemd" "$PKG/manager" "$PKG/config" "$P2/"
printf 'ID="outro"\nVERSION="1.0.0"\n' > "$P2/bundles/quebrado/manifest.conf"
mkpng "$P2/bundles/quebrado/backgrounds/background1.png"
K="$T/nobundles-root"; mkdir -p "$K/boot/grub"
export KAWAII_ROOT="$K"
out="$("$P2/install.sh" --yes --no-components 2>&1)"; rc=$?
check "instalacao segue sem bundles (rc=0)" test "$rc" = 0
check "bundle invalido do pacote e ignorado com aviso" grep -q 'bundles/quebrado ignorado' <<< "$out"
check "nenhum bundle instalado" test -z "$(bundle_dirs "$K/var/lib/kawaii-arch-manager/bundles")"
check "background.png = wallpaper padrao do pacote" cmp -s "$P2/grub-theme/background.png" "$K/boot/grub/themes/kawaii-arch-theme/background.png"
unset KAWAII_ROOT

printf '\n\e[1mResultado: %d ok, %d falha(s)\e[0m\n' "$PASS" "$FAIL"
((KEEP)) && echo "sandbox mantida em $T"
((FAIL == 0))
