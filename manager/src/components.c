/* kawaii-arch-manager - componentes: status, versoes, helper, servico,
 * atualizacao e remocao */
#include "kam.h"

#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>


/* --- versoes ------------------------------------------------------- */

/* VERSION="x.y.z" lido como texto, sem executar o script. "" = ausente,
 * "0.0.0" = sem versao valida. */
void helper_version(const char *path, char *out, size_t sz)
{
    out[0] = '\0';
    char *buf = read_file(path, 1 << 20, NULL);
    if (!buf)
        return;
    snprintf(out, sz, "0.0.0");
    for (char *l = buf; l && *l; l = strchr(l, '\n') ? strchr(l, '\n') + 1 : NULL) {
        if (!strncmp(l, "VERSION=", 8)) {
            char v[64] = "";
            if (sscanf(l + 8, "\"%63[^\"\n]\"", v) != 1 && sscanf(l + 8, "%63[^\"\n ]", v) != 1)
                v[0] = '\0';
            if (semver_valid(v))
                snprintf(out, sz, "%s", v);
            break;
        }
    }
    free(buf);
}

/* -1 ausente, 0 sem revisao, N revisao */
int unit_revision(const char *path)
{
    char *buf = read_file(path, 1 << 16, NULL);
    if (!buf)
        return -1;
    int rev = 0;
    char *p = strstr(buf, "KAWAII-UNIT-REVISION=");
    if (p)
        rev = atoi(p + 21);
    free(buf);
    return rev;
}

static void theme_version(const char *dir, char *out, size_t sz)
{
    char p[PATH_MAX];
    out[0] = '\0';
    pathf(p, sizeof p, "%s/theme.txt", dir);
    if (!dir[0] || !is_regular(p))
        return;
    pathf(p, sizeof p, "%s/VERSION", dir);
    char *buf = read_file(p, 256, NULL);
    snprintf(out, sz, "0.0.0");
    if (buf) {
        trim(buf);
        if (semver_valid(buf))
            snprintf(out, sz, "%s", buf);
        free(buf);
    }
}

static void installed_manager_version(char *out, size_t sz)
{
    out[0] = '\0';
    if (!is_executable(P.bin_path))
        return;
    char buf[256];
    char *argv[] = {P.bin_path, "--version", NULL};
    if (run_cmd(argv, buf, sizeof buf, true) == 0) {
        char *sp = strrchr(buf, ' ');
        snprintf(out, sz, "%s", sp ? sp + 1 : buf);
    } else {
        snprintf(out, sz, "?");
    }
}

static const char *cmp_label(const char *inst, const char *pkg)
{
    if (!pkg || !pkg[0])
        return "";
    int c = semver_cmp(inst, pkg);
    return c == 0 ? "atualizado" : c < 0 ? "desatualizado" : "mais novo que o pacote";
}

bool helper_installed(void) { return is_regular(P.helper_path); }
bool service_installed(void) { return is_regular(P.unit_path); }

/* --- systemctl ----------------------------------------------------- */
static bool systemctl_available(void) { return P.systemctl[0] != '\0'; }

static int sysctl(const char *verb, const char *extra, bool quiet, char *out, size_t outsz)
{
    if (!systemctl_available())
        return -1;
    char *argv[6];
    int i = 0;
    argv[i++] = P.systemctl;
    argv[i++] = (char *)verb;
    if (extra)
        argv[i++] = (char *)extra;
    if (strcmp(verb, "daemon-reload"))
        argv[i++] = UNIT_NAME;
    argv[i] = NULL;
    return run_cmd(argv, out, outsz, quiet);
}

static bool service_enabled(void)
{
    char out[64];
    return sysctl("is-enabled", NULL, true, out, sizeof out) == 0 && !strcmp(out, "enabled");
}

/* --- status -------------------------------------------------------- */
int cmd_status(void)
{
    char v[64], pv[64], p[PATH_MAX];

    printf("Kawaii Arch Manager %s\n\nComponentes\n", KAM_VERSION);

    /* Tema */
    char ptv[64] = "";
    pathf(p, sizeof p, "%s/theme-version", P.payload_dir);
    char *tvb = read_file(p, 256, NULL);
    if (tvb) {
        trim(tvb);
        if (semver_valid(tvb))
            snprintf(ptv, sizeof ptv, "%s", tvb);
        free(tvb);
    }
    theme_version(P.theme_dir, v, sizeof v);
    if (v[0])
        printf("  %-22s %-10s %s%s%s%s\n", "Tema", !strcmp(v, "0.0.0") ? "?" : v, P.theme_raw,
               ptv[0] ? "  [" : "", cmp_label(v, ptv), ptv[0] ? "]" : "");
    else
        printf("  %-22s %-10s %s\n", "Tema", "-", P.theme_raw[0] ? "nao encontrado (particao montada?)" : "nao instalado");

    /* Manager */
    installed_manager_version(v, sizeof v);
    if (v[0])
        printf("  %-22s %-10s %s%s\n", "Kawaii Arch Manager", v, P.bin_path + strlen(P.root),
               strcmp(v, KAM_VERSION) ? "  [difere do binario em execucao]" : "");
    else
        printf("  %-22s %-10s nao instalado em %s (em execucao: %s)\n", "Kawaii Arch Manager", "-",
               P.bin_path + strlen(P.root), KAM_VERSION);

    /* Helper */
    pathf(p, sizeof p, "%s/%s", P.payload_dir, HELPER_NAME);
    helper_version(p, pv, sizeof pv);
    helper_version(P.helper_path, v, sizeof v);
    if (v[0])
        printf("  %-22s %-10s %s%s%s%s\n", "Background Helper", v, P.helper_path + strlen(P.root),
               pv[0] ? "  [" : "", cmp_label(v, pv), pv[0] ? "]" : "");
    else
        printf("  %-22s %-10s nao instalado\n", "Background Helper", "-");

    /* Servico */
    int rev = unit_revision(P.unit_path);
    char en[64] = "?", ac[64] = "?";
    if (rev >= 0) {
        if (systemctl_available()) {
            sysctl("is-enabled", NULL, true, en, sizeof en);
            sysctl("is-active", NULL, true, ac, sizeof ac);
        }
        pathf(p, sizeof p, "%s/%s", P.payload_dir, UNIT_TEMPLATE);
        int prev = unit_revision(p);
        char rv[32];
        snprintf(rv, sizeof rv, "rev %d", rev);
        printf("  %-22s %-10s %s, %s%s\n", "Servico systemd", rv, en, ac,
               prev > 0 ? (rev < prev ? "  [desatualizado]" : rev == prev ? "  [atualizado]" : "  [mais novo que o pacote]") : "");
    } else {
        printf("  %-22s %-10s nao instalado\n", "Servico systemd", "-");
    }

    /* Configuracao */
    struct prefs c;
    bool have;
    struct bundle *bv = NULL;
    size_t bn = 0;
    prefs_load(&c, &have);
    bundles_scan(&bv, &bn);
    printf("\nPreferencias (%s%s)\n", P.prefs_conf, have ? "" : ": ausente, valores padrao");
    printf("  %-22s %s\n", "Modo", c.mode);
    struct bundle *sb = c.bundle[0] ? bundle_find(bv, bn, c.bundle) : NULL;
    printf("  %-22s %s%s%s%s\n", "Bundle selecionado", c.bundle[0] ? c.bundle : "-", sb ? " (" : "",
           sb ? sb->name : "", sb ? ")" : (c.bundle[0] ? " [NAO INSTALADO]" : ""));
    printf("  %-22s %s\n", "Imagem fixa", c.background[0] ? c.background : "-");
    printf("  %-22s %s\n", "LOGO", c.logo);
    printf("  %-22s %s\n", "MENU_BOX", c.menu_box);
    printf("  %-22s %s\n", "TONE", c.tone);
    char perr[256];
    if (prefs_check(&c, perr, sizeof perr) < 0)
        printf("  %-22s %s\n", "ERRO", perr);
    char *lb = read_file(P.last_bg, 1024, NULL);
    if (lb)
        trim(lb);
    printf("  %-22s %s\n", "Ultima aplicada", lb && *lb ? lb : "-");
    free(lb);

    if (P.theme_dir[0]) {
        struct png_info pi;
        char e[128], sz[32];
        struct stat st;
        pathf(p, sizeof p, "%s/%s", P.theme_dir, ACTIVE_NAME);
        if (png_check_file(p, &pi, e, sizeof e) == 0 && stat(p, &st) == 0) {
            human_size(st.st_size, sz, sizeof sz);
            printf("  %-22s %s (%ux%u, %s)\n", "Wallpaper ativo", ACTIVE_NAME, pi.w, pi.h, sz);
        } else {
            printf("  %-22s ausente ou invalido (%s)\n", "Wallpaper ativo", e);
        }
        pathf(p, sizeof p, "%s/icons/.tone", P.theme_dir);
        char *tone = read_file(p, 64, NULL);
        if (tone)
            trim(tone);
        printf("  %-22s %s\n", "Tom do tema",
               tone && !strcmp(tone, "light") ? "light (wallpaper claro: texto e icones escuros)"
               : tone && !strcmp(tone, "dark") ? "dark (wallpaper escuro: texto e icones claros)"
                                                : "-");
        free(tone);
        int lg = theme_element_state("logo"), mb = theme_element_state("menu-box");
        printf("  %-22s %s\n", "Logo", lg == 1 ? "ligado" : lg == 0 ? "desligado" : "-");
        printf("  %-22s %s\n", "Contorno do menu", mb == 1 ? "ligado" : mb == 0 ? "desligado" : "-");
        if ((lg >= 0 && lg != !strcmp(c.logo, "on")) || (mb >= 0 && mb != !strcmp(c.menu_box, "on")))
            printf("  %-22s o tema difere de %s: rode sudo %s --reload-confs\n", "Pendente", P.prefs_conf,
                   KAM_PROG);
        pathf(p, sizeof p, "%s/%s", P.theme_dir, FALLBACK_NAME);
        printf("  %-22s %s\n", "Fallback", png_check_file(p, NULL, e, sizeof e) == 0 ? "presente" : "ausente");
        char merr[512];
        printf("  %-22s %s\n", "Particao do tema",
               theme_mount_check(merr, sizeof merr) == KAM_OK ? "montada (ok)" : merr);
    }
    printf("  %-22s %s\n", "Origem do caminho", P.theme_from_conf ? P.paths_conf : "descoberta automatica");

    size_t imgs = 0;
    long long tot = 0;
    for (size_t i = 0; i < bn; i++) {
        imgs += bv[i].nimg;
        tot += bv[i].total;
    }
    char ts[32];
    human_size(tot, ts, sizeof ts);
    printf("\nBundles: %zu instalado(s), %zu imagens, %s (%s)\n", bn, imgs, ts, P.bundles_dir);
    bundles_free(bv, bn);
    return KAM_OK;
}

/* --- helper -------------------------------------------------------- */
static int install_helper_from_payload(bool ask)
{
    char src[PATH_MAX], pv[64], iv[64], tmp[PATH_MAX];
    pathf(src, sizeof src, "%s/%s", P.payload_dir, HELPER_NAME);
    helper_version(src, pv, sizeof pv);
    if (!pv[0]) {
        errmsg("payload do helper indisponivel em %s (reinstale o manager pelo install.sh)", src);
        return KAM_EFAIL;
    }
    helper_version(P.helper_path, iv, sizeof iv);
    if (iv[0]) {
        int c = semver_cmp(iv, pv);
        if (c > 0 && !O.force) {
            msg("Helper instalado (%s) e mais novo que o do pacote (%s); nenhum downgrade sera feito.", iv, pv);
            return KAM_OK;
        }
        if (c == 0 && !O.force) {
            msg("Background Helper ja esta atualizado (%s).", iv);
            return KAM_OK;
        }
        if (ask) {
            char q[160];
            snprintf(q, sizeof q, "Atualizar o Background Helper %s -> %s", iv, pv);
            int r = confirm_rc(q, c < 0);
            if (r)
                return r;
        }
    }
    if (mkdir_p(P.lib_dir, 0755) < 0) {
        errmsg("nao foi possivel criar %s: %s", P.lib_dir, strerror(errno));
        return KAM_EFAIL;
    }
    pathf(tmp, sizeof tmp, "%s.tmp", P.helper_path);
    if (copy_file_atomic(src, P.helper_path, tmp, 0755) < 0) {
        errmsg("falha ao instalar %s: %s", P.helper_path, strerror(errno));
        return KAM_EFAIL;
    }
    char out[64];
    char *argv[] = {P.helper_path, "--version", NULL};
    if (run_cmd(argv, out, sizeof out, true) != 0 || strcmp(out, pv)) {
        errmsg("o helper instalado nao respondeu --version com %s", pv);
        return KAM_EFAIL;
    }
    msg("Background Helper %s instalado em %s", pv, P.helper_path + strlen(P.root));
    return KAM_OK;
}

int cmd_install_helper(void)
{
    int rc = require_root("--install-helper");
    return rc ? rc : install_helper_from_payload(false);
}

/* --- servico ------------------------------------------------------- */
static char *render_unit(char *err, size_t errsz)
{
    char p[PATH_MAX];
    pathf(p, sizeof p, "%s/%s", P.payload_dir, UNIT_TEMPLATE);
    size_t len;
    char *t = read_file(p, 1 << 16, &len);
    if (!t) {
        snprintf(err, errsz, "modelo da unidade indisponivel em %s (reinstale o manager pelo install.sh)", p);
        return NULL;
    }
    size_t tl = strlen(P.theme_raw), cnt = 0;
    for (char *q = t; (q = strstr(q, "@THEME_DIR@")); q += 11)
        cnt++;
    char *out = malloc(len + cnt * tl + 1), *o = out;
    if (!out) {
        free(t);
        snprintf(err, errsz, "sem memoria");
        return NULL;
    }
    for (char *q = t;;) {
        char *m = strstr(q, "@THEME_DIR@");
        size_t n = m ? (size_t)(m - q) : strlen(q);
        memcpy(o, q, n);
        o += n;
        if (!m)
            break;
        memcpy(o, P.theme_raw, tl);
        o += tl;
        q = m + 11;
    }
    *o = '\0';
    free(t);
    return out;
}

static int install_service_impl(bool ask_update)
{
    char err[512];
    if (!helper_installed()) {
        errmsg("o servico depende do Background Helper, que nao esta instalado.");
        note("Instale-o antes: sudo %s --install-helper", KAM_PROG);
        return KAM_ECONFLICT;
    }
    if (!P.theme_raw[0]) {
        errmsg("diretorio do tema desconhecido; defina THEME_DIR em %s", P.paths_conf);
        return KAM_EFAIL;
    }
    char *unit = render_unit(err, sizeof err);
    if (!unit) {
        errmsg("%s", err);
        return KAM_EFAIL;
    }
    int rc = KAM_OK;
    size_t cur_len = 0;
    char *cur = read_file(P.unit_path, 1 << 16, &cur_len);
    bool changed = !cur || cur_len != strlen(unit) || memcmp(cur, unit, cur_len);
    if (cur && changed) {
        char tp[PATH_MAX];
        pathf(tp, sizeof tp, "%s/%s", P.payload_dir, UNIT_TEMPLATE);
        int ir = unit_revision(P.unit_path), pr = unit_revision(tp);
        if (ir > pr && !O.force) {
            msg("Unidade instalada (rev %d) e mais nova que a do pacote (rev %d); nenhum downgrade sera feito.", ir, pr);
            changed = false;
        } else if (ask_update) {
            char q[160];
            snprintf(q, sizeof q, "Atualizar a unidade systemd (rev %d -> rev %d)", ir, pr);
            if ((rc = confirm_rc(q, true)))
                changed = false;
        }
    }
    free(cur);
    if (changed) {
        char dir[PATH_MAX];
        snprintf(dir, sizeof dir, "%s", P.unit_path);
        *strrchr(dir, '/') = '\0';
        if (mkdir_p(dir, 0755) < 0 || write_file_atomic(P.unit_path, unit, strlen(unit), 0644) < 0) {
            errmsg("falha ao gravar %s: %s", P.unit_path, strerror(errno));
            free(unit);
            return KAM_EFAIL;
        }
        msg("Unidade systemd instalada: %s", P.unit_path + strlen(P.root));
        if (sysctl("daemon-reload", NULL, false, NULL, 0) != 0)
            warnmsg("systemctl daemon-reload falhou ou indisponivel");
    } else if (rc == KAM_OK) {
        msg("Unidade systemd ja esta identica a do pacote; nada a fazer.");
    }
    free(unit);
    if (changed && !service_enabled()) {
        note("O servico NAO foi habilitado. Para habilitar: sudo %s --enable-service", KAM_PROG);
    }
    return rc;
}

int cmd_install_service(void)
{
    int rc = require_root("--install-service");
    return rc ? rc : install_service_impl(false);
}

static int need_service(const char *what)
{
    int rc = require_root(what);
    if (rc)
        return rc;
    if (!service_installed()) {
        errmsg("o servico nao esta instalado (use --install-service)");
        return KAM_ECONFLICT;
    }
    if (!systemctl_available()) {
        errmsg("systemctl indisponivel");
        return KAM_EFAIL;
    }
    return KAM_OK;
}

int cmd_enable_service(void)
{
    int rc = need_service("--enable-service");
    if (rc)
        return rc;
    if (sysctl("enable", NULL, false, NULL, 0) != 0) {
        errmsg("falha ao habilitar %s", UNIT_NAME);
        return KAM_EFAIL;
    }
    msg("Servico habilitado; iniciando uma execucao agora");
    if (sysctl("start", NULL, false, NULL, 0) != 0) {
        errmsg("o servico falhou; veja: journalctl -u %s", UNIT_NAME);
        return KAM_EFAIL;
    }
    return KAM_OK;
}

int cmd_disable_service(void)
{
    int rc = need_service("--disable-service");
    if (rc)
        return rc;
    if (sysctl("disable", "--now", false, NULL, 0) != 0) {
        errmsg("falha ao desabilitar %s", UNIT_NAME);
        return KAM_EFAIL;
    }
    msg("Servico desabilitado (o wallpaper atual e mantido).");
    return KAM_OK;
}

int cmd_start_service(void)
{
    int rc = need_service("--start-service");
    if (rc)
        return rc;
    if (sysctl("start", NULL, false, NULL, 0) != 0) {
        errmsg("o servico falhou; veja: journalctl -u %s", UNIT_NAME);
        return KAM_EFAIL;
    }
    msg("Servico executado.");
    return KAM_OK;
}

int cmd_stop_service(void)
{
    int rc = need_service("--stop-service");
    if (rc)
        return rc;
    if (sysctl("stop", NULL, false, NULL, 0) != 0) {
        errmsg("falha ao parar %s", UNIT_NAME);
        return KAM_EFAIL;
    }
    msg("Servico parado.");
    return KAM_OK;
}

/* --- remocao ------------------------------------------------------- */
int cmd_uninstall(const char *comp)
{
    int rc;
    if (strcmp(comp, "service") && strcmp(comp, "helper") && strcmp(comp, "manager") &&
        strcmp(comp, "data") && strcmp(comp, "theme")) {
        errmsg("componente desconhecido: \"%s\" (service, helper, manager ou data)", comp);
        return KAM_EUSAGE;
    }
    if (!strcmp(comp, "theme")) {
        errmsg("a remocao do tema altera a configuracao do GRUB; use: sudo ./install.sh --uninstall");
        return KAM_EUSAGE;
    }
    if ((rc = require_root("--uninstall")))
        return rc;

    if (!strcmp(comp, "service")) {
        if (!service_installed()) {
            msg("Servico nao esta instalado; nada a fazer.");
            return KAM_OK;
        }
        if ((rc = confirm_rc("Desabilitar e remover o servico systemd", true)))
            return rc;
        sysctl("disable", "--now", true, NULL, 0);
        unlink(P.unit_path);
        sysctl("daemon-reload", NULL, true, NULL, 0);
        msg("Servico removido. Helper, bundles e configuracao foram preservados.");
        return KAM_OK;
    }
    if (!strcmp(comp, "helper")) {
        if (service_installed()) {
            errmsg("o servico depende do helper; remova-o antes: sudo %s --uninstall service", KAM_PROG);
            return KAM_ECONFLICT;
        }
        if (!helper_installed()) {
            msg("Helper nao esta instalado; nada a fazer.");
            return KAM_OK;
        }
        if ((rc = confirm_rc("Remover o Background Helper", true)))
            return rc;
        unlink(P.helper_path);
        rmdir(P.lib_dir);
        msg("Helper removido. Bundles e configuracao foram preservados.");
        return KAM_OK;
    }
    if (!strcmp(comp, "manager")) {
        if ((rc = confirm_rc("Remover o kawaii-arch-manager e seu payload", true)))
            return rc;
        rm_rf(P.share_dir);
        if (unlink(P.bin_path) < 0 && errno != ENOENT) {
            errmsg("falha ao remover %s: %s", P.bin_path, strerror(errno));
            return KAM_EFAIL;
        }
        msg("Manager removido. Helper, servico, bundles e configuracao foram preservados.");
        return KAM_OK;
    }
    /* data */
    if (helper_installed())
        warnmsg("o helper continuara instalado, mas sem bundles/configuracao (usara o wallpaper atual)");
    msg("Isto apaga PERMANENTEMENTE %s (bundles, configuracao e estado).", P.data_dir);
    if ((rc = confirm_rc("Apagar todos os dados", false)))
        return rc;
    if (rm_rf(P.data_dir) < 0) {
        errmsg("falha ao apagar %s: %s", P.data_dir, strerror(errno));
        return KAM_EFAIL;
    }
    msg("Dados removidos.");
    return KAM_OK;
}

/* --- atualizacao --------------------------------------------------- */
static int kawall_filter(const struct dirent *de)
{
    size_t n = strlen(de->d_name);
    return de->d_name[0] != '.' && n > 7 && !strcmp(de->d_name + n - 7, ".kawall");
}

int cmd_update(void)
{
    int rc, worst = KAM_OK;
    if (!O.dry_run && (rc = require_root("--update")))
        return rc;
    if (!is_dir(P.payload_dir)) {
        errmsg("payload indisponivel em %s (reinstale o manager pelo install.sh)", P.payload_dir);
        return KAM_EFAIL;
    }
    char p[PATH_MAX], iv[64], pv[64];

    msg("Kawaii Arch Manager %s (atualizado pelo install.sh do pacote)", KAM_VERSION);

    /* Tema: somente relatorio (copia para /boot e feita pelo instalador) */
    pathf(p, sizeof p, "%s/theme-version", P.payload_dir);
    char *tv = read_file(p, 256, NULL);
    theme_version(P.theme_dir, iv, sizeof iv);
    if (tv) {
        trim(tv);
        if (iv[0] && semver_cmp(iv, tv) < 0)
            msg("Tema: %s -> %s disponivel; execute o install.sh do pacote para atualizar", iv, tv);
        else if (iv[0])
            msg("Tema: %s (%s)", iv, cmp_label(iv, tv));
        free(tv);
    }

    /* Helper */
    pathf(p, sizeof p, "%s/%s", P.payload_dir, HELPER_NAME);
    helper_version(p, pv, sizeof pv);
    helper_version(P.helper_path, iv, sizeof iv);
    if (!iv[0]) {
        msg("Background Helper: nao instalado (instale com --install-helper)");
    } else if (O.dry_run) {
        msg("Background Helper: %s, pacote %s (%s)", iv, pv, cmp_label(iv, pv));
    } else {
        rc = install_helper_from_payload(true);
        if (rc && rc != KAM_ECANCEL)
            worst = rc;
    }

    /* Servico */
    if (!service_installed()) {
        msg("Servico systemd: nao instalado (instale com --install-service)");
    } else if (O.dry_run) {
        pathf(p, sizeof p, "%s/%s", P.payload_dir, UNIT_TEMPLATE);
        msg("Servico systemd: rev %d, pacote rev %d", unit_revision(P.unit_path), unit_revision(p));
    } else {
        rc = install_service_impl(true);
        if (rc && rc != KAM_ECANCEL)
            worst = rc;
    }

    /* Bundles: atualiza somente os ja instalados */
    pathf(p, sizeof p, "%s/bundles", P.payload_dir);
    struct dirent **list;
    int n = scandir(p, &list, kawall_filter, alphasort);
    for (int i = 0; i < n; i++) {
        char kp[PATH_MAX], err[512], inst[PATH_MAX];
        struct kawall_info ki;
        pathf(kp, sizeof kp, "%s/%s", p, list[i]->d_name);
        if (kawall_inspect(kp, &ki, err, sizeof err) == 0) {
            pathf(inst, sizeof inst, "%s/%s", P.bundles_dir, ki.meta.id);
            struct bundle cur;
            if (is_dir(inst) && bundle_load(inst, ki.meta.id, &cur) == 0) {
                if (semver_cmp(ki.meta.version, cur.version) > 0) {
                    if (O.dry_run) {
                        msg("Bundle %s: %s -> %s disponivel", ki.meta.id, cur.version, ki.meta.version);
                    } else {
                        rc = cmd_import_bundle(kp);
                        if (rc && rc != KAM_ECANCEL)
                            worst = rc;
                    }
                } else {
                    msg("Bundle %s: %s (%s)", ki.meta.id, cur.version, cmp_label(cur.version, ki.meta.version));
                }
                bundle_free(&cur);
            }
        } else {
            warnmsg("%s: %s", list[i]->d_name, err);
        }
        free(list[i]);
    }
    if (n > 0)
        free(list);
    return worst;
}
