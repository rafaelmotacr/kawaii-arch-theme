#!/usr/bin/env bash
# =====================================================================
#  grub-random-bg.sh - Background Helper do Kawaii Arch Theme
#
#  Seleciona um wallpaper de acordo com a configuracao persistente e o
#  copia atomicamente para <tema>/background.png. Funciona sem o
#  kawaii-arch-manager: le diretamente a configuracao e os bundles.
#
#  Depois de aplicar, ajusta o tema a claridade do wallpaper (tom "dark"
#  para wallpaper escuro, "light" para wallpaper claro): copia para
#  <tema>/icons/ o conjunto de <tema>/icon-sets/<tom>/ e reescreve no
#  theme.txt somente as cores do menu, os caminhos tones/<tom>/ e o logo
#  (logos/<distro>-<tom>.png, distro lida de /etc/os-release; fallback:
#  arch). A claridade e medida por 'kawaii-arch-manager --tone'; sem o
#  manager, o tom e sempre "dark" (o visual padrao do tema).
#
#  Uso:
#    grub-random-bg.sh              seleciona e aplica um wallpaper
#    grub-random-bg.sh --retone     so reaplica o tom/logo do wallpaper ativo
#    grub-random-bg.sh --dry-run    apenas mostra o que seria aplicado
#    grub-random-bg.sh --quiet      sem mensagens informativas
#    grub-random-bg.sh --version    mostra a versao
#
#  Arquivos (somente leitura, exceto onde indicado):
#    /var/lib/kawaii-arch-manager/config/paths.conf       THEME_DIR, EXPECTED_MOUNT
#    /var/lib/kawaii-arch-manager/config/backgrounds.conf MODE, SELECTED_BUNDLE,
#                                                         SELECTED_BACKGROUND
#    /var/lib/kawaii-arch-manager/bundles/<id>/           bundles instalados
#    /var/lib/kawaii-arch-manager/state/last-background   (escrita)
#    <THEME_DIR>/background.png                           (escrita)
#    <THEME_DIR>/theme.txt, <THEME_DIR>/icons/            (escrita: tom/logo)
#
#  Codigos de saida:
#    0 wallpaper aplicado          3 configuracao invalida / nenhuma imagem
#    1 falha operacional             elegivel (wallpaper anterior preservado)
#    2 argumento invalido          4 outra execucao em andamento (lock)
#                                  5 sem permissao / particao nao montada
#
#  Nunca executa grub-mkconfig nem altera os bundles; no theme.txt so
#  troca os valores gerenciados pelo tom (e so quando mudam).
# =====================================================================

set -uo pipefail
umask 022
export LC_ALL=C

# Versao do helper (SemVer). Lida como texto pelo instalador e pelo
# manager (sem executar o script): mantenha o formato VERSION="x.y.z".
VERSION="2.1.1"

readonly E_OK=0 E_FAIL=1 E_USAGE=2 E_CONFIG=3 E_BUSY=4 E_PERM=5

# KAWAII_ROOT prefixa todos os caminhos (somente para testes em sandbox).
ROOT="${KAWAII_ROOT:-}"
DATA_DIR="$ROOT/var/lib/kawaii-arch-manager"
BUNDLES_DIR="$DATA_DIR/bundles"
CONF_DIR="$DATA_DIR/config"
STATE_DIR="$DATA_DIR/state"
BG_CONF="$CONF_DIR/backgrounds.conf"
PATHS_CONF="$CONF_DIR/paths.conf"
LAST_FILE="$STATE_DIR/last-background"
LOCK_FILE="$STATE_DIR/apply.lock"
THEME_NAME="kawaii-arch-theme"
ACTIVE_NAME="background.png"
FALLBACK_NAME="fallback.png"

ID_RE='^[a-z0-9][a-z0-9_-]{0,63}$'
IMG_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,250}\.png$'

DRY_RUN=0
QUIET=0
RETONE=0

# --- Mensagens --------------------------------------------------------
# Sob o systemd, stdout/stderr vao para o journal; o prefixo <N> define
# a prioridade (SyslogLevelPrefix=yes e o padrao).
JOURNAL=0
[[ -n "${INVOCATION_ID:-}" || -n "${JOURNAL_STREAM:-}" ]] && JOURNAL=1

log_info() {
    ((QUIET)) && return 0
    if ((JOURNAL)); then echo "<6>$*"; else echo "grub-random-bg: $*"; fi
}
log_warn() {
    if ((JOURNAL)); then echo "<4>aviso: $*" >&2; else echo "grub-random-bg: aviso: $*" >&2; fi
}
log_err() {
    if ((JOURNAL)); then echo "<3>erro: $*" >&2; else echo "grub-random-bg: erro: $*" >&2; fi
}

usage() { sed -n '2,/^# =====/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

# --- Argumentos -------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --version|-V) echo "$VERSION"; exit $E_OK ;;
        --help|-h)    usage; exit $E_OK ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --quiet|-q)   QUIET=1 ;;
        --retone)     RETONE=1 ;;
        *) log_err "opcao desconhecida: $arg (use --help)"; exit $E_USAGE ;;
    esac
done

# --- Configuracao (KEY="valor"; nunca usa 'source') -------------------
# conf_get ARQUIVO CHAVE -> define CONF_VALUE e retorna 0 se a chave existe
CONF_VALUE=""
conf_get() {
    local file="$1" key="$2" line found=1 re_q re_u
    # valor entre aspas (sem " $ ` \) ou sem aspas (sem espacos/aspas)
    re_q='^[[:space:]]*'"$key"'="([^"$`\\]*)"[[:space:]]*$'
    re_u='^[[:space:]]*'"$key"'=([^"'"'"'[:space:]$`\\]*)[[:space:]]*$'
    CONF_VALUE=""
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ $re_q ]] || [[ "$line" =~ $re_u ]]; then
            CONF_VALUE="${BASH_REMATCH[1]}"
            found=0
        fi
    done < "$file"
    return $found
}

# --- Validacao de PNG (assinatura + IHDR compativel com o GRUB) -------
# O leitor PNG do GRUB aceita somente profundidade 8/16, cor gray/RGB/
# gray+alpha/RGBA, sem entrelacamento.
png_ok() {
    local f="$1" hex
    [[ -f "$f" && -r "$f" && ! -L "$f" ]] || return 1
    hex="$(od -An -tx1 -N29 -v -- "$f" 2>/dev/null | tr -d ' \n')" || return 1
    ((${#hex} == 58)) || return 1
    [[ "${hex:0:16}" == "89504e470d0a1a0a" && "${hex:24:8}" == "49484452" ]] || return 1
    ((16#${hex:32:8} > 0 && 16#${hex:40:8} > 0)) || return 1
    [[ "${hex:48:2}" == "08" || "${hex:48:2}" == "10" ]] || return 1
    case "${hex:50:2}" in 00|02|04|06) ;; *) return 1 ;; esac
    [[ "${hex:52:2}" == "00" && "${hex:54:2}" == "00" && "${hex:56:2}" == "00" ]]
}

# --- Aleatoriedade uniforme -------------------------------------------
# rand_below N -> RAND (0..N-1). Usa SRANDOM (bash >= 5.1, 32 bits) com
# rejeicao para evitar vies de modulo; senao recorre ao shuf.
RAND=0
rand_below() {
    local n="$1" r lim
    if ((n <= 1)); then RAND=0; return; fi
    if [[ -n "${SRANDOM:-}" ]]; then
        lim=$((4294967296 - 4294967296 % n))
        while r=$SRANDOM; ((r >= lim)); do :; done
        RAND=$((r % n))
    else
        RAND="$(shuf -i "0-$((n - 1))" -n 1)"
    fi
}

# --- Caminho do tema --------------------------------------------------
THEME_RAW=""        # caminho real (sem KAWAII_ROOT)
THEME_DIR=""        # caminho efetivo
EXPECTED_MOUNT=""

resolve_theme_dir() {
    if conf_get "$PATHS_CONF" THEME_DIR && [[ -n "$CONF_VALUE" ]]; then
        THEME_RAW="$CONF_VALUE"
    else
        local cand
        for cand in /boot/grub/themes/$THEME_NAME /boot/grub2/themes/$THEME_NAME; do
            if [[ -f "$ROOT$cand/theme.txt" ]]; then THEME_RAW="$cand"; break; fi
        done
        if [[ -z "$THEME_RAW" ]]; then
            log_err "diretorio do tema desconhecido: $PATHS_CONF ausente e tema nao encontrado em /boot/grub{,2}/themes (particao de boot montada?)"
            return 1
        fi
        log_warn "$PATHS_CONF ausente; usando $THEME_RAW"
    fi
    if [[ "$THEME_RAW" != /* || "$THEME_RAW" == *"/../"* || "$THEME_RAW" == *"/.." ]]; then
        log_err "THEME_DIR invalido em $PATHS_CONF: \"$THEME_RAW\""
        return 1
    fi
    THEME_DIR="$ROOT$THEME_RAW"
    conf_get "$PATHS_CONF" EXPECTED_MOUNT && EXPECTED_MOUNT="$CONF_VALUE"
    return 0
}

# --- Verificacao de montagem ------------------------------------------
# Impede escrever no diretorio subjacente quando a particao que contem
# o tema nao esta montada.
check_mount() {
    if [[ ! -d "$THEME_DIR" || ! -f "$THEME_DIR/theme.txt" ]]; then
        log_err "tema nao encontrado em $THEME_DIR (particao de boot montada?)"
        return 1
    fi
    local actual actual_raw
    actual="$(stat -c %m -- "$THEME_DIR" 2>/dev/null)" || {
        log_err "nao foi possivel determinar o ponto de montagem de $THEME_DIR"
        return 1
    }
    actual_raw="${actual#"$ROOT"}"; [[ -z "$actual_raw" ]] && actual_raw="/"

    if [[ -n "$EXPECTED_MOUNT" && "$actual_raw" != "$EXPECTED_MOUNT" ]]; then
        log_err "$THEME_RAW esta em '$actual_raw', mas era esperado '$EXPECTED_MOUNT' (particao nao montada?)"
        return 1
    fi

    # Ponto de montagem mais especifico declarado no fstab para o tema
    local fstab="$ROOT/etc/fstab" best="" mp
    if [[ -r "$fstab" ]]; then
        while read -r _ mp _; do
            [[ "$mp" == /* && "$mp" != "/" ]] || continue
            mp="${mp%/}"
            [[ "$THEME_RAW" == "$mp" || "$THEME_RAW" == "$mp"/* ]] || continue
            ((${#mp} > ${#best})) && best="$mp"
        done < <(grep -v -E '^[[:space:]]*(#|$)' "$fstab")
        if [[ -n "$best" && "$actual_raw" != "$best" ]]; then
            log_err "$best esta declarado no fstab, mas nao esta montado (tema em '$actual_raw')"
            return 1
        fi
    fi
    return 0
}

# --- Bundles ----------------------------------------------------------
# Um bundle e utilizavel se o diretorio tem nome valido, nao e link,
# possui manifest.conf com o mesmo ID e um diretorio backgrounds/.
bundle_usable() {
    local id="$1" dir="$BUNDLES_DIR/$1"
    [[ "$id" =~ $ID_RE && -d "$dir" && ! -L "$dir" && -d "$dir/backgrounds" && ! -L "$dir/backgrounds" ]] || return 1
    conf_get "$dir/manifest.conf" ID && [[ "$CONF_VALUE" == "$id" ]]
}

# list_bundles -> BUNDLES=(id ...)
BUNDLES=()
list_bundles() {
    BUNDLES=()
    local d id
    [[ -d "$BUNDLES_DIR" ]] || return 0
    for d in "$BUNDLES_DIR"/*/; do
        [[ -d "$d" ]] || continue
        id="$(basename "$d")"
        if bundle_usable "$id"; then
            BUNDLES+=("$id")
        elif [[ "$id" != .* ]]; then
            log_warn "bundle '$id' ignorado (estrutura ou manifest.conf invalido)"
        fi
    done
}

# bundle_images ID -> IMAGES=(nome.png ...) candidatos (validacao do PNG
# e feita somente na imagem sorteada, para manter o boot rapido)
IMAGES=()
bundle_images() {
    IMAGES=()
    local f name
    shopt -s nullglob
    for f in "$BUNDLES_DIR/$1/backgrounds/"*.png; do
        name="${f##*/}"
        [[ "$name" =~ $IMG_RE && -f "$f" && ! -L "$f" ]] && IMAGES+=("$name")
    done
    shopt -u nullglob
}

# --- Selecao ----------------------------------------------------------
LAST=""
CHOSEN=""        # "id/nome.png"

# pick_from_list "id/img" ... -> CHOSEN; evita LAST se houver alternativa,
# descarta imagens invalidas e sorteia novamente (uniforme entre validas)
pick_from_list() {
    local -a cand=() rest=()
    local item had_last=0
    for item in "$@"; do
        if [[ -n "$LAST" && "$item" == "$LAST" ]]; then had_last=1; else cand+=("$item"); fi
    done
    while ((${#cand[@]} > 0)); do
        rand_below "${#cand[@]}"
        item="${cand[RAND]}"
        if png_ok "$BUNDLES_DIR/${item%%/*}/backgrounds/${item#*/}"; then
            CHOSEN="$item"; return 0
        fi
        log_warn "imagem invalida ou ilegivel ignorada: $item"
        rest=("${cand[@]:0:RAND}" "${cand[@]:RAND+1}")
        cand=("${rest[@]}")
    done
    if ((had_last)) && png_ok "$BUNDLES_DIR/${LAST%%/*}/backgrounds/${LAST#*/}"; then
        CHOSEN="$LAST"; return 0
    fi
    return 1
}

select_fixed() {
    local sel id name
    conf_get "$BG_CONF" SELECTED_BACKGROUND; sel="$CONF_VALUE"
    if [[ -z "$sel" ]]; then log_err "modo 'fixed' sem SELECTED_BACKGROUND"; return 1; fi
    id="${sel%%/*}"; name="${sel#*/}"
    [[ "$sel" == */* ]] && [[ "$id" =~ $ID_RE ]] && [[ "$name" =~ $IMG_RE ]] || {
        log_err "SELECTED_BACKGROUND invalido: \"$sel\" (esperado ID/arquivo.png)"; return 1; }
    bundle_usable "$id" || { log_err "bundle '$id' de SELECTED_BACKGROUND nao esta instalado ou e invalido"; return 1; }
    png_ok "$BUNDLES_DIR/$id/backgrounds/$name" || { log_err "imagem fixa ausente ou invalida: $sel"; return 1; }
    CHOSEN="$id/$name"
}

select_set() {
    local id img; local -a all=()
    conf_get "$BG_CONF" SELECTED_BUNDLE; id="$CONF_VALUE"
    if [[ -z "$id" ]]; then log_err "modo 'set' sem SELECTED_BUNDLE"; return 1; fi
    bundle_usable "$id" || { log_err "bundle selecionado '$id' nao esta instalado ou e invalido; atualize a configuracao (kawaii-arch-manager --set-bundle)"; return 1; }
    bundle_images "$id"
    for img in "${IMAGES[@]}"; do all+=("$id/$img"); done
    ((${#all[@]})) || { log_err "bundle '$id' nao possui imagens"; return 1; }
    pick_from_list "${all[@]}" || { log_err "nenhuma imagem valida no bundle '$id'"; return 1; }
}

select_global() {
    local id img; local -a all=()
    list_bundles
    for id in "${BUNDLES[@]}"; do
        bundle_images "$id"
        for img in "${IMAGES[@]}"; do all+=("$id/$img"); done
    done
    ((${#all[@]})) || { log_err "modo 'global': nenhuma imagem em nenhum bundle"; return 1; }
    pick_from_list "${all[@]}" || { log_err "modo 'global': nenhuma imagem valida"; return 1; }
}

# balanced: bundle uniforme, depois imagem uniforme dentro dele.
select_balanced() {
    local -A pool=()
    local id img item last_ok=0
    local -a ids=() imgs=() keep=()
    list_bundles
    for id in "${BUNDLES[@]}"; do
        bundle_images "$id"
        imgs=()
        for img in "${IMAGES[@]}"; do
            if [[ "$id/$img" == "$LAST" ]]; then last_ok=1; else imgs+=("$img"); fi
        done
        if ((${#imgs[@]})); then pool[$id]="${imgs[*]}"; ids+=("$id"); fi
    done
    while ((${#ids[@]} > 0)); do
        rand_below "${#ids[@]}"; id="${ids[RAND]}"
        read -r -a imgs <<< "${pool[$id]}"
        rand_below "${#imgs[@]}"; img="${imgs[RAND]}"
        if png_ok "$BUNDLES_DIR/$id/backgrounds/$img"; then
            CHOSEN="$id/$img"; return 0
        fi
        log_warn "imagem invalida ou ilegivel ignorada: $id/$img"
        keep=()
        for item in "${imgs[@]}"; do [[ "$item" != "$img" ]] && keep+=("$item"); done
        if ((${#keep[@]})); then
            pool[$id]="${keep[*]}"
        else
            unset 'pool[$id]'
            keep=()
            for item in "${ids[@]}"; do [[ "$item" != "$id" ]] && keep+=("$item"); done
            ids=("${keep[@]}")
        fi
    done
    if ((last_ok)) && png_ok "$BUNDLES_DIR/${LAST%%/*}/backgrounds/${LAST#*/}"; then
        CHOSEN="$LAST"; return 0
    fi
    log_err "modo 'balanced': nenhum bundle com imagens validas"
    return 1
}

select_image() {
    local mode
    if [[ ! -r "$BG_CONF" ]]; then
        log_err "configuracao ausente ou ilegivel: $BG_CONF"
        return 1
    fi
    conf_get "$BG_CONF" MODE; mode="${CONF_VALUE:-set}"
    if [[ -r "$LAST_FILE" ]]; then
        IFS= read -r LAST < "$LAST_FILE" || true
        [[ "$LAST" == */* ]] || LAST=""
    fi
    case "$mode" in
        fixed)    select_fixed ;;
        set)      select_set ;;
        global)   select_global ;;
        balanced) select_balanced ;;
        *) log_err "MODE invalido em $BG_CONF: \"$mode\" (fixed|set|global|balanced)"; return 1 ;;
    esac
}

# --- Aplicacao atomica ------------------------------------------------
# copia -> background.png.tmp (mesmo diretorio = mesmo filesystem) ->
# valida -> rename(2) sobre background.png. O original nunca e alterado.
apply_file() {
    local src="$1" dst="$THEME_DIR/$ACTIVE_NAME" tmp="$THEME_DIR/$ACTIVE_NAME.tmp"
    png_ok "$src" || { log_err "origem invalida: $src"; return 1; }
    rm -f -- "$tmp"
    if ! cp --no-preserve=all -- "$src" "$tmp" 2>/dev/null; then
        rm -f -- "$tmp"
        log_err "falha ao copiar $src para $tmp"
        return 1
    fi
    chmod 0644 -- "$tmp" 2>/dev/null
    if [[ "$(stat -c %s -- "$src")" != "$(stat -c %s -- "$tmp")" ]] || ! png_ok "$tmp"; then
        rm -f -- "$tmp"
        log_err "copia verificada falhou (tamanho/cabecalho divergente); wallpaper anterior preservado"
        return 1
    fi
    sync -- "$tmp" 2>/dev/null || sync
    if ! mv -fT -- "$tmp" "$dst"; then
        rm -f -- "$tmp"
        log_err "falha ao substituir $dst; wallpaper anterior preservado"
        return 1
    fi
    sync -- "$THEME_DIR" 2>/dev/null || sync
    return 0
}

save_last() {
    local tmp="$LAST_FILE.tmp"
    if printf '%s\n' "$1" > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$LAST_FILE"; then
        return 0
    fi
    rm -f -- "$tmp"
    log_warn "nao foi possivel atualizar $LAST_FILE"
}

# Sem selecao valida: preserva background.png valido; se nao houver,
# aplica fallback.png.
apply_fallback() {
    if png_ok "$THEME_DIR/$ACTIVE_NAME"; then
        log_warn "wallpaper ativo preservado sem alteracoes"
        return 0
    fi
    if png_ok "$THEME_DIR/$FALLBACK_NAME"; then
        if apply_file "$THEME_DIR/$FALLBACK_NAME"; then
            log_warn "wallpaper ativo ausente/invalido; $FALLBACK_NAME aplicado"
            return 0
        fi
    fi
    log_err "nenhum wallpaper valido disponivel (nem $ACTIVE_NAME nem $FALLBACK_NAME)"
    return 1
}

# --- Tom (claro/escuro) e logo ----------------------------------------
# O tom e o do WALLPAPER: "dark" (escuro: texto/icones claros, o padrao do
# tema) ou "light" (claro: texto/icones escuros). Falhas aqui nunca
# desfazem o wallpaper: no pior caso o tema fica no tom anterior.
TONE_RE='^(dark|light)$'
COLOR_RE='^#[0-9A-Fa-f]{6}$'
DISTRO_RE='^[a-z0-9][a-z0-9._-]{0,63}$'

# measure_tone ARQUIVO -> TONE (dark se o manager nao estiver disponivel)
TONE="dark"
measure_tone() {
    local mgr="" out
    TONE="dark"
    if [[ -x "$ROOT/usr/bin/kawaii-arch-manager" ]]; then
        mgr="$ROOT/usr/bin/kawaii-arch-manager"
    elif [[ -z "$ROOT" ]]; then
        mgr="$(command -v kawaii-arch-manager 2>/dev/null)" || mgr=""
    fi
    if [[ -z "$mgr" ]]; then
        log_info "kawaii-arch-manager ausente; tom padrao (dark)"
        return 0
    fi
    out="$("$mgr" --tone "$1" 2>/dev/null)" || out=""
    if [[ "$out" =~ $TONE_RE ]]; then
        TONE="$out"
    else
        log_warn "nao foi possivel medir a claridade de $1; tom padrao (dark)"
    fi
}

# pick_logo -> LOGO (nome em logos/) ou "" se nenhum logo existir.
# Ordem: ID, cada ID_LIKE e, por fim, arch (fallback oficial).
LOGO=""
pick_logo() {
    local f cand ids=""
    LOGO=""
    for f in "$ROOT/etc/os-release" "$ROOT/usr/lib/os-release"; do
        [[ -r "$f" ]] || continue
        conf_get "$f" ID && ids="$CONF_VALUE"
        conf_get "$f" ID_LIKE && ids="$ids $CONF_VALUE"
        break
    done
    for cand in $ids arch; do
        [[ "$cand" =~ $DISTRO_RE ]] || continue
        if png_ok "$THEME_DIR/logos/$cand-$TONE.png"; then
            LOGO="$cand-$TONE.png"; return 0
        fi
    done
}

# sync_icons: icons/ <- icon-sets/<tom>/ (arquivo a arquivo, atomico; o
# GRUB so le icones de icons/). O marcador icons/.tone sai antes da copia
# e volta por ultimo: uma copia interrompida fica sem marcador e e
# completada na proxima execucao (arquivos iguais nao sao reescritos).
sync_icons() {
    local set="$THEME_DIR/icon-sets/$TONE" dst="$THEME_DIR/icons" cur="" f name changed=0
    [[ -d "$set" && ! -L "$set" ]] || return 0
    [[ -r "$dst/.tone" ]] && IFS= read -r cur < "$dst/.tone"
    [[ "$cur" == "$TONE" ]] && return 0
    mkdir -p -- "$dst" || return 1
    rm -f -- "$dst/.tone" || return 1
    shopt -s nullglob
    for f in "$set"/*.png; do
        name="${f##*/}"
        [[ -f "$f" && ! -L "$f" ]] || continue
        cmp -s -- "$f" "$dst/$name" && continue
        cp --no-preserve=all -- "$f" "$dst/.$name.tmp" && mv -f -- "$dst/.$name.tmp" "$dst/$name" \
            || { rm -f -- "$dst/.$name.tmp"; shopt -u nullglob; return 1; }
        changed=1
    done
    shopt -u nullglob
    ((changed)) && sync -f "$dst" 2>/dev/null
    printf '%s\n' "$TONE" > "$dst/.tone.tmp" && mv -f -- "$dst/.tone.tmp" "$dst/.tone" \
        || { rm -f -- "$dst/.tone.tmp"; return 1; }
}

# rewrite_theme: troca so os valores gerenciados do theme.txt e grava
# (atomico) apenas se algo mudou. Linhas de comentario sao preservadas,
# exceto as de blocos desativados ("#[logo] " do logo e "#[menu] " do
# contorno do menu), que tambem acompanham o tom para quando forem
# reativados.
rewrite_theme() {
    local tt="$THEME_DIR/theme.txt" tmp="$THEME_DIR/theme.txt.tmp" ic sic
    conf_get "$THEME_DIR/tones/$TONE/colors.conf" ITEM_COLOR && ic="$CONF_VALUE" || ic=""
    conf_get "$THEME_DIR/tones/$TONE/colors.conf" SELECTED_ITEM_COLOR && sic="$CONF_VALUE" || sic=""
    [[ "$ic" =~ $COLOR_RE ]] || ic=""
    [[ "$sic" =~ $COLOR_RE ]] || sic=""
    awk -v tone="$TONE" -v ic="$ic" -v sic="$sic" -v logo="$LOGO" '
        /^[[:space:]]*#/ && !/^#\[(logo|menu)\] / { print; next }
        {
            gsub(/"tones\/(dark|light)\//, "\"tones/" tone "/")
            if (ic != "" && $0 ~ /^[[:space:]]*item_color[[:space:]]*=/) sub(/"[^"]*"/, "\"" ic "\"")
            if (sic != "" && $0 ~ /^[[:space:]]*selected_item_color[[:space:]]*=/) sub(/"[^"]*"/, "\"" sic "\"")
            if (logo != "" && $0 ~ /file[[:space:]]*=[[:space:]]*"logos\//) sub(/"logos\/[^"]*"/, "\"logos/" logo "\"")
            print
        }' "$tt" > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    if cmp -s -- "$tmp" "$tt"; then rm -f -- "$tmp"; return 0; fi
    grep -qx 'desktop-image: "background.png"' "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 0644 -- "$tmp"
    sync -- "$tmp" 2>/dev/null
    mv -f -- "$tmp" "$tt" || { rm -f -- "$tmp"; return 1; }
    sync -f "$THEME_DIR" 2>/dev/null
    return 0
}

# apply_tone: mede o wallpaper ativo e ajusta icones, cores e logo.
# Temas sem tones/ (versoes antigas) sao deixados como estao.
apply_tone() {
    [[ -d "$THEME_DIR/tones/dark" && -d "$THEME_DIR/tones/light" ]] || return 0
    measure_tone "$THEME_DIR/$ACTIVE_NAME"
    pick_logo
    sync_icons || log_warn "falha ao atualizar os icones do tom $TONE"
    rewrite_theme || { log_warn "falha ao atualizar o theme.txt para o tom $TONE"; return 0; }
    log_info "tom do tema: $TONE${LOGO:+ (logo: $LOGO)}"
}

# --- Execucao ---------------------------------------------------------
main() {
    resolve_theme_dir || return $E_PERM

    if ((DRY_RUN)); then
        ((RETONE)) && { log_err "--retone nao aceita --dry-run"; return $E_USAGE; }
        if select_image; then
            echo "$CHOSEN"
            return $E_OK
        fi
        return $E_CONFIG
    fi

    if [[ ! -d "$STATE_DIR" ]]; then
        log_err "$STATE_DIR nao existe (instalacao incompleta?)"
        return $E_FAIL
    fi
    if ! exec 9>>"$LOCK_FILE"; then
        log_err "sem permissao para $LOCK_FILE (execute como root)"
        return $E_PERM
    fi
    if command -v flock >/dev/null; then
        flock -w 30 9 || { log_err "outra execucao do helper esta em andamento"; return $E_BUSY; }
    else
        log_warn "flock indisponivel; execucoes concorrentes nao sao bloqueadas"
    fi

    check_mount || return $E_PERM
    if [[ ! -w "$THEME_DIR" ]]; then
        log_err "sem permissao de escrita em $THEME_DIR (execute como root)"
        return $E_PERM
    fi
    rm -f -- "$THEME_DIR/$ACTIVE_NAME.tmp" "$THEME_DIR/theme.txt.tmp"

    if ((RETONE)); then
        png_ok "$THEME_DIR/$ACTIVE_NAME" || { log_err "wallpaper ativo ausente ou invalido"; return $E_FAIL; }
        apply_tone
        return $E_OK
    fi

    if ! select_image; then
        apply_fallback || return $E_FAIL
        apply_tone
        return $E_CONFIG
    fi

    local src="$BUNDLES_DIR/${CHOSEN%%/*}/backgrounds/${CHOSEN#*/}"
    if ! apply_file "$src"; then
        apply_fallback >/dev/null 2>&1 || true
        return $E_FAIL
    fi
    save_last "$CHOSEN"
    log_info "wallpaper aplicado: $CHOSEN"
    apply_tone
    return $E_OK
}

main
exit $?
