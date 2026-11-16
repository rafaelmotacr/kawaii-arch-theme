/* kawaii-arch-manager - arquivos KEY="valor", caminhos e backgrounds.conf
 *
 * Os arquivos de configuracao sao compartilhados com o helper (bash), que
 * os le sem 'source'. Por isso os valores gravados nunca contem aspas,
 * '$', crase, barra invertida ou quebras de linha. */
#include "kam.h"

#include <ctype.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct kam_paths P;
struct kam_opts O;

struct kv {
    char *key;
    char *val;
};
struct kv_list {
    struct kv *v;
    size_t n, cap;
};

struct kv_list *kv_new(void) { return calloc(1, sizeof(struct kv_list)); }

void kv_free(struct kv_list *l)
{
    if (!l)
        return;
    for (size_t i = 0; i < l->n; i++) {
        free(l->v[i].key);
        free(l->v[i].val);
    }
    free(l->v);
    free(l);
}

bool conf_value_safe(const char *v)
{
    for (const unsigned char *p = (const unsigned char *)v; *p; p++)
        if (*p == '"' || *p == '$' || *p == '`' || *p == '\\' || *p < 0x20 || *p == 0x7f)
            return false;
    return true;
}

static bool key_ok(const char *k, size_t n)
{
    if (n == 0 || n > 63 || !(isupper((unsigned char)k[0]) || k[0] == '_'))
        return false;
    for (size_t i = 0; i < n; i++)
        if (!isupper((unsigned char)k[i]) && !isdigit((unsigned char)k[i]) && k[i] != '_')
            return false;
    return true;
}

const char *kv_get(const struct kv_list *l, const char *key)
{
    if (!l)
        return NULL;
    for (size_t i = l->n; i-- > 0;)
        if (!strcmp(l->v[i].key, key))
            return l->v[i].val;
    return NULL;
}

int kv_set(struct kv_list *l, const char *key, const char *val)
{
    if (!conf_value_safe(val) || !key_ok(key, strlen(key))) {
        errno = EINVAL;
        return -1;
    }
    for (size_t i = 0; i < l->n; i++) {
        if (!strcmp(l->v[i].key, key)) {
            char *nv = strdup(val);
            if (!nv)
                return -1;
            free(l->v[i].val);
            l->v[i].val = nv;
            return 0;
        }
    }
    if (l->n == l->cap) {
        size_t nc = l->cap ? l->cap * 2 : 8;
        struct kv *nv = realloc(l->v, nc * sizeof *nv);
        if (!nv)
            return -1;
        l->v = nv;
        l->cap = nc;
    }
    l->v[l->n].key = strdup(key);
    l->v[l->n].val = strdup(val);
    if (!l->v[l->n].key || !l->v[l->n].val)
        return -1;
    l->n++;
    return 0;
}

/* Aceita: comentarios (#), linhas vazias, KEY="valor", KEY=valor
 * (mesmo formato que o helper em bash reconhece) */
int kv_parse_buf(struct kv_list *l, const char *buf, size_t len, char *err, size_t errsz)
{
    size_t i = 0;
    int lineno = 0;
    while (i < len) {
        size_t e = i;
        while (e < len && buf[e] != '\n')
            e++;
        lineno++;
        char line[2048];
        size_t ll = e - i;
        if (ll >= sizeof line) {
            snprintf(err, errsz, "linha %d muito longa", lineno);
            return -1;
        }
        memcpy(line, buf + i, ll);
        line[ll] = '\0';
        i = e + 1;
        trim(line);
        if (!line[0] || line[0] == '#')
            continue;
        char *eq = strchr(line, '=');
        if (!eq || !key_ok(line, (size_t)(eq - line))) {
            snprintf(err, errsz, "linha %d invalida: esperado CHAVE=\"valor\"", lineno);
            return -1;
        }
        *eq = '\0';
        char *v = eq + 1;
        size_t vl = strlen(v);
        if (vl >= 2 && v[0] == '"' && v[vl - 1] == '"') {
            v[vl - 1] = '\0';
            v++;
        } else if (strpbrk(v, " \t\"'")) {
            snprintf(err, errsz, "linha %d: valor com espacos/aspas deve estar entre aspas", lineno);
            return -1;
        }
        if (!conf_value_safe(v)) {
            snprintf(err, errsz, "linha %d: valor contem caracteres nao permitidos", lineno);
            return -1;
        }
        if (kv_set(l, line, v) < 0) {
            snprintf(err, errsz, "linha %d: sem memoria", lineno);
            return -1;
        }
    }
    return 0;
}

/* err: 0 ok, ENOENT ausente, EINVAL malformado, outro errno */
struct kv_list *kv_load(const char *path, int *err)
{
    size_t len;
    char *buf = read_file(path, LIMIT_META_BYTES, &len);
    if (!buf) {
        if (err)
            *err = errno ? errno : EIO;
        return NULL;
    }
    struct kv_list *l = kv_new();
    char e[256];
    if (!l || kv_parse_buf(l, buf, len, e, sizeof e) < 0) {
        if (l)
            warnmsg("%s: %s", path, e);
        free(buf);
        kv_free(l);
        if (err)
            *err = EINVAL;
        return NULL;
    }
    free(buf);
    if (err)
        *err = 0;
    return l;
}

int kv_save(const struct kv_list *l, const char *path, const char *header)
{
    size_t cap = 256 + (header ? strlen(header) : 0), n = 0;
    for (size_t i = 0; i < l->n; i++)
        cap += strlen(l->v[i].key) + strlen(l->v[i].val) + 8;
    char *buf = malloc(cap);
    if (!buf)
        return -1;
    if (header)
        n += (size_t)snprintf(buf + n, cap - n, "%s", header);
    for (size_t i = 0; i < l->n; i++)
        n += (size_t)snprintf(buf + n, cap - n, "%s=\"%s\"\n", l->v[i].key, l->v[i].val);
    int r = write_file_atomic(path, buf, n, 0644);
    free(buf);
    return r;
}

/* ------------------------------------------------------------------ */
static void build(char *dst, const char *suffix)
{
    if (pathf(dst, PATH_MAX, "%s%s", P.root, suffix) < 0)
        dst[0] = '\0';
}

static bool theme_raw_ok(const char *p)
{
    if (p[0] != '/' || strstr(p, "/../") || (strlen(p) >= 3 && !strcmp(p + strlen(p) - 3, "/..")))
        return false;
    for (const unsigned char *c = (const unsigned char *)p; *c; c++)
        if (!(isalnum(*c) || strchr("/._+-", *c)))
            return false;
    return true;
}

int paths_init(void)
{
    memset(&P, 0, sizeof P);
    const char *root = getenv("KAWAII_ROOT");
    if (root && *root) {
        if (root[0] != '/' || pathf(P.root, sizeof P.root, "%s", root) < 0) {
            errmsg("KAWAII_ROOT invalido");
            return KAM_EUSAGE;
        }
        size_t rl = strlen(P.root);
        while (rl > 1 && P.root[rl - 1] == '/')
            P.root[--rl] = '\0';
    }
    build(P.data_dir, "/var/lib/kawaii-arch-manager");
    build(P.bundles_dir, "/var/lib/kawaii-arch-manager/bundles");
    build(P.config_dir, "/var/lib/kawaii-arch-manager/config");
    build(P.state_dir, "/var/lib/kawaii-arch-manager/state");
    build(P.bg_conf, "/var/lib/kawaii-arch-manager/config/backgrounds.conf");
    build(P.paths_conf, "/var/lib/kawaii-arch-manager/config/paths.conf");
    build(P.last_bg, "/var/lib/kawaii-arch-manager/state/last-background");
    build(P.apply_lock, "/var/lib/kawaii-arch-manager/state/apply.lock");
    build(P.manager_lock, "/var/lib/kawaii-arch-manager/state/manager.lock");
    build(P.lib_dir, "/usr/lib/kawaii-arch-manager");
    build(P.helper_path, "/usr/lib/kawaii-arch-manager/" HELPER_NAME);
    build(P.share_dir, "/usr/share/kawaii-arch-manager");
    build(P.payload_dir, "/usr/share/kawaii-arch-manager/payload");
    build(P.unit_path, "/usr/lib/systemd/system/" UNIT_NAME);
    build(P.bin_path, "/usr/bin/" KAM_PROG);

    const char *sc = getenv("KAWAII_SYSTEMCTL");
    /* Em sandbox (KAWAII_ROOT) o systemd real nunca e tocado */
    snprintf(P.systemctl, sizeof P.systemctl, "%s", sc && *sc ? sc : P.root[0] ? "" : "systemctl");

    /* Diretorio do tema: paths.conf (explicito) ou descoberta */
    int e;
    struct kv_list *l = kv_load(P.paths_conf, &e);
    const char *t = l ? kv_get(l, "THEME_DIR") : NULL;
    if (t && *t) {
        if (!theme_raw_ok(t)) {
            warnmsg("THEME_DIR invalido em %s: \"%s\"", P.paths_conf, t);
        } else {
            snprintf(P.theme_raw, sizeof P.theme_raw, "%s", t);
            P.theme_from_conf = true;
        }
        const char *m = kv_get(l, "EXPECTED_MOUNT");
        if (m)
            snprintf(P.expected_mount, sizeof P.expected_mount, "%s", m);
    }
    kv_free(l);
    if (!P.theme_raw[0]) {
        const char *cands[] = {"/boot/grub/themes/" THEME_NAME, "/boot/grub2/themes/" THEME_NAME};
        for (size_t i = 0; i < 2; i++) {
            char tt[PATH_MAX];
            if (pathf(tt, sizeof tt, "%s%s/theme.txt", P.root, cands[i]) == 0 && is_regular(tt)) {
                snprintf(P.theme_raw, sizeof P.theme_raw, "%s", cands[i]);
                break;
            }
        }
    }
    if (P.theme_raw[0] && pathf(P.theme_dir, sizeof P.theme_dir, "%s%s", P.root, P.theme_raw) < 0)
        P.theme_dir[0] = '\0';

    /* PATH previsivel ao executar como root */
    if (geteuid() == 0)
        setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    return KAM_OK;
}

bool mode_valid(const char *m)
{
    return !strcmp(m, "fixed") || !strcmp(m, "set") || !strcmp(m, "global") || !strcmp(m, "balanced");
}

int bgconf_load(struct bgconf *c, bool *exists_out)
{
    memset(c, 0, sizeof *c);
    snprintf(c->mode, sizeof c->mode, "set");
    int e;
    struct kv_list *l = kv_load(P.bg_conf, &e);
    if (exists_out)
        *exists_out = l != NULL;
    if (!l) {
        if (e == ENOENT)
            return KAM_OK;
        errmsg("nao foi possivel ler %s (%s)", P.bg_conf, e == EINVAL ? "formato invalido" : strerror(e));
        return KAM_EBUNDLE;
    }
    const char *v;
    if ((v = kv_get(l, "MODE")) && *v)
        snprintf(c->mode, sizeof c->mode, "%s", v);
    if ((v = kv_get(l, "SELECTED_BUNDLE")))
        snprintf(c->bundle, sizeof c->bundle, "%s", v);
    if ((v = kv_get(l, "SELECTED_BACKGROUND")))
        snprintf(c->background, sizeof c->background, "%s", v);
    kv_free(l);
    return KAM_OK;
}

/* Preserva chaves desconhecidas existentes no arquivo */
int bgconf_save(const struct bgconf *c)
{
    int e;
    struct kv_list *l = kv_load(P.bg_conf, &e);
    if (!l)
        l = kv_new();
    if (!l)
        return KAM_EFAIL;
    if (mkdir_p(P.config_dir, 0755) < 0 || kv_set(l, "MODE", c->mode) < 0 ||
        kv_set(l, "SELECTED_BUNDLE", c->bundle) < 0 ||
        kv_set(l, "SELECTED_BACKGROUND", c->background) < 0 ||
        kv_save(l, P.bg_conf,
                "# Kawaii Arch Manager - preferencias de wallpaper\n"
                "# MODE: fixed | set | global | balanced\n"
                "# SELECTED_BACKGROUND: ID/arquivo.png (usado no modo fixed)\n") < 0) {
        errmsg("falha ao gravar %s: %s", P.bg_conf, strerror(errno));
        kv_free(l);
        return errno == EACCES || errno == EPERM || errno == EROFS ? KAM_EPRIV : KAM_EFAIL;
    }
    kv_free(l);
    return KAM_OK;
}
