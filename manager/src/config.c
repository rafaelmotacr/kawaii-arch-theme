/* kawaii-arch-manager - arquivos KEY="valor", caminhos e preferences.conf
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
    build(P.prefs_conf, "/var/lib/kawaii-arch-manager/config/preferences.conf");
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

bool onoff_valid(const char *v) { return !strcmp(v, "on") || !strcmp(v, "off"); }
bool tone_valid(const char *v) { return !strcmp(v, "auto") || !strcmp(v, "dark") || !strcmp(v, "light"); }

static const char *const PREF_KEYS[] = {"MODE", "SELECTED_BUNDLE", "SELECTED_BACKGROUND", "LOGO", "MENU_BOX", "TONE", "ON_FRESH_INSTALL"};
#define NPREF_KEYS (sizeof PREF_KEYS / sizeof PREF_KEYS[0])

/* Chave ausente = padrao (o mesmo do modelo config/preferences.conf) */
int prefs_load(struct prefs *c, bool *exists_out)
{
    memset(c, 0, sizeof *c);
    snprintf(c->mode, sizeof c->mode, "set");
    snprintf(c->logo, sizeof c->logo, "on");
    snprintf(c->menu_box, sizeof c->menu_box, "on");
    snprintf(c->tone, sizeof c->tone, "auto");
    snprintf(c->on_fresh, sizeof c->on_fresh, "backup");
    int e;
    struct kv_list *l = kv_load(P.prefs_conf, &e);
    if (exists_out)
        *exists_out = l != NULL;
    if (!l) {
        if (e == ENOENT)
            return KAM_OK;
        errmsg("nao foi possivel ler %s (%s)", P.prefs_conf, e == EINVAL ? "formato invalido" : strerror(e));
        return KAM_EBUNDLE;
    }
    const char *v;
    if ((v = kv_get(l, "MODE")) && *v)
        snprintf(c->mode, sizeof c->mode, "%s", v);
    if ((v = kv_get(l, "SELECTED_BUNDLE")))
        snprintf(c->bundle, sizeof c->bundle, "%s", v);
    if ((v = kv_get(l, "SELECTED_BACKGROUND")))
        snprintf(c->background, sizeof c->background, "%s", v);
    if ((v = kv_get(l, "LOGO")) && *v)
        snprintf(c->logo, sizeof c->logo, "%s", v);
    if ((v = kv_get(l, "MENU_BOX")) && *v)
        snprintf(c->menu_box, sizeof c->menu_box, "%s", v);
    if ((v = kv_get(l, "TONE")) && *v)
        snprintf(c->tone, sizeof c->tone, "%s", v);
    if ((v = kv_get(l, "ON_FRESH_INSTALL")) && *v)
        snprintf(c->on_fresh, sizeof c->on_fresh, "%s", v);
    kv_free(l);
    return KAM_OK;
}

int prefs_check(const struct prefs *c, char *err, size_t errsz)
{
    if (!mode_valid(c->mode))
        snprintf(err, errsz, "MODE invalido: \"%s\" (fixed | set | global | balanced)", c->mode);
    else if (c->bundle[0] && !bundle_id_valid(c->bundle))
        snprintf(err, errsz, "SELECTED_BUNDLE invalido: \"%s\"", c->bundle);
    else if (!onoff_valid(c->logo))
        snprintf(err, errsz, "LOGO invalido: \"%s\" (on | off)", c->logo);
    else if (!onoff_valid(c->menu_box))
        snprintf(err, errsz, "MENU_BOX invalido: \"%s\" (on | off)", c->menu_box);
    else if (!tone_valid(c->tone))
        snprintf(err, errsz, "TONE invalido: \"%s\" (auto | dark | light)", c->tone);
    else if (strcmp(c->on_fresh, "backup") && strcmp(c->on_fresh, "override") && strcmp(c->on_fresh, "keep"))
        snprintf(err, errsz, "ON_FRESH_INSTALL invalido: \"%s\" (backup | override | keep)", c->on_fresh);
    else
        return 0;
    return -1;
}

void prefs_warn_unknown(void)
{
    int e;
    struct kv_list *l = kv_load(P.prefs_conf, &e);
    if (!l)
        return;
    for (size_t i = 0; i < l->n; i++) {
        bool known = false;
        for (size_t k = 0; k < NPREF_KEYS; k++)
            known |= !strcmp(l->v[i].key, PREF_KEYS[k]);
        if (!known)
            warnmsg("%s: chave desconhecida ignorada: %s", P.prefs_conf, l->v[i].key);
    }
    kv_free(l);
}

/* Linha "  CHAVE=..." (atribuicao, nao comentario) */
static bool line_is_key(const char *l, size_t n, const char *key)
{
    while (n && (*l == ' ' || *l == '\t'))
        l++, n--;
    size_t kl = strlen(key);
    return n > kl && !memcmp(l, key, kl) && l[kl] == '=';
}

/* Grava as preferencias trocando so o valor das linhas de cada chave:
 * comentarios, ordem e chaves desconhecidas do usuario sao mantidos.
 * Chave ausente vai para o fim. Sem arquivo, parte do modelo comentado
 * do payload (config/preferences.conf do pacote). */
struct sbuf {
    char *p;
    size_t n, cap;
};

static int sbuf_add(struct sbuf *b, const char *s, size_t n)
{
    if (b->n + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 1024;
        while (cap < b->n + n + 1)
            cap *= 2;
        char *q = realloc(b->p, cap);
        if (!q)
            return -1;
        b->p = q;
        b->cap = cap;
    }
    memcpy(b->p + b->n, s, n);
    b->n += n;
    b->p[b->n] = '\0';
    return 0;
}

static int sbuf_kv(struct sbuf *b, const char *key, const char *val)
{
    return sbuf_add(b, key, strlen(key)) || sbuf_add(b, "=\"", 2) || sbuf_add(b, val, strlen(val)) ||
           sbuf_add(b, "\"\n", 2);
}

int prefs_save(const struct prefs *c)
{
    const char *vals[NPREF_KEYS] = {c->mode, c->bundle, c->background, c->logo, c->menu_box, c->tone, c->on_fresh};
    bool done[NPREF_KEYS] = {false};
    char tpl[PATH_MAX];
    size_t len = 0;
    for (size_t k = 0; k < NPREF_KEYS; k++)
        if (!conf_value_safe(vals[k])) {
            errmsg("valor invalido para %s", PREF_KEYS[k]);
            return KAM_EUSAGE;
        }
    char *old = read_file(P.prefs_conf, 1024 * 1024, &len);
    if (!old) {
        pathf(tpl, sizeof tpl, "%s/preferences.conf", P.payload_dir);
        old = read_file(tpl, 1024 * 1024, &len);
        if (!old)
            len = 0;
    }
    struct sbuf out = {0};
    int bad = 0;
    for (size_t i = 0; i < len && !bad;) {
        const char *l = old + i, *nl = memchr(l, '\n', len - i);
        size_t ln = nl ? (size_t)(nl - l) : len - i;
        size_t k = 0;
        while (k < NPREF_KEYS && !line_is_key(l, ln, PREF_KEYS[k]))
            k++;
        if (k < NPREF_KEYS) {
            bad = sbuf_kv(&out, PREF_KEYS[k], vals[k]);
            done[k] = true;
        } else {
            bad = sbuf_add(&out, l, ln) || sbuf_add(&out, "\n", 1);
        }
        i += nl ? ln + 1 : ln;
    }
    free(old);
    for (size_t k = 0; k < NPREF_KEYS && !bad; k++)
        if (!done[k])
            bad = sbuf_kv(&out, PREF_KEYS[k], vals[k]);
    int rc = KAM_OK;
    if (bad) {
        errmsg("sem memoria");
        rc = KAM_EFAIL;
    } else if (mkdir_p(P.config_dir, 0755) < 0 || write_file_atomic(P.prefs_conf, out.p, out.n, 0644) < 0) {
        errmsg("falha ao gravar %s: %s", P.prefs_conf, strerror(errno));
        rc = errno == EACCES || errno == EPERM || errno == EROFS ? KAM_EPRIV : KAM_EFAIL;
    }
    free(out.p);
    return rc;
}
