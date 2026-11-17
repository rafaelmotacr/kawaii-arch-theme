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
#    sudo ./install.sh --fresh               instalacao limpa: apaga tema,
#                                            componentes, bundles, configuracao
#                                            e estado, e reinstala a partir do
#                                            pacote (pede confirmacao; pergunta
#                                            se a configuracao de wallpapers
#                                            deve ser mantida)
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
#    --keep-config | --no-keep-config
#                           so com --fresh: mantem (ou descarta) o modo de
#                           troca de wallpapers / wallpaper fixo, o estado da
#                           rotacao e o wallpaper ativo (padrao: pergunta;
#                           com --yes, mantem)
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

# KAWAII_ROOT: prefixo para testes em sandbox (nao toca o sistema real)
ROOT="${KAWAII_ROOT:-}"
DATA_DIR="$ROOT/var/lib/kawaii-arch-manager"
BUNDLES_DIR="$DATA_DIR/bundles"
CONF_DIR="$DATA_DIR/config"
STATE_DIR="$DATA_DIR/state"
BG_CONF="$CONF_DIR/backgrounds.conf"
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

LOGO_FILE="logos/arch-dark.png"   # logo padrao (o seletor de tom troca o arquivo)
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
OPT_KEEP_CONFIG=""  # --fresh: "" pergunta | 1 mantem | 0 descarta a config de wallpapers

# Estado
GRUB_DEFAULT_CHANGED=0
NEED_DAEMON_RELOAD=0
OLD_LOGO_STATE=""     # estado do logo no tema instalado: on | off | ""
OLD_MENU_STATE=""     # estado do contorno do menu no tema instalado
declare -A RESULT=()
PKG_BUNDLES=()        # IDs validos encontrados em bundles/ do pacote
declare -A PKG_NAME=() PKG_VER=() PKG_COUNT=()
WANT_BUNDLES=()
KEEP_CONFIG=0         # --fresh: manter backgrounds.conf, estado e wallpaper ativo
KEEP_REFS=()          # bundles referenciados pela configuracao mantida
KEEP_BUNDLES=()       # desses, os que nao estao no pacote (preservados no wipe)
KEEP_DIR=""           # guarda temporaria durante o --fresh

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

# Versao declarada num script, lida do texto (sem executa-lo).
# "0.0.0" = sem versao valida.
script_version() {
    local file="$1" v
    [[ -f "$file" ]] || { echo ""; return; }
    v="$(sed -n -E 's/^VERSION="?([^"[:space:]]*)"?.*/\1/p' "$file" | head -n1)"
    if [[ -n "$v" ]] && semver_valid "$v"; then echo "$v"; else echo "0.0.0"; fi
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
        for t in /boot/grub /boot/grub2; do
            if [[ -f "$ROOT$t/grub.cfg" ]]; then cand="$t"; break; fi
        done
        if [[ -z "$cand" ]]; then
            for t in /boot/grub /boot/grub2; do
                [[ -d "$ROOT$t" ]] && { cand="$t"; break; }
            done
        fi
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
    [[ -f "$THEME_FILE" ]] || { echo ""; return; }
    local v=""
    [[ -f "$THEME_DIR/VERSION" ]] && v="$(head -n1 "$THEME_DIR/VERSION" | tr -d '[:space:]')"
    semver_valid "$v" && echo "$v" || echo "0.0.0"
}

# Blocos opcionais do theme.txt: linhas entre "# >>> NOME" e "# <<< NOME".
# Um bloco desativado tem todas as linhas com o prefixo "#[TAG] ".
block_has() {       # block_has ARQUIVO NOME -> 0 se os marcadores existem
    grep -q "^[[:space:]]*# >>> $2\$" "$1" 2>/dev/null && grep -q "^[[:space:]]*# <<< $2\$" "$1"
}
block_active() {    # block_active ARQUIVO NOME -> 0 se ha linha nao comentada
    sed -n "/^[[:space:]]*# >>> $2\$/,/^[[:space:]]*# <<< $2\$/p" "$1" | grep -qv '^[[:space:]]*\(#\|$\)'
}
block_set() {       # block_set ARQUIVO NOME TAG on|off
    local f="$1" b="^[[:space:]]*# >>> $2\$" e="^[[:space:]]*# <<< $2\$" tag="$3"
    if [[ "$4" == on ]]; then
        sed -i "/$b/,/$e/s/^#\[$tag\] //" "$f"
    else
        sed -i "/$b/,/$e/{/$b/b;/$e/b;/^#\[$tag\] /b;s/^/#[$tag] /}" "$f"
    fi
}

logo_state() {      # on | off | "" para um theme.txt
    block_has "$1" logo || { echo ""; return; }
    if block_active "$1" logo; then echo on; else echo off; fi
}

menu_state() {      # contorno do menu: on | off | ""
    block_has "$1" menu-box && block_has "$1" no-menu-box || { echo ""; return; }
    if block_active "$1" menu-box; then echo on; else echo off; fi
}

manager_version() {
    [[ -x "$BIN_PATH" ]] || { echo ""; return; }
    "$BIN_PATH" --version 2>/dev/null | awk '{print $NF}' || echo "?"
}

pkg_manager_version() { sed -n -E 's/^VERSION[[:space:]]*:?=[[:space:]]*([^[:space:]]+).*/\1/p' "$SRC_MANAGER/Makefile" | head -n1; }

render_unit() { sed "s|@THEME_DIR@|$THEME_RAW|g" "$SRC_UNIT"; }

detect_state() {
    section "Estado atual"
    local tv; tv="$(theme_version)"
    if [[ -n "$tv" ]]; then
        note "Tema:               v$tv em $THEME_RAW"
        OLD_LOGO_STATE="$(logo_state "$THEME_FILE")"
        OLD_MENU_STATE="$(menu_state "$THEME_FILE")"
    else
        note "Tema:               nao instalado"
    fi

    local mv; mv="$(manager_version)"
    note "Manager:            ${mv:+v$mv}${mv:-nao instalado}"
    local hv; hv="$(script_version "$HELPER_PATH")"
    note "Background Helper:  ${hv:+v$hv}${hv:-nao instalado}"
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
    grep -qx 'desktop-image: "background.png"' "$SRC_THEME/theme.txt" \
        || die "theme.txt do pacote deve usar desktop-image: \"background.png\""
    semver_valid "$(tr -d '[:space:]' < "$SRC_THEME/VERSION" 2>/dev/null)" || die "grub-theme/VERSION ausente ou invalido"
    png_ok "$SRC_THEME/fallback.png" || die "grub-theme/fallback.png ausente ou invalido"
    png_ok "$SRC_THEME/background.png" || die "grub-theme/background.png (wallpaper padrao) ausente ou invalido"
    discover_pkg_bundles
    if [[ -f "$SRC_HELPER" ]]; then
        semver_valid "$(script_version "$SRC_HELPER")" && [[ "$(script_version "$SRC_HELPER")" != 0.0.0 ]] \
            || die "helper do pacote sem VERSION valida"
        bash -n "$SRC_HELPER" || die "helper do pacote tem erro de sintaxe"
    fi
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

plan() {
    if ((FRESH)); then
        plan_fresh
        OLD_LOGO_STATE=""   # instalacao limpa: padroes do pacote
        OLD_MENU_STATE=""
    fi

    # Logo
    local cur="${OLD_LOGO_STATE:-on}" def=S
    [[ "$cur" == off ]] && def=N
    if [[ -n "$OPT_LOGO" ]]; then WANT_LOGO="$OPT_LOGO"
    elif ask_yn "Exibir o logo da distribuicao (Arch Linux por padrao) abaixo do menu?" "$def"; then WANT_LOGO=on
    else WANT_LOGO=off
    fi

    # Contorno do menu de boot
    def=S; [[ "$OLD_MENU_STATE" == off ]] && def=N
    if [[ -n "$OPT_MENU" ]]; then WANT_MENU="$OPT_MENU"
    elif ask_yn "Exibir o contorno de vidro em volta do menu de boot?" "$def"; then WANT_MENU=on
    else WANT_MENU=off
    fi

    plan_bundles

    section "Componentes opcionais (nenhum e obrigatorio; o tema funciona sem eles)"
    local pkg inst c

    # Manager
    pkg="$(pkg_manager_version)"; inst=""
    ((FRESH)) || inst="$(manager_version)"
    if [[ -z "$inst" ]]; then
        WANT_MANAGER="$(decide "$OPT_MANAGER" "Instalar o Kawaii Arch Manager (binario compilado, v$pkg)?" S)"
    else
        c="$(semver_cmp "$inst" "$pkg")"
        if ((c < 0)); then
            WANT_MANAGER="$(decide "$OPT_MANAGER" "Atualizar o Kawaii Arch Manager v$inst -> v$pkg?" S)"
        else
            WANT_MANAGER=keep
            ((c > 0)) && note "Manager instalado (v$inst) e mais novo que o do pacote (v$pkg); sem downgrade" \
                      || note "Manager ja atualizado (v$inst)"
        fi
    fi

    # Helper
    pkg="$(script_version "$SRC_HELPER")"; inst=""
    ((FRESH)) || inst="$(script_version "$HELPER_PATH")"
    if [[ -z "$inst" ]]; then
        WANT_HELPER="$(decide "$OPT_HELPER" "Instalar o Background Helper (script de selecao, v$pkg)?" S)"
    else
        c="$(semver_cmp "$inst" "$pkg")"
        if ((c < 0)); then
            WANT_HELPER="$(decide "$OPT_HELPER" "Atualizar o Background Helper v$inst -> v$pkg?" S)"
        else
            WANT_HELPER=keep
            ((c > 0)) && note "Helper instalado (v$inst) e mais novo que o do pacote (v$pkg); sem downgrade" \
                      || note "Background Helper ja atualizado (v$inst)"
        fi
    fi
    local helper_present=0
    [[ "$WANT_HELPER" != skip ]] && helper_present=1

    # Servico (depende do helper)
    if ((!FRESH)) && [[ -f "$UNIT_PATH" ]]; then
        if cmp -s <(render_unit) "$UNIT_PATH"; then
            WANT_SERVICE=keep; note "Servico systemd ja atualizado"
        else
            WANT_SERVICE="$(decide "$OPT_SERVICE" "Atualizar a unidade systemd?" S)"
            [[ "$WANT_SERVICE" == skip ]] && WANT_SERVICE=keep
        fi
    else
        local def_s=S
        ((helper_present)) || def_s=N
        WANT_SERVICE="$(decide "$OPT_SERVICE" "Instalar o servico systemd de troca automatica a cada boot?" "$def_s")"
    fi
    if [[ "$WANT_SERVICE" != skip ]] && ((!helper_present)); then
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
# bundles/<id>/manifest.conf + bundles/<id>/backgrounds/*.png. A quantidade
# de imagens e sempre contada; nada no pacote a declara.
count_images() {   # count_images DIR -> numero de PNGs validos
    local f n=0 name
    shopt -s nullglob
    for f in "$1"/*.png; do
        name="${f##*/}"
        [[ "$name" =~ $IMG_RE && ! -L "$f" ]] && png_ok "$f" && n=$((n + 1))
    done
    shopt -u nullglob
    echo "$n"
}

discover_pkg_bundles() {
    PKG_BUNDLES=()
    [[ -d "$SRC_BUNDLES" ]] || return 0
    local d id mid ver n
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
        n="$(count_images "$d/backgrounds")"
        ((n > 0)) || { warn "bundles/$id ignorado: nenhuma imagem PNG compativel com o GRUB"; continue; }
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
        ((!FRESH)) && [[ -f "$BUNDLES_DIR/$id/manifest.conf" ]] && inst="  [instalado: v$(conf_get "$BUNDLES_DIR/$id/manifest.conf" VERSION)]"
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
    # Configuracao mantida no --fresh: o bundle do modo 'set' ou do wallpaper
    # fixo precisa existir depois da reinstalacao
    local ref
    for ref in "${KEEP_REFS[@]}"; do
        [[ " ${PKG_BUNDLES[*]} " == *" $ref "* && " ${WANT_BUNDLES[*]} " != *" $ref "* ]] || continue
        WANT_BUNDLES+=("$ref")
        note "Bundle '$ref' incluido: e usado pela configuracao de wallpapers mantida"
    done
    if ((${#WANT_BUNDLES[@]})); then
        note "Selecionados: ${WANT_BUNDLES[*]}"
    else
        note "Nenhum bundle selecionado."
    fi
    return 0
}

install_pkg_bundle() {   # install_pkg_bundle ID -> 0 ok/preservado, 1 falha
    local id="$1" src="$SRC_BUNDLES/$1" dest="$BUNDLES_DIR/$1" pkg_ver inst_ver c
    pkg_ver="${PKG_VER[$id]}"

    if [[ -d "$dest" ]]; then
        inst_ver="$(conf_get "$dest/manifest.conf" VERSION || true)"
        c="$(semver_cmp "${inst_ver:-0.0.0}" "$pkg_ver")"
        if ((c >= 0)); then
            info "Bundle '$id' ja instalado (v${inst_ver}); preservado"
            return 0
        fi
        ask_yn "Atualizar o bundle '$id' v${inst_ver:-?} -> v$pkg_ver?" S || return 0
    fi

    local tmp="$BUNDLES_DIR/.install-$id.$$" n=0 f name
    rm -rf "$tmp"
    mkdir -p "$tmp/backgrounds"
    cp "$src/manifest.conf" "$tmp/" || { rm -rf "$tmp"; warn "falha ao copiar o manifest.conf de '$id'"; return 1; }
    shopt -s nullglob
    for f in "$src/backgrounds"/*.png; do
        name="${f##*/}"
        if [[ ! "$name" =~ $IMG_RE || -L "$f" ]] || ! png_ok "$f"; then
            warn "$id: ignorada (nome ou formato incompativel com o GRUB): $name"; continue
        fi
        if ! cp --no-preserve=all -- "$f" "$tmp/backgrounds/$name" \
            || [[ "$(stat -c %s -- "$f")" != "$(stat -c %s -- "$tmp/backgrounds/$name")" ]]; then
            shopt -u nullglob; rm -rf "$tmp"; warn "$id: falha ao copiar $name"; return 1
        fi
        n=$((n + 1))
    done
    shopt -u nullglob
    ((n > 0)) || { rm -rf "$tmp"; warn "$id: nenhuma imagem valida"; return 1; }
    chmod -R u=rwX,go=rX "$tmp"
    sync -f "$tmp" 2>/dev/null || sync

    if [[ -d "$dest" ]]; then
        local old="$BUNDLES_DIR/.old-$id.$$"
        if ! { mv "$dest" "$old" && mv "$tmp" "$dest"; }; then
            [[ -d "$old" && ! -d "$dest" ]] && mv "$old" "$dest"
            rm -rf "$tmp"; warn "falha ao atualizar o bundle '$id'"; return 1
        fi
        rm -rf "$old"
    else
        mv "$tmp" "$dest" || { rm -rf "$tmp"; warn "falha ao instalar o bundle '$id'"; return 1; }
    fi
    info "Bundle '$id' v$pkg_ver instalado: $n imagens, $(du -sh "$dest" | cut -f1)"
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
set_logo() {   # set_logo ARQUIVO on|off
    local f="$1" state="$2"
    block_has "$f" logo || { warn "marcadores do logo ausentes no theme.txt"; return 0; }
    block_set "$f" logo logo "$state"
    [[ "$(logo_state "$f")" == "$state" ]] || die "falha ao $( [[ "$state" == on ]] && echo ativar || echo desativar) o logo"
}

# Contorno do menu: o bloco menu-box (limites +16 px por lado e
# menu_pixmap_style) e o no-menu-box (limites originais) se alternam.
set_menu() {   # set_menu ARQUIVO on|off
    local f="$1" state="$2" other=off
    [[ "$state" == off ]] && other=on
    [[ -n "$(menu_state "$f")" ]] || { warn "marcadores do contorno do menu ausentes no theme.txt"; return 0; }
    block_set "$f" menu-box menu "$state"
    block_set "$f" no-menu-box menu "$other"
    if [[ "$state" == on ]]; then
        block_active "$f" menu-box && ! block_active "$f" no-menu-box || die "falha ao ativar o contorno do menu"
    else
        ! block_active "$f" menu-box && block_active "$f" no-menu-box || die "falha ao desativar o contorno do menu"
    fi
}

# Primeiro wallpaper ativo para um tema novo/atualizado: o atual, uma imagem
# aleatoria dos bundles instalados ou o padrao do pacote
initial_background() {   # -> caminho da imagem de origem
    local old="$1" f
    # --fresh mantendo a configuracao: o wallpaper fixo escolhido ou,
    # nos demais modos, o wallpaper que estava ativo
    if ((KEEP_CONFIG)); then
        f="$(fixed_background_path)"
        if [[ -n "$f" ]] && png_ok "$f"; then echo "$f"; return; fi
        if [[ -n "$KEEP_DIR" ]] && png_ok "$KEEP_DIR/background.png"; then echo "$KEEP_DIR/background.png"; return; fi
    fi
    if png_ok "$old/background.png"; then echo "$old/background.png"; return; fi
    local -a dirs=()
    local id
    while IFS= read -r id; do dirs+=("$BUNDLES_DIR/$id/backgrounds"); done < <(installed_bundles)
    if ((${#dirs[@]})); then
        while IFS= read -r f; do
            png_ok "$f" && { echo "$f"; return; }
        done < <(find "${dirs[@]}" -maxdepth 1 -type f -name '*.png' | shuf)
    fi
    # Sem bundles: wallpaper padrao do pacote
    if png_ok "$SRC_THEME/background.png"; then echo "$SRC_THEME/background.png"; return; fi
    echo "$SRC_THEME/fallback.png"
}

install_theme() {
    local src_ver inst_ver c
    src_ver="$(tr -d '[:space:]' < "$SRC_THEME/VERSION")"
    inst_ver="$(theme_version)"

    if [[ -n "$inst_ver" ]]; then
        c="$(semver_cmp "$inst_ver" "$src_ver")"
        if ((c > 0)); then
            info "Tema instalado (v$inst_ver) e mais novo que o do pacote (v$src_ver); nenhum downgrade sera feito"
            apply_layout_in_place; ensure_active_background; return 0
        elif ((c == 0)); then
            info "Tema ja atualizado (v$inst_ver)"
            apply_layout_in_place; ensure_active_background; return 0
        fi
        info "Atualizando o tema: v$inst_ver -> v$src_ver"
    else
        info "Instalando o tema v$src_ver em $THEME_RAW"
    fi

    mkdir -p "$THEMES_DIR"
    local new="$THEMES_DIR/.$THEME_NAME.new.$$" old="$THEMES_DIR/.$THEME_NAME.old.$$" bg
    rm -rf "$new"
    cp -r "$SRC_THEME" "$new"
    rm -f "$new/background.png"
    chmod -R u=rwX,go=rX "$new"
    set_logo "$new/theme.txt" "$WANT_LOGO"
    set_menu "$new/theme.txt" "$WANT_MENU"
    [[ "$WANT_LOGO" == off ]] || [[ -f "$new/$LOGO_FILE" ]] || die "logo ativado, mas $LOGO_FILE nao esta no tema"

    bg="$(initial_background "$THEME_DIR")"
    cp --no-preserve=all -- "$bg" "$new/background.png" || { rm -rf "$new"; die "falha ao criar background.png"; }
    chmod 644 "$new/background.png"

    # Validacao antes de substituir
    png_ok "$new/background.png" || { rm -rf "$new"; die "background.png invalido"; }
    png_ok "$new/fallback.png" || { rm -rf "$new"; die "fallback.png invalido"; }
    grep -qx 'desktop-image: "background.png"' "$new/theme.txt" || { rm -rf "$new"; die "theme.txt invalido"; }
    compgen -G "$new/*.pf2" >/dev/null || { rm -rf "$new"; die "fontes .pf2 ausentes no tema"; }

    sync -f "$new" 2>/dev/null || sync
    if [[ -d "$THEME_DIR" ]]; then
        mv "$THEME_DIR" "$old" || { rm -rf "$new"; die "falha ao mover o tema anterior"; }
        if ! mv "$new" "$THEME_DIR"; then
            mv "$old" "$THEME_DIR"; rm -rf "$new"; die "falha ao instalar o tema; anterior restaurado"
        fi
        rm -rf "$old"
    else
        mv "$new" "$THEME_DIR" || die "falha ao instalar o tema"
    fi
    sync -f "$THEME_DIR" 2>/dev/null || sync
    if [[ -n "$KEEP_DIR" && "$bg" == "$KEEP_DIR/"* ]]; then
        info "Tema v$src_ver instalado; wallpaper ativo: o mesmo de antes da reinstalacao"
    else
        info "Tema v$src_ver instalado; wallpaper ativo: $(raw_path "$bg")"
    fi
    note "Espaco ocupado em $(raw_path "$THEME_DIR"): $(du -sh "$THEME_DIR" | cut -f1)"
}

# Logo e contorno do menu num tema ja atualizado (escreve so se mudar)
apply_layout_in_place() {
    local logo menu
    logo="$(logo_state "$THEME_FILE")"; menu="$(menu_state "$THEME_FILE")"
    [[ ( -z "$logo" || "$logo" == "$WANT_LOGO" ) && ( -z "$menu" || "$menu" == "$WANT_MENU" ) ]] && return 0
    local tmp; tmp="$(mktemp "$THEME_DIR/.theme.txt.XXXXXX")"
    cp "$THEME_FILE" "$tmp"
    [[ -n "$logo" && "$logo" != "$WANT_LOGO" ]] && set_logo "$tmp" "$WANT_LOGO"
    [[ -n "$menu" && "$menu" != "$WANT_MENU" ]] && set_menu "$tmp" "$WANT_MENU"
    chmod 644 "$tmp"; mv -f "$tmp" "$THEME_FILE"
    [[ -n "$logo" && "$logo" != "$WANT_LOGO" ]] && info "Logo $( [[ "$WANT_LOGO" == on ]] && echo ativado || echo desativado)"
    [[ -n "$menu" && "$menu" != "$WANT_MENU" ]] && info "Contorno do menu $( [[ "$WANT_MENU" == on ]] && echo ativado || echo desativado)"
    return 0
}

ensure_active_background() {
    png_ok "$THEME_DIR/background.png" && return 0
    local bg; bg="$(initial_background "$THEME_DIR")"
    cp --no-preserve=all -- "$bg" "$THEME_DIR/background.png.tmp" && chmod 644 "$THEME_DIR/background.png.tmp" \
        && mv -f "$THEME_DIR/background.png.tmp" "$THEME_DIR/background.png" || die "falha ao criar background.png"
    info "background.png recriado a partir de $(raw_path "$bg")"
}

# backgrounds.conf: criado somente se ausente (configuracao do usuario e
# sempre preservada). Padrao: modo 'global' (todos os bundles).
setup_bg_config() {
    if [[ -f "$BG_CONF" ]]; then
        info "Configuracao de wallpapers preservada ($(raw_path "$BG_CONF"): MODE=$(conf_get "$BG_CONF" MODE))"
        return 0
    fi
    local first
    first="$(installed_bundles | sed -n 1p)"
    printf '# Kawaii Arch Manager - preferencias de wallpaper\n# MODE: fixed | set | global | balanced\n# SELECTED_BUNDLE: ID (usado no modo set)\n# SELECTED_BACKGROUND: ID/arquivo.png (usado no modo fixed)\nMODE="global"\nSELECTED_BUNDLE="%s"\nSELECTED_BACKGROUND=""\n' \
        "$first" | write_atomic "$BG_CONF" 644 || die "falha ao gravar $BG_CONF"
    info "Configuracao criada: MODE=global"
}

# ---------------------------------------------------------------------
# Componentes opcionais (falhas nao abortam a instalacao)
# ---------------------------------------------------------------------
install_payload() {
    install -d -m 755 "$PAYLOAD_DIR" "$PAYLOAD_DIR/bundles" || return 1
    install -m 644 "$SRC_HELPER" "$PAYLOAD_DIR/grub-random-bg.sh" || return 1
    install -m 644 "$SRC_UNIT" "$PAYLOAD_DIR/grub-random-bg.service.in" || return 1
    install -m 644 "$SRC_THEME/VERSION" "$PAYLOAD_DIR/theme-version" || return 1
    local k
    for k in "$SRC_DIR"/bundles/*.kawall; do
        [[ -f "$k" ]] && { install -m 644 "$k" "$PAYLOAD_DIR/bundles/" || return 1; }
    done
    return 0
}

install_manager() {
    local pkg; pkg="$(pkg_manager_version)"
    local cc_bin=""
    command -v cc >/dev/null && cc_bin=cc
    [[ -z "$cc_bin" ]] && command -v gcc >/dev/null && cc_bin=gcc
    local missing=()
    [[ -n "$cc_bin" ]] || missing+=("compilador C (gcc)")
    command -v make >/dev/null || missing+=("make")
    [[ -f /usr/include/archive.h ]] || missing+=("libarchive (headers)")
    [[ -f /usr/include/zlib.h ]] || missing+=("zlib (headers)")
    if ((${#missing[@]})); then
        warn "nao e possivel compilar o manager; faltam: ${missing[*]}"
        note "No Arch Linux: pacman -S --needed base-devel libarchive zlib"
        return 1
    fi
    local bdir log
    bdir="$(mktemp -d)"; log="$bdir/build.log"
    cp -r "$SRC_MANAGER/Makefile" "$SRC_MANAGER/src" "$bdir/" || { rm -rf "$bdir"; return 1; }
    info "Compilando o kawaii-arch-manager v$pkg"
    if ! make -C "$bdir" CC="$cc_bin" BUILD=out >"$log" 2>&1; then
        warn "a compilacao falhou:"; tail -n 20 "$log" >&2; rm -rf "$bdir"; return 1
    fi
    local built="$bdir/out/kawaii-arch-manager"
    if [[ "$(head -c4 "$built" | od -An -c | tr -d ' ')" != '177ELF' ]] \
        || [[ "$("$built" --version 2>/dev/null)" != "kawaii-arch-manager $pkg" ]]; then
        warn "o binario compilado nao passou na verificacao (--version)"; rm -rf "$bdir"; return 1
    fi
    install -d -m 755 "$(dirname "$BIN_PATH")" \
        && install -m 755 "$built" "$BIN_PATH.tmp" \
        && mv -f "$BIN_PATH.tmp" "$BIN_PATH" || { rm -f "$BIN_PATH.tmp"; rm -rf "$bdir"; warn "falha ao instalar $BIN_PATH"; return 1; }
    rm -rf "$bdir"
    [[ -x "$BIN_PATH" && "$("$BIN_PATH" --version 2>/dev/null)" == "kawaii-arch-manager $pkg" ]] \
        || { warn "o manager instalado nao responde a --version"; return 1; }
    info "Kawaii Arch Manager v$pkg instalado em $(raw_path "$BIN_PATH")"
    return 0
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
    local tmpd tmp; tmpd="$(mktemp -d)"; tmp="$tmpd/$SERVICE_NAME"
    render_unit > "$tmp" || { rm -rf "$tmpd"; return 1; }
    if [[ -f "$UNIT_PATH" ]] && cmp -s "$tmp" "$UNIT_PATH"; then
        info "Unidade systemd ja identica a do pacote; nada a fazer"
        rm -rf "$tmpd"; return 0
    fi
    if [[ -z "$ROOT" ]] && command -v systemd-analyze >/dev/null; then
        local out; out="$(systemd-analyze verify "$tmp" 2>&1 | grep -v -e 'ExecStart=.*not executable' -e 'Unit .* not found' || true)"
        [[ -n "$out" ]] && { warn "systemd-analyze verify:"; echo "$out" >&2; }
    fi
    install -d -m 755 "$(dirname "$UNIT_PATH")" && install -m 644 "$tmp" "$UNIT_PATH" \
        || { rm -rf "$tmpd"; warn "falha ao instalar a unidade"; return 1; }
    rm -rf "$tmpd"
    NEED_DAEMON_RELOAD=1
    info "Unidade systemd instalada: $(raw_path "$UNIT_PATH") (RequiresMountsFor=$THEME_RAW)"
}

daemon_reload() {
    ((NEED_DAEMON_RELOAD)) || return 0
    [[ -n "$SYSTEMCTL" ]] || return 0
    "$SYSTEMCTL" daemon-reload && info "systemctl daemon-reload executado" || warn "daemon-reload falhou"
    NEED_DAEMON_RELOAD=0
}

run_component() {   # run_component NOME FUNCAO
    local name="$1" fn="$2"
    if "$fn"; then RESULT[$name]="ok"; else RESULT[$name]="falhou"; warn "$name nao foi instalado; os demais componentes continuam"; fi
}

install_components() {
    section "Componentes"

    case "$WANT_MANAGER" in
        install) run_component manager install_manager ;;
        keep)    RESULT[manager]="mantido" ;;
        *)       RESULT[manager]="recusado" ;;
    esac
    if [[ -x "$BIN_PATH" ]]; then
        install_payload || warn "falha ao atualizar o payload do manager em $(raw_path "$PAYLOAD_DIR")"
    fi

    case "$WANT_HELPER" in
        install) run_component helper install_helper ;;
        keep)    RESULT[helper]="mantido" ;;
        *)       RESULT[helper]="recusado" ;;
    esac

    case "$WANT_SERVICE" in
        install) run_component service install_service ;;
        keep)    RESULT[service]="mantido" ;;
        *)       RESULT[service]="recusado" ;;
    esac
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
    [[ -d "$THEME_DIR/tones" ]] || return 0
    section "Tom do tema"
    if ! bash "$SRC_HELPER" --retone --quiet; then
        warn "nao foi possivel ajustar o tom do tema ao wallpaper; mantido o atual"
        return 0
    fi
    local tone="" logo
    [[ -r "$THEME_DIR/icons/.tone" ]] && tone="$(head -n1 "$THEME_DIR/icons/.tone")"
    logo="$(sed -n -E 's/^[^#]*file[[:space:]]*=[[:space:]]*"logos\/([^"]+)".*/\1/p' "$THEME_FILE" | head -n1)"
    case "$tone" in
        light) info "Tom: light (wallpaper claro: texto, icones e bordas escuros)" ;;
        *)     info "Tom: dark (wallpaper escuro: texto, icones e bordas claros)" ;;
    esac
    [[ -x "$BIN_PATH" ]] || note "Sem o kawaii-arch-manager a claridade nao e medida; o tom fica sempre dark"
    [[ "$WANT_LOGO" == on && -n "$logo" ]] && note "Logo: logos/$logo"
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
    info "$GRUB_CFG atualizado${GRUB_CFG:+ (anterior em $GRUB_CFG.bak)}"
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
        note "Gerencie com: kawaii-arch-manager --status | --list-bundles | --set-mode | --randomize"
    else
        note "Sem o manager, o tema usa o wallpaper atual; configure editando $(raw_path "$BG_CONF")."
    fi
    info "Pronto!"
}

# ---------------------------------------------------------------------
# Remocao do que esta instalado (usada por --uninstall e --fresh).
# /etc/default/grub e grub.cfg nao sao tocados aqui.
remove_installation() {
    local had_unit=0
    [[ -f "$UNIT_PATH" ]] && had_unit=1
    if [[ -n "$SYSTEMCTL" ]]; then "$SYSTEMCTL" disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
    rm -f "$UNIT_PATH" "$HELPER_PATH" "$BIN_PATH"
    rmdir "$LIB_DIR" 2>/dev/null || true
    rm -rf "$SHARE_DIR"
    ((had_unit)) && { NEED_DAEMON_RELOAD=1; daemon_reload; }
    rm -rf "$THEME_DIR"
}

# --fresh: mostra o que sera apagado e pede confirmacao (antes de qualquer
# alteracao, como as demais perguntas)
plan_fresh() {
    section "Instalacao limpa (--fresh)"
    local any=0
    [[ -d "$THEME_DIR" || -e "$BIN_PATH" || -d "$SHARE_DIR" || -f "$HELPER_PATH" || -f "$UNIT_PATH" || -d "$DATA_DIR" ]] && any=1
    if ((!any)); then
        note "Nada instalado; equivale a uma instalacao normal."
        [[ "$OPT_KEEP_CONFIG" == 1 ]] && note "--keep-config: nao ha configuracao de wallpapers a manter."
        return 0
    fi

    plan_keep_config

    local -a items=() lost=()
    if ((KEEP_CONFIG)); then
        [[ -d "$THEME_DIR" ]] && items+=("tema em $THEME_RAW (o wallpaper ativo sera mantido)")
    else
        [[ -d "$THEME_DIR" ]] && items+=("tema em $THEME_RAW (inclui o wallpaper ativo)")
    fi
    [[ -e "$BIN_PATH" || -d "$SHARE_DIR" ]] && items+=("Kawaii Arch Manager ($(raw_path "$BIN_PATH")) e payload")
    [[ -f "$HELPER_PATH" ]] && items+=("Background Helper ($(raw_path "$HELPER_PATH"))")
    [[ -f "$UNIT_PATH" ]] && items+=("servico systemd ($(service_enabled && echo habilitado || echo desabilitado); volta habilitado so com --enable-service ou se voce escolher)")
    if [[ -d "$DATA_DIR" ]]; then
        if ((KEEP_CONFIG)); then
            items+=("dados em $(raw_path "$DATA_DIR"): bundles (exceto os usados pela configuracao mantida)")
        else
            items+=("dados em $(raw_path "$DATA_DIR"): bundles, configuracao e estado")
        fi
    fi
    note "Sera APAGADO e depois reinstalado a partir do pacote:"
    local i id
    for i in "${items[@]}"; do note " - $i"; done
    if ((KEEP_CONFIG)); then
        note "Mantido: configuracao de wallpapers ($(describe_bg_config)), estado da rotacao${KEEP_BUNDLES[*]:+ e o(s) bundle(s) importado(s) ${KEEP_BUNDLES[*]}}."
    fi
    while IFS= read -r id; do
        [[ " ${PKG_BUNDLES[*]} " == *" $id "* || " ${KEEP_BUNDLES[*]} " == *" $id "* ]] || lost+=("$id")
    done < <(installed_bundles)
    ((${#lost[@]})) && warn "bundles instalados que NAO estao no pacote serao perdidos: ${lost[*]}"
    note "Preservados: $(raw_path "$DEFAULT_GRUB") e $(raw_path "$GRUB_CFG")."
    if ((ASSUME_YES)); then
        note "Confirmado por --fresh --yes."
    else
        ask_yn "Apagar tudo isso e reinstalar?" N || die "instalacao limpa cancelada; nada foi alterado"
    fi
    return 0
}

# --- Configuracao de wallpapers mantida no --fresh --------------------
# Mantidos: backgrounds.conf (MODE, SELECTED_BUNDLE, SELECTED_BACKGROUND),
# state/last-background (evita repetir o ultimo wallpaper), o wallpaper
# ativo e, se a configuracao apontar para um bundle importado (fora do
# pacote), esse bundle. paths.conf e sempre regenerado.

describe_bg_config() {
    local mode sel
    mode="$(conf_get "$BG_CONF" MODE || true)"
    case "$mode" in
        fixed) sel="$(conf_get "$BG_CONF" SELECTED_BACKGROUND || true)"; echo "modo fixed, wallpaper fixo: ${sel:-nenhum}" ;;
        set)   sel="$(conf_get "$BG_CONF" SELECTED_BUNDLE || true)"; echo "modo set, bundle: ${sel:-nenhum}" ;;
        global|balanced) echo "modo $mode" ;;
        *)     echo "MODE=\"$mode\"" ;;
    esac
}

# IDs de bundles de que a configuracao depende (modo set / fixed)
config_bundle_refs() {
    local mode sel=""
    mode="$(conf_get "$BG_CONF" MODE || true)"
    case "$mode" in
        fixed) sel="$(conf_get "$BG_CONF" SELECTED_BACKGROUND || true)"
               [[ "$sel" == */* ]] && sel="${sel%%/*}" || sel="" ;;
        set)   sel="$(conf_get "$BG_CONF" SELECTED_BUNDLE || true)" ;;
    esac
    [[ -n "$sel" && "$sel" =~ $ID_RE ]] && echo "$sel"
    return 0
}

# Caminho do wallpaper fixo configurado ("" se o modo nao e fixed)
fixed_background_path() {
    [[ "$(conf_get "$BG_CONF" MODE || true)" == fixed ]] || return 0
    local sel id name
    sel="$(conf_get "$BG_CONF" SELECTED_BACKGROUND || true)"
    [[ "$sel" == */* ]] || return 0
    id="${sel%%/*}"; name="${sel#*/}"
    [[ "$id" =~ $ID_RE && "$name" =~ $IMG_RE ]] || return 0
    echo "$BUNDLES_DIR/$id/backgrounds/$name"
}

plan_keep_config() {
    KEEP_CONFIG=0; KEEP_REFS=(); KEEP_BUNDLES=()
    if [[ ! -f "$BG_CONF" ]]; then
        [[ "$OPT_KEEP_CONFIG" == 1 ]] && note "--keep-config: nao ha configuracao de wallpapers a manter."
        return 0
    fi
    note "Configuracao de wallpapers atual: $(describe_bg_config)"
    if [[ -n "$OPT_KEEP_CONFIG" ]]; then
        KEEP_CONFIG="$OPT_KEEP_CONFIG"
    elif ask_yn "Manter a configuracao de wallpapers (modo de troca / wallpaper fixo) apos a reinstalacao?" S; then
        KEEP_CONFIG=1
    fi
    ((KEEP_CONFIG)) || { note "A configuracao sera recriada com os padroes (MODE=global)."; return 0; }

    local ref
    while IFS= read -r ref; do
        KEEP_REFS+=("$ref")
        if [[ " ${PKG_BUNDLES[*]} " == *" $ref "* ]]; then
            :   # reinstalado a partir do pacote (plan_bundles garante a selecao)
        elif [[ -d "$BUNDLES_DIR/$ref" && ! -L "$BUNDLES_DIR/$ref" ]]; then
            KEEP_BUNDLES+=("$ref")
        else
            warn "a configuracao usa o bundle '$ref', que nao esta instalado nem no pacote; o helper usara o fallback ate voce escolher outro"
        fi
    done < <(config_bundle_refs)
    # O wallpaper fixo existira depois da reinstalacao? (bundle do pacote:
    # confere no pacote; bundle importado: confere o instalado)
    local f src id
    f="$(fixed_background_path)"
    if [[ -n "$f" ]]; then
        id="${f#"$BUNDLES_DIR/"}"; id="${id%%/*}"; src="$f"
        [[ " ${PKG_BUNDLES[*]} " == *" $id "* ]] && src="$SRC_BUNDLES/$id/backgrounds/${f##*/}"
        png_ok "$src" || warn "o wallpaper fixo configurado ($(conf_get "$BG_CONF" SELECTED_BACKGROUND)) nao existe ou e invalido; o helper usara o fallback ate voce escolher outro"
    fi
    return 0
}

# Avisa onde estao os dados guardados se o instalador terminar no meio
keep_exit_report() {
    [[ -n "$KEEP_DIR" && -d "$KEEP_DIR" ]] || return 0
    warn "a configuracao de wallpapers mantida ficou guardada em $(raw_path "$KEEP_DIR")"
    note "Restaure manualmente: backgrounds.conf -> $(raw_path "$BG_CONF"), last-background -> $(raw_path "$STATE_DIR")/,"
    note "bundles/<id> -> $(raw_path "$BUNDLES_DIR")/ e background.png -> $THEME_RAW/"
}

# Guarda o que sera mantido fora de DATA_DIR (mesmo filesystem: mv e atomico)
stash_config() {
    ((KEEP_CONFIG)) || return 0
    KEEP_DIR="$(dirname "$DATA_DIR")/.kawaii-arch-manager.keep.$$"
    rm -rf "$KEEP_DIR"
    mkdir -m 700 -p "$KEEP_DIR/bundles" || die "falha ao criar $(raw_path "$KEEP_DIR"); nada foi apagado"
    trap keep_exit_report EXIT
    cp -p -- "$BG_CONF" "$KEEP_DIR/backgrounds.conf" || { rm -rf "$KEEP_DIR"; KEEP_DIR=""; die "falha ao guardar $(raw_path "$BG_CONF"); nada foi apagado"; }
    [[ -f "$STATE_DIR/last-background" ]] && { cp -p -- "$STATE_DIR/last-background" "$KEEP_DIR/" || true; }
    png_ok "$THEME_DIR/background.png" && { cp --no-preserve=all -- "$THEME_DIR/background.png" "$KEEP_DIR/background.png" || true; }
    local id moved=()
    for id in "${KEEP_BUNDLES[@]}"; do
        if ! mv -- "$BUNDLES_DIR/$id" "$KEEP_DIR/bundles/$id"; then
            for id in "${moved[@]}"; do mv -- "$KEEP_DIR/bundles/$id" "$BUNDLES_DIR/$id"; done
            rm -rf "$KEEP_DIR"; KEEP_DIR=""
            die "falha ao guardar o bundle '$id'; nada foi apagado"
        fi
        moved+=("$id")
    done
    sync -f "$KEEP_DIR" 2>/dev/null || sync
}

# Devolve configuracao, estado e bundles guardados (apos setup_data_dir)
restore_config() {
    [[ -n "$KEEP_DIR" ]] || return 0
    local id
    for id in "${KEEP_BUNDLES[@]}"; do
        mv -- "$KEEP_DIR/bundles/$id" "$BUNDLES_DIR/$id" || die "falha ao restaurar o bundle '$id'"
        info "Bundle '$id' mantido"
    done
    write_atomic "$BG_CONF" 644 < "$KEEP_DIR/backgrounds.conf" || die "falha ao restaurar $(raw_path "$BG_CONF")"
    if [[ -f "$KEEP_DIR/last-background" ]]; then
        write_atomic "$STATE_DIR/last-background" 644 < "$KEEP_DIR/last-background" || warn "estado da rotacao nao restaurado"
    fi
    info "Configuracao de wallpapers mantida: $(describe_bg_config)"
}

# Descarta a guarda temporaria (depois que o tema ja usou o wallpaper guardado)
finish_keep() {
    [[ -n "$KEEP_DIR" ]] || return 0
    rm -rf "$KEEP_DIR"; KEEP_DIR=""
    trap - EXIT
}

fresh_wipe() {
    [[ -d "$THEME_DIR" || -e "$BIN_PATH" || -d "$SHARE_DIR" || -f "$HELPER_PATH" || -f "$UNIT_PATH" || -d "$DATA_DIR" ]] || return 0
    section "Remocao (instalacao limpa)"
    stash_config
    remove_installation
    rm -rf "$DATA_DIR"
    if ((KEEP_CONFIG)); then
        info "Instalacao anterior removida (tema, componentes e bundles); configuracao de wallpapers guardada"
    else
        info "Instalacao anterior removida (tema, componentes, bundles, configuracao e estado)"
    fi
}

do_install() {
    preflight
    detect_state
    plan
    if ((FRESH)); then fresh_wipe; fi
    section "Instalacao"
    setup_data_dir
    restore_config
    install_bundles
    install_theme
    finish_keep
    setup_bg_config
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

    remove_installation
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
        --keep-config)      OPT_KEEP_CONFIG=1 ;;
        --no-keep-config)   OPT_KEEP_CONFIG=0 ;;
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
[[ -n "$OPT_KEEP_CONFIG" ]] && ((!FRESH)) \
    && die "--keep-config/--no-keep-config so se aplicam a --fresh (as demais instalacoes ja preservam a configuracao)"
((OPT_ENABLE)) && [[ "$OPT_SERVICE" == 0 ]] && die "--enable-service e --without-service sao incompativeis"

case "$ACTION" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
esac
