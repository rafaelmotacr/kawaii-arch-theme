/* kawaii-arch-manager - --reload-confs: aplica config/preferences.conf
 *
 * O arquivo de preferencias e a fonte da verdade; o theme.txt e o
 * wallpaper ativo sao derivados dele. O reload valida o arquivo inteiro
 * antes de mudar qualquer coisa e aplica so o que difere do estado atual:
 *   LOGO, MENU_BOX     blocos do theme.txt (layout_apply)
 *   MODE, SELECTED_*   aplica um wallpaper so se o ativo nao corresponde
 *                      mais a configuracao (fixed: outra imagem; set: outro
 *                      bundle). global/balanced nao sorteiam (--randomize)
 *   TONE               o tom e reaplicado no fim (helper --retone) */
#include "kam.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void read_tone(char *out, size_t sz)
{
    char p[PATH_MAX];
    out[0] = '\0';
    if (!P.theme_dir[0])
        return;
    pathf(p, sizeof p, "%s/icons/.tone", P.theme_dir);
    char *t = read_file(p, 64, NULL);
    if (t) {
        trim(t);
        snprintf(out, sz, "%s", t);
        free(t);
    }
}

int cmd_reload_confs(void)
{
    int rc;
    if (!O.dry_run && (rc = require_root("--reload-confs")))
        return rc;
    struct prefs c;
    bool have;
    if ((rc = prefs_load(&c, &have)))
        return rc;
    if (!have) {
        errmsg("%s nao existe; rode o install.sh ou copie config/preferences.conf do pacote", P.prefs_conf);
        return KAM_EBUNDLE;
    }
    prefs_warn_unknown();
    char err[512];
    if (prefs_check(&c, err, sizeof err) < 0) {
        errmsg("%s: %s; nada foi aplicado", P.prefs_conf, err);
        return KAM_EBUNDLE;
    }
    /* fixed/set dependem de bundle/imagem instalados; global/balanced sem
     * bundles sao validos (o tema usa o wallpaper atual ou o fallback) */
    if (!strcmp(c.mode, "fixed") || !strcmp(c.mode, "set")) {
        struct bundle *v = NULL;
        size_t n = 0;
        if (bundles_scan(&v, &n) < 0) {
            errmsg("nao foi possivel ler %s", P.bundles_dir);
            return KAM_EFAIL;
        }
        rc = config_satisfiable(&c, v, n, true);
        bundles_free(v, n);
        if (rc != KAM_OK) {
            errmsg("%s: configuracao de wallpaper invalida; nada foi aplicado", P.prefs_conf);
            return KAM_EBUNDLE;
        }
    }
    msg("%sAplicando %s", O.dry_run ? "[dry-run] " : "", P.prefs_conf);

    /* 1. Visual: logo e contorno do menu */
    int lk, changed = 0, total = 0;
    if ((rc = theme_write_begin(&lk)))
        return rc;
    rc = layout_apply(!strcmp(c.logo, "on"), !strcmp(c.menu_box, "on"), O.dry_run, &changed);
    if (lk >= 0)
        close(lk);
    if (rc)
        return rc;
    total += changed;

    /* 2. Wallpaper: so se o ativo nao corresponde a configuracao */
    char last[ID_MAX + 2 + IMG_NAME_MAX] = "";
    char *lb = read_file(P.last_bg, 1024, NULL);
    if (lb) {
        trim(lb);
        snprintf(last, sizeof last, "%s", lb);
        free(lb);
    }
    size_t bl = strlen(c.bundle);
    bool need = (!strcmp(c.mode, "fixed") && strcmp(last, c.background)) ||
                (!strcmp(c.mode, "set") && (strncmp(last, c.bundle, bl) || last[bl] != '/'));
    char before[16], after[16];
    read_tone(before, sizeof before);
    if (need) {
        msg("%sWallpaper: o ativo (%s) nao corresponde ao modo %s; aplicando", O.dry_run ? "[dry-run] " : "",
            last[0] ? last : "desconhecido", c.mode);
        total++;
        if ((rc = apply_now(false)) != KAM_OK)
            return rc;
    } else if (!O.dry_run) {
        retone_now();   /* TONE pode ter mudado */
    }

    /* 3. Tom */
    if (O.dry_run) {
        msg("[dry-run] Tom: seria reavaliado (TONE=%s, atual: %s)", c.tone, before[0] ? before : "-");
    } else {
        read_tone(after, sizeof after);
        if (strcmp(before, after)) {
            msg("Tom: %s -> %s", before[0] ? before : "-", after[0] ? after : "-");
            total++;
        }
    }
    if (!total && !O.dry_run)
        msg("Tema ja corresponde as preferencias; nada a fazer");
    else if (!O.dry_run)
        note("As mudancas valem a partir do proximo boot");
    return KAM_OK;
}
