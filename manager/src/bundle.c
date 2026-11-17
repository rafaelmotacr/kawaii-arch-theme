/* kawaii-arch-manager - bundles instalados: descoberta, metadados,
 * listagem, selecao e remocao */
#include "kam.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

bool bundle_id_valid(const char *id)
{
    size_t n = strlen(id);
    if (n == 0 || n > ID_MAX)
        return false;
    if (!(islower((unsigned char)id[0]) || isdigit((unsigned char)id[0])))
        return false;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)id[i];
        if (!(islower(c) || isdigit(c) || c == '-' || c == '_'))
            return false;
    }
    return true;
}

/* ^[A-Za-z0-9][A-Za-z0-9._-]*\.png$ (mesma regra do helper) */
bool image_name_valid(const char *name)
{
    size_t n = strlen(name);
    if (n < 5 || n > IMG_NAME_MAX - 4 || strcmp(name + n - 4, ".png") != 0)
        return false;
    if (!isalnum((unsigned char)name[0]))
        return false;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)name[i];
        if (!(isalnum(c) || c == '.' || c == '_' || c == '-'))
            return false;
    }
    return true;
}

static bool text_ok(const char *s)
{
    for (const unsigned char *p = (const unsigned char *)s; *p; p++)
        if (*p < 0x20 || *p == 0x7f)
            return false;
    return true;
}

int parse_manifest(const char *buf, size_t len, struct bundle *b, char *err, size_t errsz)
{
    char e[200];
    if (memchr(buf, '\0', len) || !utf8_valid(buf, len)) {
        snprintf(err, errsz, "manifest.conf nao e texto UTF-8 valido");
        return -1;
    }
    struct kv_list *l = kv_new();
    if (!l || kv_parse_buf(l, buf, len, e, sizeof e) < 0) {
        snprintf(err, errsz, "manifest.conf: %s", l ? e : "sem memoria");
        kv_free(l);
        return -1;
    }
    const char *id = kv_get(l, "ID"), *ver = kv_get(l, "VERSION");
    const char *name = kv_get(l, "NAME");
    const char *author = kv_get(l, "AUTHOR"), *desc = kv_get(l, "DESCRIPTION");
    int rc = -1;
    if (!id || !*id) {
        snprintf(err, errsz, "manifest.conf sem o campo obrigatorio ID");
    } else if (!bundle_id_valid(id)) {
        snprintf(err, errsz, "ID invalido \"%.64s\" (use a-z, 0-9, '-' e '_'; ate %d caracteres)", id, ID_MAX);
    } else if (!ver || !*ver) {
        snprintf(err, errsz, "manifest.conf sem o campo obrigatorio VERSION");
    } else if (!semver_valid(ver)) {
        snprintf(err, errsz, "VERSION invalida \"%.40s\" (esperado SemVer, ex.: 1.0.0)", ver);
    } else if ((name && (strlen(name) > NAME_MAX_LEN || !text_ok(name))) ||
               (author && (strlen(author) > 256 || !text_ok(author))) ||
               (desc && (strlen(desc) > DESC_MAX_LEN || !text_ok(desc)))) {
        snprintf(err, errsz, "manifest.conf: NAME/AUTHOR/DESCRIPTION invalido ou muito longo");
    } else {
        snprintf(b->id, sizeof b->id, "%s", id);
        snprintf(b->version, sizeof b->version, "%s", ver);
        snprintf(b->author, sizeof b->author, "%s", author ? author : "");
        snprintf(b->name, sizeof b->name, "%s", name && *name ? name : id);
        snprintf(b->desc, sizeof b->desc, "%s", desc ? desc : "");
        rc = 0;
    }
    kv_free(l);
    return rc;
}

static int img_cmp(const void *a, const void *b)
{
    return strverscmp(((const struct image *)a)->name, ((const struct image *)b)->name);
}

void bundle_free(struct bundle *b)
{
    free(b->imgs);
    b->imgs = NULL;
    b->nimg = 0;
}

/* Carrega um bundle de um diretorio. Retorna 0 se metadados validos. */
int bundle_load(const char *dir, const char *expect_id, struct bundle *b)
{
    memset(b, 0, sizeof *b);
    snprintf(b->dir, sizeof b->dir, "%s", dir);
    if (expect_id)
        snprintf(b->id, sizeof b->id, "%s", expect_id);

    char path[PATH_MAX];
    size_t len;
    char *buf;

    pathf(path, sizeof path, "%s/manifest.conf", dir);
    if (!(buf = read_file(path, 16384, &len))) {
        snprintf(b->err, sizeof b->err, "manifest.conf ausente ou ilegivel");
        return -1;
    }
    int r = parse_manifest(buf, len, b, b->err, sizeof b->err);
    free(buf);
    if (r < 0)
        return -1;
    if (expect_id && strcmp(b->id, expect_id) != 0) {
        snprintf(b->err, sizeof b->err, "ID do manifesto (%s) difere do diretorio (%s)", b->id, expect_id);
        return -1;
    }

    pathf(path, sizeof path, "%s/backgrounds", dir);
    DIR *d = is_dir(path) ? opendir(path) : NULL;
    if (!d) {
        snprintf(b->err, sizeof b->err, "diretorio backgrounds/ ausente");
        return -1;
    }
    size_t cap = 0;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (!image_name_valid(de->d_name))
            continue;
        char ip[PATH_MAX], e[128];
        struct stat st;
        if (pathf(ip, sizeof ip, "%s/%s", path, de->d_name) < 0 || lstat(ip, &st) < 0 ||
            !S_ISREG(st.st_mode))
            continue;
        if (b->nimg == cap) {
            cap = cap ? cap * 2 : 64;
            struct image *ni = realloc(b->imgs, cap * sizeof *ni);
            if (!ni) {
                closedir(d);
                snprintf(b->err, sizeof b->err, "sem memoria");
                return -1;
            }
            b->imgs = ni;
        }
        struct image *im = &b->imgs[b->nimg++];
        snprintf(im->name, sizeof im->name, "%s", de->d_name);
        im->size = st.st_size;
        im->valid = png_check_file(ip, NULL, e, sizeof e) == 0;
        if (im->valid)
            b->nvalid++;
        b->total += st.st_size;
    }
    closedir(d);
    if (b->nimg)
        qsort(b->imgs, b->nimg, sizeof *b->imgs, img_cmp);
    b->valid = true;
    return 0;
}

static int bundle_cmp(const void *a, const void *b)
{
    return strcmp(((const struct bundle *)a)->id, ((const struct bundle *)b)->id);
}

/* Lista bundles instalados (validos e invalidos), ordenados por ID.
 * Diretorios iniciados por '.' sao temporarios e ignorados. */
int bundles_scan(struct bundle **out, size_t *n)
{
    *out = NULL;
    *n = 0;
    DIR *d = opendir(P.bundles_dir);
    if (!d)
        return errno == ENOENT ? 0 : -1;
    size_t cap = 0;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.')
            continue;
        char p[PATH_MAX];
        if (pathf(p, sizeof p, "%s/%s", P.bundles_dir, de->d_name) < 0 || !is_dir(p))
            continue;
        if (*n == cap) {
            cap = cap ? cap * 2 : 16;
            struct bundle *nb = realloc(*out, cap * sizeof *nb);
            if (!nb) {
                closedir(d);
                return -1;
            }
            *out = nb;
        }
        struct bundle *b = &(*out)[(*n)++];
        if (!bundle_id_valid(de->d_name)) {
            memset(b, 0, sizeof *b);
            snprintf(b->id, sizeof b->id, "%.64s", de->d_name);
            snprintf(b->err, sizeof b->err, "nome de diretorio nao e um ID valido");
            continue;
        }
        bundle_load(p, de->d_name, b);
    }
    closedir(d);
    if (*n)
        qsort(*out, *n, sizeof **out, bundle_cmp);
    return 0;
}

void bundles_free(struct bundle *v, size_t n)
{
    for (size_t i = 0; i < n; i++)
        bundle_free(&v[i]);
    free(v);
}

struct bundle *bundle_find(struct bundle *v, size_t n, const char *id)
{
    for (size_t i = 0; i < n; i++)
        if (!strcmp(v[i].id, id))
            return &v[i];
    return NULL;
}

/* Lock exclusivo para operacoes de escrita do manager */
int kam_lock(void)
{
    if (mkdir_p(P.state_dir, 0755) < 0) {
        errmsg("nao foi possivel criar %s: %s", P.state_dir, strerror(errno));
        return -1;
    }
    int fd = lock_file(P.manager_lock, 30);
    if (fd < 0)
        errmsg("outra instancia do %s esta em execucao (%s)", KAM_PROG, P.manager_lock);
    return fd;
}

/* ------------------------------------------------------------------ */
int cmd_list_bundles(void)
{
    struct bundle *v;
    size_t n;
    struct prefs c;
    prefs_load(&c, NULL);
    if (bundles_scan(&v, &n) < 0) {
        errmsg("nao foi possivel ler %s: %s", P.bundles_dir, strerror(errno));
        return KAM_EFAIL;
    }
    if (n == 0) {
        msg("Nenhum bundle instalado em %s", P.bundles_dir);
        note("Importe um com: sudo %s --import-bundle ARQUIVO.kawall", KAM_PROG);
        return KAM_OK;
    }
    char fixed_bundle[ID_MAX + 1] = "";
    sscanf(c.background, "%64[^/]", fixed_bundle);

    msg("Bundles instalados em %s", P.bundles_dir);
    printf("\n  %-3s %-20s %-10s %8s %11s  %s\n", "#", "ID", "VERSAO", "IMAGENS", "TAMANHO", "NOME");
    long long sum = 0;
    for (size_t i = 0; i < n; i++) {
        struct bundle *b = &v[i];
        char sz[32], idcol[32];
        human_size(b->total, sz, sizeof sz);
        bool sel = (!strcmp(c.mode, "set") && !strcmp(c.bundle, b->id)) ||
                   (!strcmp(c.mode, "fixed") && !strcmp(fixed_bundle, b->id));
        snprintf(idcol, sizeof idcol, "%.18s%s", b->id, sel ? " *" : "");
        if (!b->valid) {
            printf("  %-3zu %-20s (invalido: %s)\n", i + 1, idcol, b->err);
            continue;
        }
        sum += b->total;
        printf("  %-3zu %-20s %-10s %8zu %11s  %s\n", i + 1, idcol, b->version, b->nimg, sz, b->name);
        if (b->desc[0])
            printf("  %-3s %-20s %s\n", "", "", b->desc);
        if (b->nvalid != b->nimg)
            printf("  %-3s %-20s aviso: %zu imagem(ns) invalida(s) para o GRUB serao ignoradas\n", "",
                   "", b->nimg - b->nvalid);
    }
    char tot[32];
    human_size(sum, tot, sizeof tot);
    printf("\n  Total: %zu bundle(s), %s. Modo atual: %s", n, tot, c.mode);
    if (!strcmp(c.mode, "set") || !strcmp(c.mode, "fixed"))
        printf(" (* = selecionado)");
    printf("\n");
    bundles_free(v, n);
    return KAM_OK;
}

static int checked_bundle(struct bundle *v, size_t n, const char *id, struct bundle **out)
{
    if (!bundle_id_valid(id)) {
        errmsg("ID de bundle invalido: \"%s\"", id);
        return KAM_EUSAGE;
    }
    struct bundle *b = bundle_find(v, n, id);
    if (!b) {
        errmsg("bundle '%s' nao esta instalado (veja --list-bundles)", id);
        return KAM_EBUNDLE;
    }
    if (!b->valid) {
        errmsg("bundle '%s' e invalido: %s", id, b->err);
        return KAM_EBUNDLE;
    }
    if (b->nvalid == 0) {
        errmsg("bundle '%s' nao possui imagens validas", id);
        return KAM_EBUNDLE;
    }
    *out = b;
    return KAM_OK;
}

/* Verifica se a configuracao (modo + selecoes) e satisfeita */
int config_satisfiable(const struct prefs *c, struct bundle *v, size_t n, bool verbose)
{
    struct bundle *b;
    size_t usable = 0;
    for (size_t i = 0; i < n; i++)
        if (v[i].valid && v[i].nvalid)
            usable++;
    if (!strcmp(c->mode, "set")) {
        if (!c->bundle[0]) {
            if (verbose)
                errmsg("modo 'set' exige um bundle selecionado: use --set-bundle ID");
            return KAM_ECONFLICT;
        }
        return checked_bundle(v, n, c->bundle, &b) == KAM_OK ? KAM_OK : KAM_ECONFLICT;
    }
    if (!strcmp(c->mode, "fixed")) {
        char id[ID_MAX + 1] = "", name[IMG_NAME_MAX + 1] = "";
        if (sscanf(c->background, "%64[^/]/%255s", id, name) != 2) {
            if (verbose)
                errmsg("modo 'fixed' exige uma imagem: use --set-background ID/ARQUIVO");
            return KAM_ECONFLICT;
        }
        if (checked_bundle(v, n, id, &b) != KAM_OK)
            return KAM_ECONFLICT;
        for (size_t i = 0; i < b->nimg; i++)
            if (!strcmp(b->imgs[i].name, name) && b->imgs[i].valid)
                return KAM_OK;
        if (verbose)
            errmsg("imagem fixa '%s' nao existe ou e invalida", c->background);
        return KAM_ECONFLICT;
    }
    if (usable == 0) {
        if (verbose)
            errmsg("modo '%s' exige pelo menos um bundle com imagens validas", c->mode);
        return KAM_ECONFLICT;
    }
    return KAM_OK;
}

int cmd_set_bundle(const char *id)
{
    int rc = require_root("--set-bundle");
    if (rc)
        return rc;
    int lk = kam_lock();
    if (lk < 0)
        return KAM_EFAIL;
    struct bundle *v, *b;
    size_t n;
    struct prefs c;
    if ((rc = prefs_load(&c, NULL)) || bundles_scan(&v, &n) < 0) {
        close(lk);
        return rc ? rc : KAM_EFAIL;
    }
    if ((rc = checked_bundle(v, n, id, &b)) == KAM_OK) {
        snprintf(c.bundle, sizeof c.bundle, "%s", id);
        if ((rc = prefs_save(&c)) == KAM_OK) {
            msg("Bundle selecionado: %s (%s, %zu imagens)", b->id, b->name, b->nvalid);
            if (strcmp(c.mode, "set"))
                note("O modo atual e '%s'; o bundle so e usado no modo 'set' (--set-mode set).", c.mode);
            else
                note("Aplicado no proximo boot, ou agora com: sudo %s --randomize", KAM_PROG);
        }
    }
    bundles_free(v, n);
    close(lk);
    return rc;
}

int cmd_set_mode(const char *mode)
{
    if (!mode_valid(mode)) {
        errmsg("modo invalido: \"%s\" (use fixed, set, global ou balanced)", mode);
        return KAM_EUSAGE;
    }
    int rc = require_root("--set-mode");
    if (rc)
        return rc;
    int lk = kam_lock();
    if (lk < 0)
        return KAM_EFAIL;
    struct bundle *v;
    size_t n;
    struct prefs c;
    if ((rc = prefs_load(&c, NULL)) || bundles_scan(&v, &n) < 0) {
        close(lk);
        return rc ? rc : KAM_EFAIL;
    }
    snprintf(c.mode, sizeof c.mode, "%s", mode);
    if ((rc = config_satisfiable(&c, v, n, true)) == KAM_OK && (rc = prefs_save(&c)) == KAM_OK) {
        msg("Modo de selecao: %s", mode);
        note("Aplicado no proximo boot, ou agora com: sudo %s --randomize", KAM_PROG);
    }
    bundles_free(v, n);
    close(lk);
    return rc;
}

int cmd_set_background(const char *spec)
{
    char id[ID_MAX + 2] = "", name[IMG_NAME_MAX + 2] = "";
    const char *slash = strchr(spec, '/');
    if (!slash || (size_t)(slash - spec) > ID_MAX || strlen(slash + 1) > IMG_NAME_MAX - 4) {
        errmsg("formato invalido: \"%s\" (use ID/ARQUIVO, ex.: gothic/background5.png)", spec);
        return KAM_EUSAGE;
    }
    memcpy(id, spec, (size_t)(slash - spec));
    snprintf(name, sizeof name, "%s", slash + 1);
    size_t nl = strlen(name);
    if (nl < 4 || strcmp(name + nl - 4, ".png"))
        strcat(name, ".png");
    if (!image_name_valid(name)) {
        errmsg("nome de arquivo invalido: \"%s\"", name);
        return KAM_EUSAGE;
    }
    int rc = require_root("--set-background");
    if (rc)
        return rc;
    int lk = kam_lock();
    if (lk < 0)
        return KAM_EFAIL;
    struct bundle *v, *b;
    size_t n;
    struct prefs c;
    if ((rc = prefs_load(&c, NULL)) || bundles_scan(&v, &n) < 0) {
        close(lk);
        return rc ? rc : KAM_EFAIL;
    }
    if ((rc = checked_bundle(v, n, id, &b)) == KAM_OK) {
        struct image *im = NULL;
        for (size_t i = 0; i < b->nimg; i++)
            if (!strcmp(b->imgs[i].name, name))
                im = &b->imgs[i];
        if (!im) {
            errmsg("'%s' nao existe no bundle '%s'", name, id);
            rc = KAM_EBUNDLE;
        } else if (!im->valid) {
            errmsg("'%s/%s' nao e um PNG compativel com o GRUB", id, name);
            rc = KAM_EBUNDLE;
        } else {
            snprintf(c.mode, sizeof c.mode, "fixed");
            snprintf(c.background, sizeof c.background, "%s/%s", id, name);
            if ((rc = prefs_save(&c)) == KAM_OK)
                msg("Wallpaper fixo: %s (modo: fixed)", c.background);
        }
    }
    bundles_free(v, n);
    close(lk);
    if (rc == KAM_OK)
        rc = apply_now(true);
    return rc;
}

int cmd_remove_bundle(const char *id)
{
    if (!bundle_id_valid(id)) {
        errmsg("ID de bundle invalido: \"%s\"", id);
        return KAM_EUSAGE;
    }
    int rc = require_root("--remove-bundle");
    if (rc)
        return rc;
    int lk = kam_lock();
    if (lk < 0)
        return KAM_EFAIL;
    struct bundle *v, *b;
    size_t n;
    struct prefs c;
    if ((rc = prefs_load(&c, NULL)) || bundles_scan(&v, &n) < 0) {
        close(lk);
        return rc ? rc : KAM_EFAIL;
    }
    b = bundle_find(v, n, id);
    char fixed_bundle[ID_MAX + 1] = "";
    sscanf(c.background, "%64[^/]", fixed_bundle);
    if (!b) {
        errmsg("bundle '%s' nao esta instalado", id);
        rc = KAM_EBUNDLE;
        goto out;
    }
    if (!strcmp(c.bundle, id) || !strcmp(fixed_bundle, id)) {
        errmsg("o bundle '%s' esta selecionado na configuracao (%s%s%s).", id,
               !strcmp(c.bundle, id) ? "SELECTED_BUNDLE" : "",
               !strcmp(c.bundle, id) && !strcmp(fixed_bundle, id) ? " e " : "",
               !strcmp(fixed_bundle, id) ? "SELECTED_BACKGROUND" : "");
        fprintf(stderr, "       Selecione outro antes (--set-bundle / --set-background) e tente novamente.\n");
        rc = KAM_ECONFLICT;
        goto out;
    }
    if (!strcmp(c.mode, "global") || !strcmp(c.mode, "balanced")) {
        size_t others = 0;
        for (size_t i = 0; i < n; i++)
            if (strcmp(v[i].id, id) && v[i].valid && v[i].nvalid)
                others++;
        if (!others) {
            errmsg("'%s' e o unico bundle utilizavel no modo '%s'; importe outro antes de remove-lo", id, c.mode);
            rc = KAM_ECONFLICT;
            goto out;
        }
    }
    char sz[32];
    human_size(b->total, sz, sizeof sz);
    msg("Remover o bundle '%s' (%s, versao %s, %zu imagens, %s)?", id, b->valid ? b->name : "invalido",
        b->valid ? b->version : "-", b->nimg, sz);
    if ((rc = confirm_rc("Confirmar remocao permanente", false)) != KAM_OK)
        goto out;
    char trash[PATH_MAX];
    pathf(trash, sizeof trash, "%s/.remove-%s-%ld", P.bundles_dir, id, (long)getpid());
    if (rename(b->dir, trash) < 0) {
        errmsg("falha ao remover %s: %s", b->dir, strerror(errno));
        rc = KAM_EFAIL;
        goto out;
    }
    fsync_dir(P.bundles_dir);
    if (rm_rf(trash) < 0)
        warnmsg("restos em %s nao puderam ser apagados: %s", trash, strerror(errno));
    msg("Bundle '%s' removido.", id);
    rc = KAM_OK;
out:
    bundles_free(v, n);
    close(lk);
    return rc;
}
