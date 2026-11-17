/* kawaii-arch-manager - elementos opcionais do tema (logo e contorno do menu)
 *
 * O theme.txt marca os elementos opcionais com blocos:
 *     # >>> NOME
 *     ...linhas...
 *     # <<< NOME
 * Um bloco desativado tem todas as linhas com o prefixo "#[TAG] " (o GRUB
 * as le como comentario). O estado fica no proprio theme.txt; o install.sh
 * usa os mesmos blocos.
 *   logo         TAG logo: o "+ image" do logo da distribuicao
 *   menu-box     TAG menu: limites do menu +16 px por lado e o contorno
 *   no-menu-box  TAG menu: limites originais, sem contorno (ativo quando o
 *                contorno esta desligado; as entradas nao mudam de lugar) */
#include "kam.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define THEME_MAX (1024 * 1024)

struct buf {
    char *p;
    size_t n, cap;
};

static int buf_add(struct buf *b, const char *s, size_t n)
{
    if (b->n + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap * 2 : 4096;
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

/* Linha (sem o '\n') e "# >>> NAME" ou "# <<< NAME", com indentacao */
static bool is_marker(const char *l, size_t n, const char *dir, const char *name)
{
    while (n && (*l == ' ' || *l == '\t'))
        l++, n--;
    while (n && (l[n - 1] == ' ' || l[n - 1] == '\t' || l[n - 1] == '\r'))
        n--;
    char want[128];
    int w = snprintf(want, sizeof want, "# %s %s", dir, name);
    return w > 0 && (size_t)w == n && !memcmp(l, want, n);
}

/* Linha ativa: nao vazia e nao comentada */
static bool is_active_line(const char *l, size_t n)
{
    while (n && (*l == ' ' || *l == '\t' || *l == '\r'))
        l++, n--;
    return n && *l != '#';
}

struct blockop {
    const char *name;
    const char *tag;
    int set;          /* -1 so consulta; 0 desativa; 1 ativa */
    bool found_begin, found_end, active;
};

/* Percorre o texto aplicando as operacoes; out pode ser NULL (consulta) */
static int process(const char *text, size_t len, struct blockop *ops, size_t nops, struct buf *out)
{
    size_t i = 0;
    struct blockop *cur = NULL;
    while (i < len) {
        const char *l = text + i;
        const char *nl = memchr(l, '\n', len - i);
        size_t n = nl ? (size_t)(nl - l) : len - i;
        size_t adv = nl ? n + 1 : n;
        const char *emit = l;
        size_t emitn = adv;
        char tmp[8192];
        if (!cur) {
            for (size_t k = 0; k < nops; k++)
                if (is_marker(l, n, ">>>", ops[k].name)) {
                    cur = &ops[k];
                    cur->found_begin = true;
                    break;
                }
        } else if (is_marker(l, n, "<<<", cur->name)) {
            cur->found_end = true;
            cur = NULL;
        } else {
            char pre[80];
            int pl = snprintf(pre, sizeof pre, "#[%s] ", cur->tag);
            bool tagged = n >= (size_t)pl && !memcmp(l, pre, (size_t)pl);
            if (cur->set == 1 && tagged) {
                emit = l + pl;
                emitn = adv - (size_t)pl;
            } else if (cur->set == 0 && !tagged) {
                if (adv + (size_t)pl > sizeof tmp)
                    return -1;
                memcpy(tmp, pre, (size_t)pl);
                memcpy(tmp + pl, l, adv);
                emit = tmp;
                emitn = adv + (size_t)pl;
            }
            const char *el = emit;
            size_t en = emitn && emit[emitn - 1] == '\n' ? emitn - 1 : emitn;
            if (is_active_line(el, en))
                cur->active = true;
        }
        if (out && buf_add(out, emit, emitn) < 0)
            return -1;
        i += adv;
    }
    return cur ? -1 : 0;   /* bloco sem fim */
}

static char *load_theme(char *path, size_t pathsz, size_t *len)
{
    pathf(path, pathsz, "%s/theme.txt", P.theme_dir);
    return read_file(path, THEME_MAX, len);
}

/* Estado de um elemento: 1 ligado, 0 desligado, -1 sem suporte no tema */
static int element_state(const char *text, size_t len, bool menu)
{
    struct blockop ops[2] = {
        {menu ? "menu-box" : "logo", menu ? "menu" : "logo", -1, false, false, false},
        {"no-menu-box", "menu", -1, false, false, false},
    };
    size_t nops = menu ? 2 : 1;
    if (process(text, len, ops, nops, NULL) < 0)
        return -1;
    for (size_t k = 0; k < nops; k++)
        if (!ops[k].found_begin || !ops[k].found_end)
            return -1;
    return ops[0].active ? 1 : 0;
}

int theme_element_state(const char *which)
{
    char path[PATH_MAX];
    size_t len;
    if (!P.theme_dir[0])
        return -1;
    char *t = load_theme(path, sizeof path, &len);
    if (!t)
        return -1;
    int st = element_state(t, len, !strcmp(which, "menu-box"));
    free(t);
    return st;
}

static int set_element(bool menu, const char *arg)
{
    const char *opt = menu ? "--menu-box" : "--logo";
    const char *what = menu ? "contorno do menu" : "logo";
    int rc;
    if (!arg || (strcmp(arg, "on") && strcmp(arg, "off"))) {
        errmsg("%s: use on ou off", opt);
        return KAM_EUSAGE;
    }
    bool on = !strcmp(arg, "on");
    if (!O.dry_run && (rc = require_root(opt)))
        return rc;

    char err[512], path[PATH_MAX];
    if ((rc = theme_mount_check(err, sizeof err)) != KAM_OK) {
        errmsg("%s", err);
        return rc;
    }
    int lk = -1;
    if (!O.dry_run) {
        if (mkdir_p(P.state_dir, 0755) < 0 || (lk = lock_file(P.apply_lock, 30)) < 0) {
            errmsg("outra aplicacao no tema esta em andamento (ou %s inacessivel)", P.state_dir);
            return KAM_ECONFLICT;
        }
    }
    size_t len;
    struct buf out = {0};
    char *t = load_theme(path, sizeof path, &len);
    if (!t) {
        errmsg("nao foi possivel ler %s: %s", path, strerror(errno));
        rc = KAM_EFAIL;
        goto done;
    }
    int st = element_state(t, len, menu);
    if (st < 0) {
        errmsg("o tema instalado nao tem os marcadores do %s em %s; atualize o tema (install.sh)", what, path);
        rc = KAM_EBUNDLE;
        goto done;
    }
    if (st == (int)on) {
        msg("O %s ja esta %s; nada a fazer", what, on ? "ligado" : "desligado");
        rc = KAM_OK;
        goto done;
    }
    if (O.dry_run) {
        msg("O %s seria %s (nada foi alterado)", what, on ? "ligado" : "desligado");
        rc = KAM_OK;
        goto done;
    }
    struct blockop ops[2] = {
        {menu ? "menu-box" : "logo", menu ? "menu" : "logo", on, false, false, false},
        {"no-menu-box", "menu", !on, false, false, false},
    };
    if (process(t, len, ops, menu ? 2 : 1, &out) < 0 || !out.p ||
        !strstr(out.p, "\ndesktop-image: \"background.png\"") || element_state(out.p, out.n, menu) != (int)on) {
        errmsg("falha ao gerar o novo theme.txt; nada foi alterado");
        rc = KAM_EFAIL;
        goto done;
    }
    if (write_file_atomic(path, out.p, out.n, 0644) < 0) {
        errmsg("nao foi possivel gravar %s: %s", path, strerror(errno));
        rc = errno == EACCES || errno == EROFS ? KAM_EPRIV : KAM_EFAIL;
        goto done;
    }
    msg("%s %s (vale a partir do proximo boot)", menu ? "Contorno do menu" : "Logo", on ? "ligado" : "desligado");
    rc = KAM_OK;
done:
    free(t);
    free(out.p);
    if (lk >= 0)
        close(lk);
    return rc;
}

int cmd_set_logo(const char *arg) { return set_element(false, arg); }
int cmd_set_menu_box(const char *arg) { return set_element(true, arg); }
