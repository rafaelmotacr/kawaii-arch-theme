#!/usr/bin/env bash
# =====================================================================
#  Instalador (bootstrap) do tema GRUB "kawaii-arch-theme"
#
#  Instala o tema e, opcionalmente e de forma independente:
#    - Kawaii Arch Manager  (binario compilado, /usr/bin/kawaii-arch-manager)
#    - Background Helper    (/usr/lib/kawaii-arch-manager/grub-random-bg.sh)
#    - Servico systemd      (grub-random-bg.service; exige o helper)
#  Nenhum componente e obrigatorio. Os bundles de wallpapers que vierem no
#  pacote (bundles/<id>/) sao oferecidos para instalacao, com selecao; sem
#  nenhum bundle, o tema usa o wallpaper padrao (grub-theme/background.png).
#  O gerenciamento do dia a dia (bundles, modo de selecao, wallpaper) e
#  feito pelo kawaii-arch-manager.
#
#  Uso:
#    sudo ./install.sh                       instalacao/atualizacao interativa
#    sudo ./install.sh --yes                 respostas padrao (instala os tres
#                                            componentes; so habilita o servico
#                                            se ja estava habilitado ou com
#                                            --enable-service)
#    sudo ./install.sh --fresh               instalacao limpa: apaga tema e
#                                            componentes e reinstala a partir
#                                            do pacote (pede confirmacao). Os
#                                            dados seguem ON_FRESH_INSTALL do
#                                            preferences.conf: backup (move
#                                            bundles/ e config/ para *.old),
#                                            override (apaga) ou keep (mantem)
#    sudo ./install.sh --uninstall [--purge] remove tema e componentes
#                                            (--purge apaga bundles/config)
#  Opcoes:
#    --with-manager | --without-manager
#    --with-helper  | --without-helper
#    --with-service | --without-service
#    --no-components        recusa os tres componentes opcionais
#    --bundles LISTA        bundles do pacote a instalar: all, none ou IDs
#                           separados por virgula (padrao: pergunta; com
#                           --yes, all)
#    --no-bundles           o mesmo que --bundles none
#    --enable-service       habilita o servico (consentimento explicito)
#    --logo | --no-logo     exibe/oculta o logo da distribuicao abaixo do menu
#    --menu-box | --no-menu-box
#                           exibe/oculta o contorno de vidro do menu de boot
#    --grub-dir DIR         diretorio do GRUB (padrao: detectado)
#    -h, --help
# =====================================================================

set -euo pipefail
umask 022

THEME_NAME="kawaii-arch-theme"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_THEME="$SRC_DIR/grub-theme"
SRC_BUNDLES="$SRC_DIR/bundles"
SRC_HELPER="$SRC_DIR/helper/grub-random-bg.sh"
SRC_UNIT="$SRC_DIR/systemd/grub-random-bg.service.in"
SRC_MANAGER="$SRC_DIR/manager"
SRC_PREFS="$SRC_DIR/config/preferences.conf"   # modelo comentado das preferencias

# KAWAII_ROOT: prefixo para testes em sandbox (nao toca o sistema real)
ROOT="${KAWAII_ROOT:-}"
DATA_DIR="$ROOT/var/lib/kawaii-arch-manager"
BUNDLES_DIR="$DATA_DIR/bundles"
CONF_DIR="$DATA_DIR/config"
STATE_DIR="$DATA_DIR/state"
PREFS="$CONF_DIR/preferences.conf"   # preferencias do usuario (fonte da verdade)
PATHS_CONF="$CONF_DIR/paths.conf"
LIB_DIR="$ROOT/usr/lib/kawaii-arch-manager"
HELPER_PATH="$LIB_DIR/grub-random-bg.sh"
SERVICE_NAME="grub-random-bg.service"
UNIT_PATH="$ROOT/usr/lib/systemd/system/$SERVICE_NAME"
BIN_PATH="$ROOT/usr/bin/kawaii-arch-manager"
SHARE_DIR="$ROOT/usr/share/kawaii-arch-manager"
PAYLOAD_DIR="$SHARE_DIR/payload"
DEFAULT_GRUB="$ROOT/etc/default/grub"

if [[ -n "$ROOT" ]]; then SYSTEMCTL="${KAWAII_SYSTEMCTL:-}"; else SYSTEMCTL="systemctl"; fi

ID_RE='^[a-z0-9][a-z0-9_-]{0,63}$'
IMG_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,250}\.png$'

# Opcoes
ASSUME_YES=0
OPT_MANAGER=""      # "" pergunta | 1 sim | 0 nao
OPT_HELPER=""
OPT_SERVICE=""
OPT_ENABLE=0
OPT_LOGO=""
OPT_MENU=""         # contorno do menu: "" pergunta | on | off
OPT_GRUB_DIR=""
OPT_PURGE=0
OPT_BUNDLES=""      # "" pergunta | all | none | id1,id2
FRESH=0             # --fresh: apaga tudo e reinstala

# Estado
GRUB_DEFAULT_CHANGED=0
NEED_DAEMON_RELOAD=0
declare -A RESULT=()
PKG_BUNDLES=()        # IDs validos encontrados em bundles/ do pacote
declare -A PKG_NAME=() PKG_VER=() PKG_COUNT=()
WANT_BUNDLES=()
FRESH_MODE=""          # --fresh: ON_FRESH_INSTALL (backup | override | keep)
FRESH_MODE_SRC=""      # de onde veio o valor (para o resumo)

# ---------------------------------------------------------------------
# Utilitarios
# ---------------------------------------------------------------------
if [[ -t 1 ]]; then
    c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_q=$'\e[36m'; c_b=$'\e[1m'; c_off=$'\e[0m'
else
    c_ok=; c_warn=; c_err=; c_q=; c_b=; c_off=
fi
info() { echo "${c_ok}==>${c_off} $*"; }
note() { echo "    $*"; }
warn() { echo "${c_warn}aviso:${c_off} $*" >&2; }
die()  { echo "${c_err}erro:${c_off} $*" >&2; exit 1; }
section() { echo; echo "${c_b}$*${c_off}"; }

# ask_yn "pergunta" S|N -> 0 (sim) ou 1 (nao)
ask_yn() {
    local question="$1" default="$2" hint answer
    [[ "$default" == "S" ]] && hint="[S/n]" || hint="[s/N]"
    if ((ASSUME_YES)); then
        echo "${c_q}?${c_off} $question $hint $default (automatico)"
        [[ "$default" == "S" ]]; return
    fi
    while :; do
        read -r -p "${c_q}?${c_off} $question $hint " answer || die "entrada encerrada"
        answer="${answer:-$default}"
        case "${answer,,}" in
            s|sim|y|yes) return 0 ;;
            n|nao|não|no) return 1 ;;
            *) warn "responda 's' ou 'n'" ;;
        esac
    done
}

# Remove o prefixo de sandbox de um caminho
raw_path() { local p="${1#"$ROOT"}"; echo "${p:-/}"; }

# --- Configuracao KEY="valor" (sem 'source') --------------------------
conf_get() {
    local file="$1" key="$2" line val="" re
    re='^[[:space:]]*'"$key"'="?([^"$`\\]*)"?[[:space:]]*$'
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ $re ]] && val="${BASH_REMATCH[1]}"
    done < "$file"
    printf '%s' "$val"
}

write_atomic() {   # write_atomic ARQUIVO MODO < conteudo
    local file="$1" mode="$2" tmp
    tmp="$(mktemp "$file.tmp.XXXXXX")" || return 1
    if cat > "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$file"; then return 0; fi
    rm -f "$tmp"; return 1
}

# --- PNG compativel com o leitor do GRUB ------------------------------
png_ok() {
    local f="$1" hex
    [[ -f "$f" && -r "$f" && ! -L "$f" ]] || return 1
    hex="$(od -An -tx1 -N29 -v -- "$f" 2>/dev/null | tr -d ' \n')" || return 1
    ((${#hex} == 58)) || return 1
    [[ "${hex:0:16}" == "89504e470d0a1a0a" && "${hex:24:8}" == "49484452" ]] || return 1
    ((16#${hex:32:8} > 0 && 16#${hex:40:8} > 0)) || return 1
    [[ "${hex:48:2}" == "08" || "${hex:48:2}" == "10" ]] || return 1
    case "${hex:50:2}" in 00|02|04|06) ;; *) return 1 ;; esac
    [[ "${hex:52:6}" == "000000" ]]
}

# --- Versionamento (SemVer) -------------------------------------------
semver_valid() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]
}

# Versao declarada num script, lida do texto (sem executa-lo): "" se o
# arquivo nao existe, "0.0.0" se nao ha versao valida.
script_version() {
    [[ -f "$1" ]] || return 0
    local v; v="$(sed -n -E 's/^VERSION="?([^"[:space:]]*)"?.*/\1/p' "$1" | head -n1)"
    if semver_valid "$v"; then echo "$v"; else echo "0.0.0"; fi
}

_cmp_prerelease() {
    local -a a b
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    local i x y n=$(( ${#a[@]} > ${#b[@]} ? ${#a[@]} : ${#b[@]} ))
    for ((i = 0; i < n; i++)); do
        x="${a[i]-}"; y="${b[i]-}"
        [[ -z "$x" ]] && { echo -1; return; }
        [[ -z "$y" ]] && { echo 1; return; }
        if [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]]; then
            ((10#$x < 10#$y)) && { echo -1; return; }
            ((10#$x > 10#$y)) && { echo 1; return; }
        elif [[ "$x" =~ ^[0-9]+$ ]]; then echo -1; return
        elif [[ "$y" =~ ^[0-9]+$ ]]; then echo 1; return
        else
            [[ "$x" < "$y" ]] && { echo -1; return; }
            [[ "$x" > "$y" ]] && { echo 1; return; }
        fi
    done
    echo 0
}

# semver_cmp A B -> -1 (A<B), 0 (A=B) ou 1 (A>B); invalida = 0.0.0
semver_cmp() {
    local a="$1" b="$2"
    semver_valid "$a" || a="0.0.0"
    semver_valid "$b" || b="0.0.0"
    a="${a%%+*}"; b="${b%%+*}"
    local ac="${a%%-*}" bc="${b%%-*}" ap="" bp=""
    [[ "$a" == *-* ]] && ap="${a#*-}"
    [[ "$b" == *-* ]] && bp="${b#*-}"
    local -a x y
    IFS=. read -r -a x <<< "$ac"
    IFS=. read -r -a y <<< "$bc"
    local i
    for i in 0 1 2; do
        ((10#${x[i]} < 10#${y[i]})) && { echo -1; return; }
        ((10#${x[i]} > 10#${y[i]})) && { echo 1; return; }
    done
    if [[ -z "$ap" && -z "$bp" ]]; then echo 0
    elif [[ -z "$ap" ]]; then echo 1
    elif [[ -z "$bp" ]]; then echo -1
    else _cmp_prerelease "$ap" "$bp"
    fi
}


# ---------------------------------------------------------------------
# Descoberta de caminhos
# ---------------------------------------------------------------------
GRUB_RAW=""; THEME_RAW=""; THEMES_DIR=""; THEME_DIR=""; THEME_FILE=""; GRUB_CFG=""

grub_theme_value() {
    [[ -f "$DEFAULT_GRUB" ]] || return 0
    bash -c 'source "$1" >/dev/null 2>&1; echo "${GRUB_THEME:-}"' _ "$DEFAULT_GRUB"
}

discover_paths() {
    local cand="" t
    if [[ -n "$OPT_GRUB_DIR" ]]; then
        cand="${OPT_GRUB_DIR%/}"
    elif t="$(conf_get "$PATHS_CONF" THEME_DIR)" && [[ "$t" == */themes/$THEME_NAME ]]; then
        cand="${t%/themes/$THEME_NAME}"
    elif t="$(grub_theme_value)" && [[ "$t" == */themes/$THEME_NAME/theme.txt ]]; then
        cand="${t%/themes/$THEME_NAME/theme.txt}"
    else
        # o primeiro com grub.cfg; senao, o primeiro que existir
        for t in /boot/grub/grub.cfg /boot/grub2/grub.cfg /boot/grub /boot/grub2; do
            [[ -e "$ROOT$t" ]] && { cand="${t%/grub.cfg}"; break; }
        done
    fi
    [[ -n "$cand" ]] || die "diretorio do GRUB nao encontrado (/boot/grub ou /boot/grub2); use --grub-dir"
    [[ "$cand" == /* && "$cand" =~ ^[A-Za-z0-9/._+-]+$ ]] || die "caminho do GRUB invalido: $cand"
    [[ -d "$ROOT$cand" ]] || die "$cand nao existe (GRUB instalado? /boot montado?)"
    GRUB_RAW="$cand"
    THEME_RAW="$GRUB_RAW/themes/$THEME_NAME"
    THEMES_DIR="$ROOT$GRUB_RAW/themes"
    THEME_DIR="$ROOT$THEME_RAW"
    THEME_FILE="$THEME_DIR/theme.txt"
    GRUB_CFG="$ROOT$GRUB_RAW/grub.cfg"
}

# ---------------------------------------------------------------------
# Deteccao do estado atual
# ---------------------------------------------------------------------
service_enabled() {
    [[ -n "$SYSTEMCTL" ]] || return 1
    "$SYSTEMCTL" is-enabled --quiet "$SERVICE_NAME" >/dev/null 2>&1
}

theme_version() {   # versao do tema instalado ("" se ausente)
    [[ -f "$THEME_FILE" ]] || return 0
    local v; v="$(head -n1 "$THEME_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
    if semver_valid "$v"; then echo "$v"; else echo "0.0.0"; fi
}

# Blocos opcionais do theme.txt: linhas entre "# >>> NOME" e "# <<< NOME".
# Um bloco desativado tem todas as linhas com o prefixo "#[TAG] ".
block_has() {       # block_has ARQUIVO NOME -> 0 se os marcadores existem
    grep -q "^[[:space:]]*# >>> $2\$" "$1" 2>/dev/null && grep -q "^[[:space:]]*# <<< $2\$" "$1"
}
block_set() {       # block_set ARQUIVO NOME TAG on|off
    local f="$1" b="^[[:space:]]*# >>> $2\$" e="^[[:space:]]*# <<< $2\$" tag="$3"
    if [[ "$4" == on ]]; then
        sed -i "/$b/,/$e/s/^#\[$tag\] //" "$f"
    else
        sed -i "/$b/,/$e/{/$b/b;/$e/b;/^#\[$tag\] /b;s/^/#[$tag] /}" "$f"
    fi
}

# Logo e contorno do menu (WANT_LOGO, WANT_MENU) num theme.txt: o bloco
# menu-box (limites +16 px por lado e menu_pixmap_style) e o no-menu-box
# (limites originais) se alternam. Os marcadores sao conferidos no preflight.
set_layout() {   # set_layout ARQUIVO
    local other=on
    [[ "$WANT_MENU" == on ]] && other=off
    block_set "$1" logo logo "$WANT_LOGO"
    block_set "$1" menu-box menu "$WANT_MENU"
    block_set "$1" no-menu-box menu "$other"
}
manager_version() {
    [[ -x "$BIN_PATH" ]] || { echo ""; return; }
    "$BIN_PATH" --version 2>/dev/null | awk '{print $NF}' || echo "?"
}

pkg_manager_version() { sed -n -E 's/^VERSION[[:space:]]*:?=[[:space:]]*([^[:space:]]+).*/\1/p' "$SRC_MANAGER/Makefile" | head -n1; }

render_unit() { sed "s|@THEME_DIR@|$THEME_RAW|g" "$SRC_UNIT"; }

detect_state() {
    section "Estado atual"
    local v
    v="$(theme_version)";              note "Tema:               ${v:+v$v em $THEME_RAW}${v:-nao instalado}"
    v="$(manager_version)";            note "Manager:            ${v:+v$v}${v:-nao instalado}"
    v="$(script_version "$HELPER_PATH")"; note "Background Helper:  ${v:+v$v}${v:-nao instalado}"
    if [[ -f "$UNIT_PATH" ]]; then
        note "Servico systemd:    instalado ($(service_enabled && echo habilitado || echo desabilitado))"
    else
        note "Servico systemd:    nao instalado"
    fi

    if [[ -d "$BUNDLES_DIR" ]]; then
        local n; n="$(find "$BUNDLES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l)"
        note "Bundles:            $n em $(raw_path "$BUNDLES_DIR")"
    fi
}

# ---------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------
preflight() {
    if [[ -z "$ROOT" ]]; then
        [[ $EUID -eq 0 ]] || die "execute como root: sudo $0"
    fi
    ((ASSUME_YES)) || [[ -t 0 ]] || die "sem terminal interativo; use --yes"

    info "Verificando o pacote"
    [[ -f "$SRC_THEME/theme.txt" ]] || die "nao encontrado: grub-theme/theme.txt"
    [[ -f "$SRC_PREFS" ]] || die "nao encontrado: config/preferences.conf"
    grep -qx 'desktop-image: "background.png"' "$SRC_THEME/theme.txt" \
        || die "theme.txt do pacote deve usar desktop-image: \"background.png\""
    semver_valid "$(tr -d '[:space:]' < "$SRC_THEME/VERSION" 2>/dev/null)" || die "grub-theme/VERSION ausente ou invalido"
    png_ok "$SRC_THEME/fallback.png" || die "grub-theme/fallback.png ausente ou invalido"
    png_ok "$SRC_THEME/background.png" || die "grub-theme/background.png (wallpaper padrao) ausente ou invalido"
    compgen -G "$SRC_THEME/*.pf2" >/dev/null || die "fontes .pf2 ausentes em grub-theme/"
    local b
    for b in logo menu-box no-menu-box; do
        block_has "$SRC_THEME/theme.txt" "$b" || die "theme.txt do pacote sem os marcadores do bloco $b"
    done
    [[ "$(script_version "$SRC_HELPER")" =~ ^(|0\.0\.0)$ ]] && die "helper do pacote ausente ou sem VERSION valida"
    bash -n "$SRC_HELPER" || die "helper do pacote tem erro de sintaxe"
    discover_pkg_bundles
    discover_paths
    info "Diretorio do GRUB: $GRUB_RAW"
}

# ---------------------------------------------------------------------
# Perguntas (todas antes de qualquer alteracao)
# ---------------------------------------------------------------------
WANT_MANAGER=skip; WANT_HELPER=skip; WANT_SERVICE=skip; WANT_ENABLE=0; WANT_LOGO=on; WANT_MENU=on

decide() {   # decide OPT pergunta-instalar default -> echo install|skip
    local opt="$1" q="$2" def="$3"
    if [[ "$opt" == 1 ]]; then echo install; return; fi
    if [[ "$opt" == 0 ]]; then echo skip; return; fi
    if ask_yn "$q" "$def" >&2; then echo install; else echo skip; fi
}

ask_onoff() {   # ask_onoff OPCAO PADRAO(on|off) pergunta -> echo on|off
    if [[ -n "$1" ]]; then echo "$1"; return; fi
    if ask_yn "$3" "$([[ "$2" == off ]] && echo N || echo S)" >&2; then echo on; else echo off; fi
}

# plan_component ROTULO OPCAO VERSAO-INSTALADA VERSAO-PACOTE -> install|keep|skip
plan_component() {
    local label="$1" opt="$2" inst="$3" pkg="$4" c
    if [[ -z "$inst" ]]; then decide "$opt" "Instalar o $label (v$pkg)?" S; return; fi
    c="$(semver_cmp "$inst" "$pkg")"
    if ((c < 0)); then decide "$opt" "Atualizar o $label v$inst -> v$pkg?" S; return; fi
    if ((c > 0)); then note "$label instalado (v$inst) e mais novo que o do pacote (v$pkg); sem downgrade" >&2
    else note "$label ja atualizado (v$inst)" >&2; fi
    echo keep
}

pref_onoff() {   # valor on|off de uma chave das preferencias ("" se outro)
    local v; v="$(conf_get "$PREFS" "$1" || true)"
    [[ "$v" == on || "$v" == off ]] && echo "$v"
    return 0
}

plan() {
    ((FRESH)) && plan_fresh

    # Logo e contorno: o padrao vem das preferencias (exceto num --fresh que
    # descarta os dados: padroes do pacote)
    local logo="" menu=""
    if [[ "$FRESH_MODE" == "" || "$FRESH_MODE" == keep ]]; then
        logo="$(pref_onoff LOGO)"; menu="$(pref_onoff MENU_BOX)"
    fi
    WANT_LOGO="$(ask_onoff "$OPT_LOGO" "${logo:-on}" "Exibir o logo da distribuicao (Arch Linux por padrao) abaixo do menu?")"
    WANT_MENU="$(ask_onoff "$OPT_MENU" "${menu:-on}" "Exibir o contorno de vidro em volta do menu de boot?")"

    plan_bundles

    section "Componentes opcionais (nenhum e obrigatorio; o tema funciona sem eles)"
    local inst_m="" inst_h=""
    ((FRESH)) || { inst_m="$(manager_version)"; inst_h="$(script_version "$HELPER_PATH")"; }
    WANT_MANAGER="$(plan_component "Kawaii Arch Manager" "$OPT_MANAGER" "$inst_m" "$(pkg_manager_version)")"
    WANT_HELPER="$(plan_component "Background Helper" "$OPT_HELPER" "$inst_h" "$(script_version "$SRC_HELPER")")"

    # Servico (depende do helper)
    if ((!FRESH)) && [[ -f "$UNIT_PATH" ]]; then
        if cmp -s <(render_unit) "$UNIT_PATH"; then
            WANT_SERVICE=keep; note "Servico systemd ja atualizado"
        else
            WANT_SERVICE="$(decide "$OPT_SERVICE" "Atualizar a unidade systemd?" S)"
            [[ "$WANT_SERVICE" == skip ]] && WANT_SERVICE=keep
        fi
    else
        WANT_SERVICE="$(decide "$OPT_SERVICE" "Instalar o servico systemd de troca automatica a cada boot?" \
            "$([[ "$WANT_HELPER" == skip ]] && echo N || echo S)")"
    fi
    if [[ "$WANT_SERVICE" != skip && "$WANT_HELPER" == skip ]]; then
        warn "o servico depende do Background Helper, que nao foi selecionado."
        if [[ "$OPT_HELPER" != 0 ]] && ask_yn "Instalar tambem o Background Helper?" S; then
            WANT_HELPER=install
        else
            note "Servico desmarcado (sem o helper ele nao pode funcionar)."
            WANT_SERVICE=skip
        fi
    fi

    # Habilitacao: somente com consentimento explicito
    WANT_ENABLE=0
    if [[ "$WANT_SERVICE" != skip ]]; then
        if ((OPT_ENABLE)); then
            WANT_ENABLE=1
        elif ((!FRESH)) && [[ -f "$UNIT_PATH" ]] && service_enabled; then
            WANT_ENABLE=1; note "O servico ja esta habilitado e continuara habilitado"
        elif ((!ASSUME_YES)); then
            ask_yn "Habilitar o servico agora (novo wallpaper a cada boot)?" N && WANT_ENABLE=1
        else
            note "Servico sera instalado, mas NAO habilitado (use --enable-service)"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------
# Dados persistentes
# ---------------------------------------------------------------------
setup_data_dir() {
    install -d -m 755 "$DATA_DIR" "$BUNDLES_DIR" "$CONF_DIR" "$STATE_DIR"
    local mount_raw content
    mount_raw="$(raw_path "$(stat -c %m -- "$ROOT$GRUB_RAW")")"
    content="$(printf '# Kawaii Arch Manager - caminhos do sistema (gerado pelo install.sh)\n# THEME_DIR: diretorio real do tema; EXPECTED_MOUNT: ponto de montagem\n# esperado para ele (o helper nao escreve se for diferente).\nTHEME_DIR="%s"\nEXPECTED_MOUNT="%s"\n' "$THEME_RAW" "$mount_raw")"
    if [[ -f "$PATHS_CONF" ]] && [[ "$(cat "$PATHS_CONF")" == "$content" ]]; then
        info "Configuracao de caminhos ja em dia ($(raw_path "$PATHS_CONF"))"
    else
        printf '%s\n' "$content" | write_atomic "$PATHS_CONF" 644 || die "falha ao gravar $PATHS_CONF"
        info "Caminhos gravados em $(raw_path "$PATHS_CONF") (tema: $THEME_RAW, montagem: $mount_raw)"
    fi
}

# ---------------------------------------------------------------------
# Bundles do pacote
# ---------------------------------------------------------------------
# bundles/<id>/manifest.conf + bundles/<id>/backgrounds/*.png. As imagens
# sao sempre verificadas; nada no pacote as declara.
bundle_images() {   # bundle_images DIR -> caminhos dos PNGs validos de DIR/backgrounds
    local f
    for f in "$1"/backgrounds/*.png; do
        [[ "${f##*/}" =~ $IMG_RE ]] && png_ok "$f" && echo "$f"
    done
    return 0
}

discover_pkg_bundles() {
    PKG_BUNDLES=()
    [[ -d "$SRC_BUNDLES" ]] || return 0
    local d id mid ver n all
    for d in "$SRC_BUNDLES"/*/; do
        [[ -d "$d" ]] || continue
        d="${d%/}"; id="${d##*/}"
        if [[ ! -f "$d/manifest.conf" || ! -d "$d/backgrounds" ]]; then
            warn "bundles/$id ignorado: esperado manifest.conf e backgrounds/"; continue
        fi
        mid="$(conf_get "$d/manifest.conf" ID || true)"
        ver="$(conf_get "$d/manifest.conf" VERSION || true)"
        if [[ ! "$id" =~ $ID_RE || "$mid" != "$id" ]]; then
            warn "bundles/$id ignorado: ID do manifest.conf (\"$mid\") difere do nome da pasta"; continue
        fi
        semver_valid "$ver" || { warn "bundles/$id ignorado: VERSION invalida (\"$ver\")"; continue; }
        n="$(bundle_images "$d" | wc -l)"
        ((n > 0)) || { warn "bundles/$id ignorado: nenhuma imagem PNG compativel com o GRUB"; continue; }
        all="$(compgen -G "$d/backgrounds/*.png" | wc -l || true)"
        ((all == n)) || warn "bundles/$id: $((all - n)) imagem(ns) ignorada(s) (nome ou formato incompativel com o GRUB)"
        PKG_BUNDLES+=("$id")
        PKG_NAME[$id]="$(conf_get "$d/manifest.conf" NAME || true)"
        PKG_NAME[$id]="${PKG_NAME[$id]:-$id}"
        PKG_VER[$id]="$ver"
        PKG_COUNT[$id]="$n"
    done
    return 0
}

# select_bundles_from "texto" -> preenche WANT_BUNDLES; 1 se invalido
select_bundles_from() {
    local input="${1,,}" tok id found
    local -A seen=()
    WANT_BUNDLES=()
    input="${input//,/ }"
    case "${input// /}" in
        ""|all|todos|t|s|sim) WANT_BUNDLES=("${PKG_BUNDLES[@]}"); return 0 ;;
        none|nenhum|n|nao|não) return 0 ;;
    esac
    for tok in $input; do
        found=""
        if [[ "$tok" =~ ^[0-9]{1,4}$ ]] && ((10#$tok >= 1 && 10#$tok <= ${#PKG_BUNDLES[@]})); then
            found="${PKG_BUNDLES[10#$tok - 1]}"
        else
            for id in "${PKG_BUNDLES[@]}"; do [[ "$id" == "$tok" ]] && found="$id"; done
        fi
        [[ -n "$found" ]] || { warn "bundle desconhecido: $tok"; return 1; }
        [[ -n "${seen[$found]:-}" ]] || { WANT_BUNDLES+=("$found"); seen[$found]=1; }
    done
}

plan_bundles() {
    section "Bundles de wallpapers"
    WANT_BUNDLES=()
    if ((${#PKG_BUNDLES[@]} == 0)); then
        note "O pacote nao traz bundles; o tema usara o wallpaper padrao (grub-theme/background.png)."
        [[ -z "$OPT_BUNDLES" || "$OPT_BUNDLES" == all || "$OPT_BUNDLES" == none ]] \
            || die "--bundles $OPT_BUNDLES: o pacote nao contem bundles"
        return 0
    fi
    local i id inst
    for i in "${!PKG_BUNDLES[@]}"; do
        id="${PKG_BUNDLES[i]}"; inst=""
        [[ "$FRESH_MODE" == "" || "$FRESH_MODE" == keep ]] && [[ -f "$BUNDLES_DIR/$id/manifest.conf" ]] && inst="  [instalado: v$(conf_get "$BUNDLES_DIR/$id/manifest.conf" VERSION)]"
        note "$(printf '%2d) %-16s %-20s v%-8s %3d imagens%s' $((i + 1)) "$id" "${PKG_NAME[$id]}" "${PKG_VER[$id]}" "${PKG_COUNT[$id]}" "$inst")"
    done
    if [[ -n "$OPT_BUNDLES" ]]; then
        select_bundles_from "$OPT_BUNDLES" || die "--bundles: use all, none ou IDs do pacote separados por virgula"
    elif ((ASSUME_YES)); then
        WANT_BUNDLES=("${PKG_BUNDLES[@]}")
    else
        local answer
        while :; do
            read -r -p "${c_q}?${c_off} Bundles a instalar (Enter = todos, n = nenhum, ou numeros/IDs separados por espaco ou virgula): " answer \
                || die "entrada encerrada"
            select_bundles_from "$answer" && break
        done
    fi
    if ((${#WANT_BUNDLES[@]})); then
        note "Selecionados: ${WANT_BUNDLES[*]}"
    else
        note "Nenhum bundle selecionado."
    fi
    return 0
}

install_pkg_bundle() {   # install_pkg_bundle ID -> 0 ok/preservado, 1 falha
    local id="$1" dest="$BUNDLES_DIR/$1" ver="${PKG_VER[$1]}" inst f n=0
    local tmp="$BUNDLES_DIR/.install-$id.$$" old="$BUNDLES_DIR/.old-$id.$$"
    if [[ -d "$dest" ]]; then
        inst="$(conf_get "$dest/manifest.conf" VERSION || true)"
        if (($(semver_cmp "${inst:-0.0.0}" "$ver") >= 0)); then
            info "Bundle '$id' ja instalado (v$inst); preservado"; return 0
        fi
        info "Atualizando o bundle '$id': v${inst:-?} -> v$ver"
    fi
    rm -rf "$tmp"
    mkdir -p "$tmp/backgrounds" && cp "$SRC_BUNDLES/$id/manifest.conf" "$tmp/" || { rm -rf "$tmp"; return 1; }
    while IFS= read -r f; do
        cp --no-preserve=all -- "$f" "$tmp/backgrounds/" || { rm -rf "$tmp"; return 1; }
        n=$((n + 1))
    done < <(bundle_images "$SRC_BUNDLES/$id")
    chmod -R u=rwX,go=rX "$tmp"
    sync -f "$tmp" 2>/dev/null || sync
    if [[ -d "$dest" ]]; then
        mv "$dest" "$old" || { rm -rf "$tmp"; return 1; }
        mv "$tmp" "$dest" || { mv "$old" "$dest"; rm -rf "$tmp"; return 1; }
        rm -rf "$old"
    else
        mv "$tmp" "$dest" || { rm -rf "$tmp"; return 1; }
    fi
    info "Bundle '$id' v$ver instalado: $n imagens, $(du -sh "$dest" | cut -f1)"
}

install_bundles() {
    local id
    for id in "${WANT_BUNDLES[@]}"; do
        install_pkg_bundle "$id" || warn "bundle '$id' nao foi instalado; os demais continuam"
    done
    return 0
}

# Bundles instalados e utilizaveis (manifest com o ID da pasta + backgrounds/)
installed_bundles() {
    local d id
    [[ -d "$BUNDLES_DIR" ]] || return 0
    for d in "$BUNDLES_DIR"/*/; do
        d="${d%/}"; id="${d##*/}"
        [[ "$id" =~ $ID_RE && -d "$d/backgrounds" && ! -L "$d" ]] || continue
        [[ "$(conf_get "$d/manifest.conf" ID || true)" == "$id" ]] && echo "$id"
    done
    return 0
}

# ---------------------------------------------------------------------
# Tema
# ---------------------------------------------------------------------
# Primeiro wallpaper de um tema novo: o que estava ativo (exceto num --fresh
# que descarta os dados), uma imagem aleatoria dos bundles ou o padrao
initial_background() {   # -> caminho da imagem de origem
    local f id
    if [[ "$FRESH_MODE" == "" || "$FRESH_MODE" == keep ]] && png_ok "$THEME_DIR/background.png"; then
        echo "$THEME_DIR/background.png"; return
    fi
    f="$(for id in $(installed_bundles); do bundle_images "$BUNDLES_DIR/$id"; done | shuf -n1)"
    echo "${f:-$SRC_THEME/background.png}"
}

install_theme() {
    local src_ver inst_ver c bg
    local new="$THEMES_DIR/.$THEME_NAME.new.$$" old="$THEMES_DIR/.$THEME_NAME.old.$$"
    src_ver="$(tr -d '[:space:]' < "$SRC_THEME/VERSION")"
    inst_ver="$(theme_version)"
    if [[ -n "$inst_ver" ]] && ((!FRESH)); then
        c="$(semver_cmp "$inst_ver" "$src_ver")"
        if ((c >= 0)); then
            if ((c > 0)); then info "Tema instalado (v$inst_ver) e mais novo que o do pacote (v$src_ver); nenhum downgrade sera feito"
            else info "Tema ja atualizado (v$inst_ver)"; fi
            apply_layout_in_place; ensure_active_background; return 0
        fi
        info "Atualizando o tema: v$inst_ver -> v$src_ver"
    else
        info "Instalando o tema v$src_ver em $THEME_RAW"
    fi

    # O tema novo e montado ao lado e troca de lugar com o anterior
    mkdir -p "$THEMES_DIR"
    rm -rf "$new"
    cp -r "$SRC_THEME" "$new"
    chmod -R u=rwX,go=rX "$new"
    set_layout "$new/theme.txt"
    bg="$(initial_background)"
    cp --no-preserve=all -- "$bg" "$new/background.png" && chmod 644 "$new/background.png" \
        || { rm -rf "$new"; die "falha ao criar background.png"; }
    sync -f "$new" 2>/dev/null || sync
    if [[ -d "$THEME_DIR" ]]; then
        mv "$THEME_DIR" "$old" || { rm -rf "$new"; die "falha ao mover o tema anterior"; }
        mv "$new" "$THEME_DIR" || { mv "$old" "$THEME_DIR"; rm -rf "$new"; die "falha ao instalar o tema; anterior restaurado"; }
        rm -rf "$old"
    else
        mv "$new" "$THEME_DIR" || die "falha ao instalar o tema"
    fi
    sync -f "$THEME_DIR" 2>/dev/null || sync
    [[ "$bg" == "$THEME_DIR/background.png" ]] && bg="o mesmo de antes" || bg="$(raw_path "$bg")"
    info "Tema v$src_ver instalado; wallpaper ativo: $bg"
    note "Espaco ocupado em $(raw_path "$THEME_DIR"): $(du -sh "$THEME_DIR" | cut -f1)"
}

# Logo e contorno do menu num tema ja atualizado (escreve so se mudar)
apply_layout_in_place() {
    local tmp; tmp="$(mktemp "$THEME_DIR/.theme.txt.XXXXXX")"
    cp "$THEME_FILE" "$tmp" && set_layout "$tmp"
    if cmp -s "$tmp" "$THEME_FILE"; then rm -f "$tmp"; return 0; fi
    chmod 644 "$tmp" && mv -f "$tmp" "$THEME_FILE"
    info "theme.txt atualizado: logo $WANT_LOGO, contorno do menu $WANT_MENU"
}

ensure_active_background() {
    png_ok "$THEME_DIR/background.png" && return 0
    local bg; bg="$(initial_background)"
    cp --no-preserve=all -- "$bg" "$THEME_DIR/background.png.tmp" && chmod 644 "$THEME_DIR/background.png.tmp" \
        && mv -f "$THEME_DIR/background.png.tmp" "$THEME_DIR/background.png" || die "falha ao criar background.png"
    info "background.png recriado a partir de $(raw_path "$bg")"
}

# pref_set ARQUIVO CHAVE VALOR: troca so o valor da linha da chave
# (comentarios e ordem do usuario mantidos; chave ausente vai para o fim).
# Grava apenas se mudar.
pref_set() {
    local f="$1" key="$2" val="$3" new
    new="$(awk -v k="$key" -v v="$val" '
        $0 ~ "^[[:space:]]*" k "=" { print k "=\"" v "\""; done = 1; next }
        { print }
        END { if (!done) print k "=\"" v "\"" }' "$f")" || return 1
    [[ "$new" == "$(cat "$f")" ]] && return 0
    printf '%s\n' "$new" | write_atomic "$f" 644
}

# preferences.conf: criado a partir do modelo do pacote (comentado) se
# ausente; senao e preservado. As respostas sobre logo e contorno do menu
# sao gravadas nele (o tema e montado a partir delas).
setup_prefs() {
    if [[ -f "$PREFS" ]]; then
        info "Preferencias preservadas ($(raw_path "$PREFS"): MODE=$(conf_get "$PREFS" MODE))"
    else
        write_atomic "$PREFS" 644 < "$SRC_PREFS" || die "falha ao gravar $PREFS"
        pref_set "$PREFS" SELECTED_BUNDLE "$(installed_bundles | sed -n 1p)" || die "falha ao gravar $PREFS"
        info "Preferencias criadas em $(raw_path "$PREFS") (MODE=$(conf_get "$PREFS" MODE))"
    fi
    pref_set "$PREFS" LOGO "$WANT_LOGO" && pref_set "$PREFS" MENU_BOX "$WANT_MENU" \
        || die "falha ao gravar LOGO/MENU_BOX em $PREFS"
}

# ---------------------------------------------------------------------
# Componentes opcionais (falhas nao abortam a instalacao)
# ---------------------------------------------------------------------
install_payload() {
    install -d -m 755 "$PAYLOAD_DIR/bundles" \
        && install -m 644 "$SRC_HELPER" "$SRC_UNIT" "$SRC_PREFS" "$PAYLOAD_DIR/" \
        && install -m 644 "$SRC_THEME/VERSION" "$PAYLOAD_DIR/theme-version" || return 1
    local k
    for k in "$SRC_BUNDLES"/*.kawall; do
        if [[ -f "$k" ]]; then install -m 644 "$k" "$PAYLOAD_DIR/bundles/" || return 1; fi
    done
}

install_manager() {
    local pkg cc bdir missing=()
    pkg="$(pkg_manager_version)"
    cc="$(command -v cc || command -v gcc || true)"
    [[ -n "$cc" ]] || missing+=("compilador C (gcc)")
    command -v make >/dev/null || missing+=("make")
    [[ -f /usr/include/archive.h ]] || missing+=("libarchive (headers)")
    [[ -f /usr/include/zlib.h ]] || missing+=("zlib (headers)")
    if ((${#missing[@]})); then
        warn "nao e possivel compilar o manager; faltam: ${missing[*]}"
        note "No Arch Linux: pacman -S --needed base-devel libarchive zlib"
        return 1
    fi
    bdir="$(mktemp -d)"
    cp -r "$SRC_MANAGER/Makefile" "$SRC_MANAGER/src" "$bdir/" || { rm -rf "$bdir"; return 1; }
    info "Compilando o kawaii-arch-manager v$pkg"
    if ! make -C "$bdir" CC="$cc" BUILD=out >"$bdir/build.log" 2>&1; then
        warn "a compilacao falhou:"; tail -n 20 "$bdir/build.log" >&2; rm -rf "$bdir"; return 1
    fi
    if [[ "$("$bdir/out/kawaii-arch-manager" --version 2>/dev/null)" != "kawaii-arch-manager $pkg" ]]; then
        warn "o binario compilado nao passou na verificacao (--version)"; rm -rf "$bdir"; return 1
    fi
    install -D -m 755 "$bdir/out/kawaii-arch-manager" "$BIN_PATH.tmp" && mv -f "$BIN_PATH.tmp" "$BIN_PATH" \
        || { rm -f "$BIN_PATH.tmp"; rm -rf "$bdir"; warn "falha ao instalar $(raw_path "$BIN_PATH")"; return 1; }
    rm -rf "$bdir"
    info "Kawaii Arch Manager v$pkg instalado em $(raw_path "$BIN_PATH")"
}

install_helper() {
    local pkg; pkg="$(script_version "$SRC_HELPER")"
    install -d -m 755 "$LIB_DIR" || return 1
    install -m 755 "$SRC_HELPER" "$HELPER_PATH.tmp" && mv -f "$HELPER_PATH.tmp" "$HELPER_PATH" \
        || { rm -f "$HELPER_PATH.tmp"; warn "falha ao instalar o helper"; return 1; }
    [[ "$("$HELPER_PATH" --version 2>/dev/null)" == "$pkg" ]] \
        || { warn "o helper instalado nao responde a --version com $pkg"; return 1; }
    info "Background Helper v$pkg instalado em $(raw_path "$HELPER_PATH")"
}

install_service() {
    [[ -f "$HELPER_PATH" ]] || { warn "servico nao instalado: o Background Helper nao esta presente"; return 1; }
    install -d -m 755 "$(dirname "$UNIT_PATH")" && render_unit | write_atomic "$UNIT_PATH" 644 \
        || { warn "falha ao instalar a unidade"; return 1; }
    NEED_DAEMON_RELOAD=1
    info "Unidade systemd instalada: $(raw_path "$UNIT_PATH") (RequiresMountsFor=$THEME_RAW)"
}

daemon_reload() {
    ((NEED_DAEMON_RELOAD)) || return 0
    [[ -n "$SYSTEMCTL" ]] || return 0
    "$SYSTEMCTL" daemon-reload && info "systemctl daemon-reload executado" || warn "daemon-reload falhou"
    NEED_DAEMON_RELOAD=0
}

install_components() {
    section "Componentes"
    local c want
    for c in manager helper service; do
        want="WANT_${c^^}"
        case "${!want}" in
            install) if "install_$c"; then RESULT[$c]=ok
                     else RESULT[$c]=falhou; warn "$c nao foi instalado; os demais componentes continuam"; fi ;;
            keep)    RESULT[$c]=mantido ;;
            *)       RESULT[$c]=recusado ;;
        esac
        if [[ "$c" == manager && -x "$BIN_PATH" ]]; then
            install_payload || warn "falha ao atualizar o payload do manager em $(raw_path "$PAYLOAD_DIR")"
        fi
    done
    daemon_reload

    if [[ -f "$UNIT_PATH" && -n "$SYSTEMCTL" ]]; then
        if ((WANT_ENABLE)); then
            if service_enabled; then
                info "Servico habilitado"
            elif "$SYSTEMCTL" enable "$SERVICE_NAME" >/dev/null 2>&1; then
                info "Servico habilitado (troca de wallpaper a cada boot)"
            else
                warn "nao foi possivel habilitar $SERVICE_NAME"
            fi
        elif ! service_enabled; then
            note "Servico instalado e desabilitado. Para habilitar: sudo kawaii-arch-manager --enable-service"
        fi
    fi
}

# ---------------------------------------------------------------------
# Tom do tema (claro/escuro) e logo da distribuicao
# ---------------------------------------------------------------------
# Usa o helper do pacote (mesma regra do servico; nao precisa estar
# instalado). A claridade e medida pelo manager; sem ele, o tom e "dark".
# Roda depois dos componentes (o manager pode ter acabado de ser
# instalado) e so escreve no /boot o que mudou.
apply_theme_tone() {
    section "Tom do tema"
    if ! bash "$SRC_HELPER" --retone --quiet; then
        warn "nao foi possivel ajustar o tom do tema ao wallpaper; mantido o atual"
        return 0
    fi
    if [[ "$(head -n1 "$THEME_DIR/icons/.tone" 2>/dev/null || true)" == light ]]; then
        info "Tom: light (wallpaper claro: texto, icones e bordas escuros)"
    else
        info "Tom: dark (wallpaper escuro: texto, icones e bordas claros)"
    fi
    [[ -x "$BIN_PATH" ]] || note "Sem o kawaii-arch-manager a claridade nao e medida; o tom fica sempre dark"
    return 0
}

# ---------------------------------------------------------------------
# /etc/default/grub e grub.cfg (somente quando necessario)
# ---------------------------------------------------------------------
set_grub_var() {
    local key="$1" value="$2"
    if grep -qE "^[#[:space:]]*${key}=" "$DEFAULT_GRUB"; then
        sed -i -E "0,/^[#[:space:]]*${key}=.*/s||${key}=${value}|" "$DEFAULT_GRUB"
        awk -v k="^${key}=" 'BEGIN{seen=0} $0 ~ k {if (seen++) next} {print}' \
            "$DEFAULT_GRUB" > "$DEFAULT_GRUB.tmp" && cat "$DEFAULT_GRUB.tmp" > "$DEFAULT_GRUB"
        rm -f "$DEFAULT_GRUB.tmp"
    else
        echo "${key}=${value}" >> "$DEFAULT_GRUB"
    fi
}

setup_default_grub() {
    section "Configuracao do GRUB"
    [[ -f "$DEFAULT_GRUB" ]] || { warn "$(raw_path "$DEFAULT_GRUB") nao encontrado; etapa ignorada"; return 0; }
    local theme_file_raw="$THEME_RAW/theme.txt"

    if [[ "$(grub_theme_value)" == "$theme_file_raw" ]] \
        && grep -qE '^GRUB_GFXMODE=' "$DEFAULT_GRUB" \
        && ! grep -qE '^GRUB_TERMINAL_OUTPUT=.*console' "$DEFAULT_GRUB"; then
        info "$(raw_path "$DEFAULT_GRUB") ja aponta para o tema; nada a alterar"
        return 0
    fi
    ask_yn "Definir o tema em /etc/default/grub (GRUB_THEME)?" S || {
        warn "GRUB_THEME nao alterado; o tema so aparece se ja estiver configurado"
        return 0
    }
    local backup="$DEFAULT_GRUB.bak-$THEME_NAME" snapshot
    [[ -f "$backup" ]] || { cp -p "$DEFAULT_GRUB" "$backup"; info "Backup salvo em $(raw_path "$backup")"; }
    snapshot="$(mktemp)"
    cp -p "$DEFAULT_GRUB" "$snapshot"
    rollback() { cp -p "$snapshot" "$DEFAULT_GRUB"; rm -f "$snapshot"; die "$1; /etc/default/grub restaurado"; }

    set_grub_var GRUB_THEME "\"$theme_file_raw\""
    grep -qE '^GRUB_GFXMODE=' "$DEFAULT_GRUB" || set_grub_var GRUB_GFXMODE "auto"
    if grep -qE '^GRUB_TERMINAL_OUTPUT=.*console' "$DEFAULT_GRUB"; then
        warn "GRUB_TERMINAL_OUTPUT=console impede o tema de aparecer"
        if ask_yn "Comentar a linha GRUB_TERMINAL_OUTPUT?" S; then
            sed -i -E 's|^(GRUB_TERMINAL_OUTPUT=.*console.*)|#\1|' "$DEFAULT_GRUB"
        fi
    fi
    bash -n "$DEFAULT_GRUB" 2>/dev/null || rollback "/etc/default/grub ficou invalido apos a edicao"
    [[ "$(grub_theme_value)" == "$theme_file_raw" ]] || rollback "GRUB_THEME nao ficou com o valor esperado"
    cmp -s "$snapshot" "$DEFAULT_GRUB" || GRUB_DEFAULT_CHANGED=1
    rm -f "$snapshot"
    info "GRUB_THEME=\"$theme_file_raw\""
}

# Motivo para regenerar o grub.cfg ("" = em dia). Trocar wallpaper nunca e motivo.
grub_cfg_outdated_reason() {
    if ((GRUB_DEFAULT_CHANGED)); then echo "/etc/default/grub foi alterado"; return; fi
    [[ -f "$DEFAULT_GRUB" && "$(grub_theme_value)" == "$THEME_RAW/theme.txt" ]] || return 0
    [[ -f "$GRUB_CFG" ]] || { echo "grub.cfg nao existe"; return; }
    grep -qE "theme=.*themes/$THEME_NAME/theme\.txt" "$GRUB_CFG" || { echo "grub.cfg ainda nao referencia o tema"; return; }
    local loaded present
    loaded="$(grep -oE "themes/$THEME_NAME/[^ \"']+\.pf2" "$GRUB_CFG" | sed 's|.*/||' | sort -u)"
    present="$(find "$THEME_DIR" -maxdepth 1 -name '*.pf2' -printf '%f\n' | sort -u)"
    [[ "$loaded" == "$present" ]] || echo "as fontes do tema mudaram"
}

grub_mkconfig_bin() { command -v grub-mkconfig || command -v grub2-mkconfig || true; }

regen_grub_cfg() {
    local force="${1:-}" reason
    reason="$(grub_cfg_outdated_reason)"
    [[ -n "$force" ]] && reason="$force"
    if [[ -z "$reason" ]]; then
        info "grub.cfg ja esta em dia; regeneracao desnecessaria"
        return 0
    fi
    info "Regenerar o grub.cfg e necessario: $reason"
    if [[ -n "$ROOT" ]]; then note "(sandbox: grub-mkconfig nao executado)"; return 0; fi
    ask_yn "Regenerar $GRUB_CFG agora?" S || { warn "rode 'grub-mkconfig -o $GRUB_CFG' para aplicar"; return 0; }
    local mk; mk="$(grub_mkconfig_bin)"
    [[ -n "$mk" ]] || die "grub-mkconfig nao encontrado"
    local new="$GRUB_CFG.new"
    "$mk" -o "$new" || { rm -f "$new"; die "grub-mkconfig falhou; $GRUB_CFG nao foi alterado"; }
    [[ -s "$new" ]] || { rm -f "$new"; die "grub.cfg gerado esta vazio"; }
    if command -v grub-script-check >/dev/null; then
        grub-script-check "$new" || { rm -f "$new"; die "grub.cfg gerado tem erro de sintaxe; nada foi alterado"; }
    fi
    grep -q '^[[:space:]]*menuentry' "$new" || warn "nenhuma entrada de menu no grub.cfg gerado"
    [[ -f "$GRUB_CFG" ]] && cp -p "$GRUB_CFG" "$GRUB_CFG.bak"
    mv "$new" "$GRUB_CFG"
    info "$GRUB_CFG atualizado (anterior em $GRUB_CFG.bak)"
}

# ---------------------------------------------------------------------
summary() {
    section "Resumo"
    note "Tema:              $(theme_version) em $THEME_RAW (wallpaper ativo: background.png)"
    local ib; ib="$(installed_bundles | tr '\n' ' ')"
    note "Bundles:           ${ib:-nenhum (wallpaper padrao)} em $(raw_path "$BUNDLES_DIR")"
    local mv; mv="$(manager_version)"
    note "Manager:           ${RESULT[manager]:-?}${mv:+ (v$mv)}"
    note "Background Helper: ${RESULT[helper]:-?}"
    note "Servico systemd:   ${RESULT[service]:-?}$( [[ -f "$UNIT_PATH" ]] && { service_enabled && echo ", habilitado" || echo ", desabilitado"; })"
    echo
    if [[ -x "$BIN_PATH" ]]; then
        note "Preferencias: $(raw_path "$PREFS") (edite e rode: sudo kawaii-arch-manager --reload-confs)"
        note "Gerencie com: kawaii-arch-manager --status | --list-bundles | --set-mode | --randomize"
    else
        note "Sem o manager, o tema usa o wallpaper atual. Preferencias: $(raw_path "$PREFS")."
    fi
    info "Pronto!"
}

# ---------------------------------------------------------------------
# Remove os componentes (usada por --uninstall e --fresh). O tema e os
# dados sao tratados por quem chama; /etc/default/grub e grub.cfg nunca.
remove_components() {
    if [[ -n "$SYSTEMCTL" ]]; then "$SYSTEMCTL" disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
    if [[ -f "$UNIT_PATH" ]]; then NEED_DAEMON_RELOAD=1; fi
    rm -f "$UNIT_PATH" "$HELPER_PATH" "$BIN_PATH"
    rmdir "$LIB_DIR" 2>/dev/null || true
    rm -rf "$SHARE_DIR"
    daemon_reload
}

# --fresh: mostra o que sera apagado e pede confirmacao (antes de qualquer
# alteracao, como as demais perguntas)
plan_fresh() {
    section "Instalacao limpa (--fresh)"
    read_fresh_mode
    local any=0
    [[ -d "$THEME_DIR" || -e "$BIN_PATH" || -d "$SHARE_DIR" || -f "$HELPER_PATH" || -f "$UNIT_PATH" || -d "$DATA_DIR" ]] && any=1
    if ((!any)); then
        note "Nada instalado; equivale a uma instalacao normal."
        return 0
    fi
    note "ON_FRESH_INSTALL=\"$FRESH_MODE\" ($FRESH_MODE_SRC)"

    local -a items=() ids=() lost=()
    local i id d
    if [[ -d "$THEME_DIR" ]]; then
        items+=("tema em $THEME_RAW ($([[ "$FRESH_MODE" == keep ]] && echo "o wallpaper ativo sera mantido" || echo "inclui o wallpaper ativo"))")
    fi
    [[ -e "$BIN_PATH" || -d "$SHARE_DIR" ]] && items+=("Kawaii Arch Manager ($(raw_path "$BIN_PATH")) e payload")
    [[ -f "$HELPER_PATH" ]] && items+=("Background Helper ($(raw_path "$HELPER_PATH"))")
    [[ -f "$UNIT_PATH" ]] && items+=("servico systemd ($(service_enabled && echo habilitado || echo desabilitado); volta habilitado so com --enable-service ou se voce escolher)")
    [[ "$FRESH_MODE" != keep && -d "$DATA_DIR" ]] && items+=("dados em $(raw_path "$DATA_DIR"): bundles, preferencias e estado")
    note "Sera APAGADO e depois reinstalado a partir do pacote:"
    for i in "${items[@]}"; do note " - $i"; done

    if [[ -d "$DATA_DIR" ]]; then
        while IFS= read -r id; do ids+=("$id"); done < <(installed_bundles)
        case "$FRESH_MODE" in
            backup)
                note "Backup antes de apagar (em $(raw_path "$DATA_DIR")):"
                [[ -d "$BUNDLES_DIR" ]] && note " - bundles/ -> bundles.old/${ids[*]:+ (${ids[*]})}"
                [[ -d "$CONF_DIR" ]] && note " - config/ -> config.old/ (preferencias)"
                for d in bundles config; do
                    [[ -d "$DATA_DIR/$d" && -e "$DATA_DIR/$d.old" ]] \
                        && warn "o backup anterior $(raw_path "$DATA_DIR/$d.old") sera substituido"
                done
                ;;
            override)
                for id in "${ids[@]}"; do
                    [[ " ${PKG_BUNDLES[*]} " == *" $id "* ]] || lost+=("$id")
                done
                ((${#lost[@]})) && warn "bundles instalados que NAO estao no pacote serao perdidos: ${lost[*]} (use ON_FRESH_INSTALL=\"backup\" ou \"keep\" para nao perde-los)"
                compgen -G "$DATA_DIR/*.old" >/dev/null && note "Backups existentes (*.old) nao sao alterados."
                ;;
            keep)
                note "Mantidos sem alteracao: bundles${ids[*]:+ (${ids[*]})}, preferencias e estado em $(raw_path "$DATA_DIR")."
                ;;
        esac
    fi
    note "Para mudar o que acontece com os dados: ON_FRESH_INSTALL em $(raw_path "$PREFS") (backup | override | keep)."
    note "Preservados: $(raw_path "$DEFAULT_GRUB") e $(raw_path "$GRUB_CFG")."
    if ((ASSUME_YES)); then
        note "Confirmado por --fresh --yes."
    else
        ask_yn "Apagar tudo isso e reinstalar?" N || die "instalacao limpa cancelada; nada foi alterado"
    fi
    return 0
}

# --- Instalacao limpa: ON_FRESH_INSTALL -------------------------------
# O que o --fresh faz com os dados em DATA_DIR (o tema em /boot nunca tem
# .old: e sempre apagado e reinstalado):
#   backup    move bundles/ e config/ para bundles.old/ e config.old/ (uma
#             geracao: substitui os .old anteriores) e apaga o resto
#   override  apaga bundles/, config/ e state/ (os .old existentes ficam)
#   keep      nao altera DATA_DIR; o wallpaper ativo e mantido

# Le ON_FRESH_INSTALL do preferences.conf instalado (ausente: padrao do
# modelo do pacote). Valor invalido aborta antes de qualquer alteracao.
read_fresh_mode() {
    local v src
    src="$(raw_path "$PREFS")"
    v="$(conf_get "$PREFS" ON_FRESH_INSTALL || true)"
    if [[ -z "$v" ]]; then
        v="$(conf_get "$SRC_PREFS" ON_FRESH_INSTALL || true)"
        src="padrao do pacote"
    fi
    case "$v" in
        backup|override|keep) FRESH_MODE="$v"; FRESH_MODE_SRC="$src" ;;
        *) die "ON_FRESH_INSTALL invalido ($src): \"$v\" (backup | override | keep); nada foi alterado" ;;
    esac
}

# backup: move os dados antes de apagar qualquer coisa. Os .old anteriores
# so sao descartados depois que os novos estao no lugar; uma falha desfaz
# os movimentos e aborta sem ter apagado nada.
backup_data() {
    local prev="$DATA_DIR/.old.prev.$$" d i bad
    local -a from=() to=()
    for d in bundles config; do
        [[ -d "$DATA_DIR/$d" && ! -L "$DATA_DIR/$d" ]] || continue
        if [[ -e "$DATA_DIR/$d.old" || -L "$DATA_DIR/$d.old" ]]; then
            from+=("$DATA_DIR/$d.old"); to+=("$prev/$d.old")
        fi
        from+=("$DATA_DIR/$d"); to+=("$DATA_DIR/$d.old")
    done
    mkdir -p -m 700 "$prev" || die "falha ao criar $(raw_path "$prev"); nada foi apagado"
    for i in "${!from[@]}"; do
        mv -T -- "${from[i]}" "${to[i]}" && continue
        bad="${from[i]}"
        while ((i-- > 0)); do mv -T -- "${to[i]}" "${from[i]}" || true; done
        rm -rf "$prev"
        die "falha ao mover $(raw_path "$bad") para o backup; nada foi apagado"
    done
    rm -rf "$prev"
}

# O tema nao e apagado aqui: install_theme o substitui (troca atomica) e,
# no keep, reaproveita o wallpaper ativo
fresh_wipe() {
    section "Remocao (instalacao limpa)"
    if [[ "$FRESH_MODE" == backup && -d "$DATA_DIR" ]]; then backup_data; fi
    remove_components
    if [[ "$FRESH_MODE" != keep && -d "$DATA_DIR" ]]; then
        find "$DATA_DIR" -mindepth 1 -maxdepth 1 ! -name bundles.old ! -name config.old -exec rm -rf -- {} +
    fi
    case "$FRESH_MODE" in
        backup)   info "Componentes removidos; bundles e preferencias movidos para *.old em $(raw_path "$DATA_DIR")" ;;
        override) info "Componentes, bundles, preferencias e estado removidos" ;;
        keep)     info "Componentes removidos; bundles, preferencias e estado mantidos" ;;
    esac
}

do_install() {
    preflight
    detect_state
    plan
    if ((FRESH)); then fresh_wipe; fi
    section "Instalacao"
    setup_data_dir
    install_bundles
    install_theme
    setup_prefs
    install_components
    apply_theme_tone
    setup_default_grub
    regen_grub_cfg
    summary
}

do_uninstall() {
    [[ -n "$ROOT" || $EUID -eq 0 ]] || die "execute como root: sudo $0 --uninstall"
    discover_paths
    section "Remocao"
    note "Serao removidos: servico, helper, manager e o tema em $THEME_RAW."
    if ((OPT_PURGE)); then
        note "--purge: bundles, configuracao e estado em $(raw_path "$DATA_DIR") TAMBEM serao apagados."
    else
        note "Bundles e configuracao em $(raw_path "$DATA_DIR") serao preservados (use --purge para apaga-los)."
    fi
    ask_yn "Continuar?" S || die "cancelado"

    remove_components
    rm -rf "$THEME_DIR"
    info "Componentes e tema removidos"

    if ((OPT_PURGE)); then
        if ask_yn "Apagar DEFINITIVAMENTE $(raw_path "$DATA_DIR")?" S; then
            rm -rf "$DATA_DIR"; info "Dados apagados"
        fi
    fi

    if [[ -f "$DEFAULT_GRUB" ]] && grep -q "^GRUB_THEME=.*$THEME_NAME" "$DEFAULT_GRUB"; then
        if ask_yn "Comentar GRUB_THEME em /etc/default/grub?" S; then
            sed -i -E "s|^(GRUB_THEME=.*$THEME_NAME.*)|#\1|" "$DEFAULT_GRUB"
            regen_grub_cfg "o tema foi removido"
        fi
    fi
    info "Removido"
}

# ---------------------------------------------------------------------
ACTION=install
while (($#)); do
    case "$1" in
        -y|--yes)           ASSUME_YES=1 ;;
        --uninstall)        ACTION=uninstall ;;
        --fresh)            FRESH=1 ;;
        --purge)            OPT_PURGE=1 ;;
        --with-manager)     OPT_MANAGER=1 ;;
        --without-manager)  OPT_MANAGER=0 ;;
        --with-helper)      OPT_HELPER=1 ;;
        --without-helper)   OPT_HELPER=0 ;;
        --with-service)     OPT_SERVICE=1 ;;
        --without-service)  OPT_SERVICE=0 ;;
        --no-components)    OPT_MANAGER=0; OPT_HELPER=0; OPT_SERVICE=0 ;;
        --bundles)          shift; OPT_BUNDLES="${1:-}"; [[ -n "$OPT_BUNDLES" ]] || die "--bundles exige all, none ou uma lista de IDs" ;;
        --no-bundles)       OPT_BUNDLES=none ;;
        --enable-service)   OPT_ENABLE=1 ;;
        --logo)            OPT_LOGO=on ;;
        --no-logo)          OPT_LOGO=off ;;
        --menu-box)        OPT_MENU=on ;;
        --no-menu-box)     OPT_MENU=off ;;
        --grub-dir)         shift; OPT_GRUB_DIR="${1:-}"; [[ -n "$OPT_GRUB_DIR" ]] || die "--grub-dir exige um diretorio" ;;
        -h|--help)          sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                  die "opcao desconhecida: $1 (use --help)" ;;
    esac
    shift
done
((OPT_PURGE)) && [[ "$ACTION" != uninstall ]] && die "--purge so pode ser usado com --uninstall"
((FRESH)) && [[ "$ACTION" == uninstall ]] && die "--fresh e --uninstall sao incompativeis"
((OPT_ENABLE)) && [[ "$OPT_SERVICE" == 0 ]] && die "--enable-service e --without-service sao incompativeis"

case "$ACTION" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
esac
