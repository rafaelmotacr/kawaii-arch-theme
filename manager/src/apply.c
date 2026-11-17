/* kawaii-arch-manager - selecao e aplicacao do wallpaper ativo
 *
 * Se o Background Helper estiver instalado, ele e usado (fonte unica da
 * regra de selecao). Caso contrario, o manager executa a funcionalidade
 * equivalente implementada aqui, com as mesmas regras e garantias, e
 * ajusta o tom do tema (icones, cores, logo) com a copia do helper que
 * fica no payload ('grub-random-bg.sh --retone'): uma unica implementacao
 * dessa regra. */
#include "kam.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Ponto de montagem do filesystem que contem path: sobe na arvore ate
 * o st_dev mudar (mesmo algoritmo de 'stat -c %m', usado pelo helper e
 * pelo instalador). Binds do mesmo filesystem - como os criados pelo
 * ReadWritePaths= da unidade - nao contam como novo ponto de montagem. */
static int mount_point_of(const char *path, char *out, size_t sz)
{
    char cur[PATH_MAX], parent[PATH_MAX];
    struct stat st, ps;
    if (!realpath(path, cur) || stat(cur, &st) < 0)
        return -1;
    while (strcmp(cur, "/")) {
        snprintf(parent, sizeof parent, "%s", cur);
        char *s = strrchr(parent, '/');
        if (s == parent)
            parent[1] = '\0';
        else
            *s = '\0';
        if (stat(parent, &ps) < 0)
            return -1;
        if (ps.st_dev != st.st_dev || (ps.st_ino == st.st_ino))
            break;
        snprintf(cur, sizeof cur, "%s", parent);
    }
    snprintf(out, sz, "%s", cur);
    return 0;
}

int theme_mount_check(char *err, size_t errsz)
{
    char tt[PATH_MAX], mp[PATH_MAX];
    if (!P.theme_dir[0]) {
        snprintf(err, errsz, "diretorio do tema desconhecido (%s ausente e tema nao encontrado em /boot)", P.paths_conf);
        return KAM_EPRIV;
    }
    pathf(tt, sizeof tt, "%s/theme.txt", P.theme_dir);
    if (!is_dir(P.theme_dir) || !is_regular(tt)) {
        snprintf(err, errsz, "tema nao encontrado em %s (particao de boot montada?)", P.theme_dir);
        return KAM_EPRIV;
    }
    if (mount_point_of(P.theme_dir, mp, sizeof mp) < 0) {
        snprintf(err, errsz, "nao foi possivel determinar o ponto de montagem de %s", P.theme_dir);
        return KAM_EPRIV;
    }
    const char *raw = mp;
    size_t rl = strlen(P.root);
    if (rl && !strncmp(mp, P.root, rl) && (mp[rl] == '/' || !mp[rl]))
        raw = mp[rl] ? mp + rl : "/";
    if (P.expected_mount[0] && strcmp(raw, P.expected_mount)) {
        snprintf(err, errsz, "%s esta em '%s', mas era esperado '%s' (particao nao montada?)", P.theme_raw,
                 raw, P.expected_mount);
        return KAM_EPRIV;
    }
    char fstab[PATH_MAX];
    pathf(fstab, sizeof fstab, "%s/etc/fstab", P.root);
    FILE *f = fopen(fstab, "re");
    if (f) {
        char line[4096], best[PATH_MAX] = "";
        while (fgets(line, sizeof line, f)) {
            char dev[1024], m[PATH_MAX];
            if (line[strspn(line, " \t")] == '#' || sscanf(line, "%1023s %4095s", dev, m) != 2)
                continue;
            size_t l = strlen(m);
            while (l > 1 && m[l - 1] == '/')
                m[--l] = '\0';
            if (m[0] != '/' || !strcmp(m, "/"))
                continue;
            if (!strncmp(P.theme_raw, m, l) && (P.theme_raw[l] == '\0' || P.theme_raw[l] == '/') &&
                l > strlen(best))
                snprintf(best, sizeof best, "%s", m);
        }
        fclose(f);
        if (best[0] && strcmp(best, raw)) {
            snprintf(err, errsz, "%s esta declarado no fstab, mas nao esta montado (tema em '%s')", best, raw);
            return KAM_EPRIV;
        }
    }
    return KAM_OK;
}

/* ------------------------------------------------------------------ */
struct cand {
    struct bundle *b;
    struct image *im;
};

static bool is_last(const struct cand *c, const char *last)
{
    char s[ID_MAX + 2 + IMG_NAME_MAX];
    snprintf(s, sizeof s, "%s/%s", c->b->id, c->im->name);
    return !strcmp(s, last);
}

/* Escolhe uniformemente evitando 'last' quando ha alternativa */
static int pick(struct cand *v, size_t n, const char *last, struct cand *out)
{
    size_t m = 0;
    struct cand lastc = {0};
    for (size_t i = 0; i < n; i++) {
        if (last[0] && is_last(&v[i], last))
            lastc = v[i];
        else
            v[m++] = v[i];
    }
    if (m) {
        *out = v[rand_below(m)];
        return 0;
    }
    if (lastc.b) {
        *out = lastc;
        return 0;
    }
    return -1;
}

static int select_internal(const struct bgconf *c, struct bundle *v, size_t n, const char *last,
                           struct cand *out, char *err, size_t errsz)
{
    if (!strcmp(c->mode, "fixed")) {
        char id[ID_MAX + 1] = "", name[IMG_NAME_MAX + 1] = "";
        if (sscanf(c->background, "%64[^/]/%255s", id, name) != 2) {
            snprintf(err, errsz, "modo 'fixed' sem SELECTED_BACKGROUND valido");
            return -1;
        }
        struct bundle *b = bundle_find(v, n, id);
        if (!b || !b->valid) {
            snprintf(err, errsz, "bundle '%s' de SELECTED_BACKGROUND nao esta instalado ou e invalido", id);
            return -1;
        }
        for (size_t i = 0; i < b->nimg; i++)
            if (!strcmp(b->imgs[i].name, name) && b->imgs[i].valid) {
                out->b = b;
                out->im = &b->imgs[i];
                return 0;
            }
        snprintf(err, errsz, "imagem fixa ausente ou invalida: %s", c->background);
        return -1;
    }

    size_t total = 0;
    for (size_t i = 0; i < n; i++)
        if (v[i].valid)
            total += v[i].nimg;
    struct cand *all = calloc(total ? total : 1, sizeof *all);
    if (!all) {
        snprintf(err, errsz, "sem memoria");
        return -1;
    }
    int rc = -1;
    if (!strcmp(c->mode, "set") || !strcmp(c->mode, "global")) {
        bool set = !strcmp(c->mode, "set");
        size_t m = 0;
        if (set) {
            struct bundle *b = c->bundle[0] ? bundle_find(v, n, c->bundle) : NULL;
            if (!b || !b->valid) {
                snprintf(err, errsz, "bundle selecionado '%s' nao esta instalado ou e invalido", c->bundle);
                goto out;
            }
        }
        for (size_t i = 0; i < n; i++) {
            if (!v[i].valid || (set && strcmp(v[i].id, c->bundle)))
                continue;
            for (size_t k = 0; k < v[i].nimg; k++)
                if (v[i].imgs[k].valid)
                    all[m++] = (struct cand){&v[i], &v[i].imgs[k]};
        }
        if (pick(all, m, last, out) < 0) {
            snprintf(err, errsz, set ? "nenhuma imagem valida no bundle '%s'" : "nenhuma imagem valida em nenhum bundle%s",
                     set ? c->bundle : "");
            goto out;
        }
        rc = 0;
    } else if (!strcmp(c->mode, "balanced")) {
        /* bundles elegiveis: com ao menos uma imagem valida diferente de last */
        struct bundle **elig = calloc(n ? n : 1, sizeof *elig);
        size_t ne = 0;
        struct cand lastc = {0};
        if (!elig) {
            snprintf(err, errsz, "sem memoria");
            goto out;
        }
        for (size_t i = 0; i < n; i++) {
            if (!v[i].valid)
                continue;
            bool any = false;
            for (size_t k = 0; k < v[i].nimg; k++) {
                if (!v[i].imgs[k].valid)
                    continue;
                struct cand cc = {&v[i], &v[i].imgs[k]};
                if (last[0] && is_last(&cc, last))
                    lastc = cc;
                else
                    any = true;
            }
            if (any)
                elig[ne++] = &v[i];
        }
        if (ne) {
            struct bundle *b = elig[rand_below(ne)];
            size_t m = 0;
            for (size_t k = 0; k < b->nimg; k++)
                if (b->imgs[k].valid)
                    all[m++] = (struct cand){b, &b->imgs[k]};
            rc = pick(all, m, last, out);
        } else if (lastc.b) {
            *out = lastc;
            rc = 0;
        }
        free(elig);
        if (rc < 0)
            snprintf(err, errsz, "modo 'balanced': nenhum bundle com imagens validas");
    } else {
        snprintf(err, errsz, "MODE invalido: \"%s\"", c->mode);
    }
out:
    free(all);
    return rc;
}

static int keep_or_fallback(void)
{
    char act[PATH_MAX], fb[PATH_MAX], tmp[PATH_MAX], e[128];
    pathf(act, sizeof act, "%s/%s", P.theme_dir, ACTIVE_NAME);
    pathf(fb, sizeof fb, "%s/%s", P.theme_dir, FALLBACK_NAME);
    pathf(tmp, sizeof tmp, "%s/%s.tmp", P.theme_dir, ACTIVE_NAME);
    if (png_check_file(act, NULL, e, sizeof e) == 0) {
        warnmsg("wallpaper ativo preservado sem alteracoes");
        return 0;
    }
    if (png_check_file(fb, NULL, e, sizeof e) == 0 && copy_file_atomic(fb, act, tmp, 0644) == 0) {
        warnmsg("wallpaper ativo ausente/invalido; %s aplicado", FALLBACK_NAME);
        return 0;
    }
    errmsg("nenhum wallpaper valido disponivel (nem %s nem %s)", ACTIVE_NAME, FALLBACK_NAME);
    return -1;
}

/* Ajusta o tom do tema ao wallpaper ativo usando o helper do payload
 * (nao precisa estar instalado). Falhas so geram aviso. */
static void retone_from_payload(void)
{
    char h[PATH_MAX];
    pathf(h, sizeof h, "%s/%s", P.payload_dir, HELPER_NAME);
    if (!is_regular(h)) {
        note("Helper ausente no payload; o tom do tema nao foi ajustado");
        return;
    }
    char *argv[] = {"bash", h, "--retone", "--quiet", NULL};
    int r = run_cmd(argv, NULL, 0, false);
    if (r != 0)
        warnmsg("nao foi possivel ajustar o tom do tema ao wallpaper (codigo %d)", r);
}

static int apply_internal(void)
{
    bool retone = false;
    char err[512], last[ID_MAX + 2 + IMG_NAME_MAX] = "";
    struct bgconf c;
    bool have;
    struct bundle *v = NULL;
    size_t n = 0;
    int rc = bgconf_load(&c, &have);
    if (rc)
        return rc;
    char *lb = read_file(P.last_bg, 1024, NULL);
    if (lb) {
        trim(lb);
        if (strchr(lb, '/'))
            snprintf(last, sizeof last, "%s", lb);
        free(lb);
    }
    if (bundles_scan(&v, &n) < 0) {
        errmsg("nao foi possivel ler %s: %s", P.bundles_dir, strerror(errno));
        return KAM_EFAIL;
    }
    struct cand ch;
    int sel = have ? select_internal(&c, v, n, last, &ch, err, sizeof err) : -1;
    if (!have)
        snprintf(err, sizeof err, "configuracao ausente: %s", P.bg_conf);

    if (O.dry_run) {
        if (sel == 0)
            printf("%s/%s\n", ch.b->id, ch.im->name);
        else
            errmsg("%s", err);
        bundles_free(v, n);
        return sel == 0 ? KAM_OK : KAM_EBUNDLE;
    }

    if (mkdir_p(P.state_dir, 0755) < 0) {
        errmsg("nao foi possivel criar %s: %s", P.state_dir, strerror(errno));
        bundles_free(v, n);
        return errno == EACCES ? KAM_EPRIV : KAM_EFAIL;
    }
    int lk = lock_file(P.apply_lock, 30);
    if (lk < 0) {
        errmsg("outra aplicacao de wallpaper esta em andamento");
        bundles_free(v, n);
        return KAM_ECONFLICT;
    }
    if ((rc = theme_mount_check(err, sizeof err)) != KAM_OK) {
        errmsg("%s", err);
        goto out;
    }
    if (access(P.theme_dir, W_OK) < 0) {
        errmsg("sem permissao de escrita em %s", P.theme_dir);
        rc = KAM_EPRIV;
        goto out;
    }
    if (sel < 0) {
        errmsg("%s", err);
        rc = keep_or_fallback() == 0 ? KAM_EBUNDLE : KAM_EFAIL;
        retone = rc == KAM_EBUNDLE;
        goto out;
    }
    char src[PATH_MAX], dst[PATH_MAX], tmp[PATH_MAX], e[128] = "";
    pathf(src, sizeof src, "%s/backgrounds/%s", ch.b->dir, ch.im->name);
    pathf(dst, sizeof dst, "%s/%s", P.theme_dir, ACTIVE_NAME);
    pathf(tmp, sizeof tmp, "%s/%s.tmp", P.theme_dir, ACTIVE_NAME);
    errno = 0;
    if (png_check_file(src, NULL, e, sizeof e) < 0 || copy_file_atomic(src, dst, tmp, 0644) < 0 ||
        png_check_file(dst, NULL, e, sizeof e) < 0) {
        errmsg("falha ao aplicar %s: %s; wallpaper anterior preservado", src, errno ? strerror(errno) : e);
        rc = KAM_EFAIL;
        goto out;
    }
    char lastv[ID_MAX + 3 + IMG_NAME_MAX];
    int ll = snprintf(lastv, sizeof lastv, "%s/%s\n", ch.b->id, ch.im->name);
    if (write_file_atomic(P.last_bg, lastv, (size_t)ll, 0644) < 0)
        warnmsg("nao foi possivel atualizar %s", P.last_bg);
    msg("Wallpaper aplicado: %s/%s", ch.b->id, ch.im->name);
    rc = KAM_OK;
    retone = true;
out:
    close(lk);   /* o helper usa o mesmo lock */
    bundles_free(v, n);
    if (retone)
        retone_from_payload();
    return rc;
}

int apply_now(bool announce)
{
    if (is_executable(P.helper_path)) {
        char *argv[] = {P.helper_path, O.dry_run ? "--dry-run" : NULL, NULL};
        if (announce && !O.dry_run)
            msg("Aplicando com o Background Helper (%s)", P.helper_path);
        int r = run_cmd(argv, NULL, 0, false);
        if (r < 0) {
            errmsg("nao foi possivel executar %s", P.helper_path);
            return KAM_EFAIL;
        }
        return r > KAM_EPRIV ? KAM_EFAIL : r;
    }
    if (announce && !O.dry_run)
        msg("Background Helper nao instalado; usando a selecao interna do manager");
    return apply_internal();
}

int cmd_randomize(void)
{
    int rc;
    if (!O.dry_run && (rc = require_root("--randomize")))
        return rc;
    struct bgconf c;
    if ((rc = bgconf_load(&c, NULL)))
        return rc;
    if (!strcmp(c.mode, "fixed"))
        note("Modo 'fixed': sera aplicado sempre %s", c.background[0] ? c.background : "(nao definido)");
    return apply_now(true);
}
