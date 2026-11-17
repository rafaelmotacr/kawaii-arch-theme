/* kawaii-arch-manager - importacao de bundles (.kawall ou pasta extraida)
 *
 * Um .kawall e um arquivo tar (sem compressao ou com gzip/xz/zstd/bzip2)
 * com a estrutura:
 *
 *   <id>/manifest.conf
 *   <id>/backgrounds/<imagem>.png
 *
 * O conteudo e tratado como nao confiavel:
 *  - passagem 1 (sem escrever nada): valida caminhos, tipos, limites,
 *    metadados e cabecalhos PNG;
 *  - passagem 2: extrai somente as entradas reconhecidas, criando cada
 *    arquivo com openat(O_CREAT|O_EXCL|O_NOFOLLOW) a partir de nomes de
 *    um unico componente ja validados, num diretorio temporario dentro de
 *    bundles/ (mesmo filesystem); nada e executado e nenhum caminho do
 *    pacote e usado diretamente;
 *  - o resultado e validado novamente e instalado com renameat2
 *    (RENAME_EXCHANGE / RENAME_NOREPLACE), preservando a versao anterior
 *    ate a conclusao.
 *
 * Uma pasta ja extraida (manifest.conf + backgrounds/) tambem e aceita:
 * mesmas validacoes, com copia arquivo a arquivo (ver scan_dir). */
#include "kam.h"

#include <archive.h>
#include <archive_entry.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>


enum kind { K_TOP, K_MANIFEST, K_BGDIR, K_IMAGE, K_SKIP };

struct scan {
    char top[256];
    long entries, images, invalid_images, skipped;
    long long total;
    char *manifest;
    size_t manifest_len;
    char **names;
    size_t nnames, cap;
    char skipped_example[256];
    char invalid_example[300];
    long long image_bytes;
};

static void scan_free(struct scan *s)
{
    free(s->manifest);
    for (size_t i = 0; i < s->nnames; i++)
        free(s->names[i]);
    free(s->names);
    memset(s, 0, sizeof *s);
}

static struct archive *open_archive(const char *path, char *err, size_t errsz)
{
    struct archive *a = archive_read_new();
    if (!a) {
        snprintf(err, errsz, "sem memoria");
        return NULL;
    }
    archive_read_support_filter_all(a);
    archive_read_support_format_tar(a);
    if (archive_read_open_filename(a, path, 1 << 16) != ARCHIVE_OK) {
        snprintf(err, errsz, "nao foi possivel abrir o pacote: %s", archive_error_string(a));
        archive_read_free(a);
        return NULL;
    }
    return a;
}

/* Normaliza e classifica uma entrada. img recebe o nome da imagem. */
static int classify(struct archive_entry *e, struct scan *s, enum kind *k, char *img,
                    char *err, size_t errsz)
{
    const char *raw = archive_entry_pathname(e);
    if (!raw || !*raw) {
        snprintf(err, errsz, "entrada sem nome ou com codificacao invalida");
        return -1;
    }
    if (strlen(raw) >= 1024) {
        snprintf(err, errsz, "caminho muito longo no pacote");
        return -1;
    }
    char path[1024];
    snprintf(path, sizeof path, "%s", raw);
    if (path[0] == '/') {
        snprintf(err, errsz, "caminho absoluto no pacote: %.200s", raw);
        return -1;
    }
    if (strchr(path, '\\')) {
        snprintf(err, errsz, "caminho com barra invertida no pacote: %.200s", raw);
        return -1;
    }
    char *p = path;
    while (p[0] == '.' && p[1] == '/')
        p += 2;
    size_t pl = strlen(p);
    while (pl && p[pl - 1] == '/')
        p[--pl] = '\0';

    mode_t ft = archive_entry_filetype(e);
    if (archive_entry_hardlink(e)) {
        snprintf(err, errsz, "hard link nao permitido: %.200s", raw);
        return -1;
    }
    if (ft == AE_IFLNK || archive_entry_symlink(e)) {
        snprintf(err, errsz, "link simbolico nao permitido: %.200s", raw);
        return -1;
    }
    if (ft != AE_IFREG && ft != AE_IFDIR) {
        snprintf(err, errsz, "arquivo especial (dispositivo/fifo/socket) nao permitido: %.200s", raw);
        return -1;
    }
    if (!pl || !strcmp(p, ".")) { /* "./" */
        *k = K_SKIP;
        return ft == AE_IFDIR ? 1 : -1;
    }

    char *comp[8];
    int depth = 0;
    for (char *tok = p, *next; tok; tok = next) {
        next = strchr(tok, '/');
        if (next)
            *next++ = '\0';
        if (!*tok || !strcmp(tok, ".") || !strcmp(tok, "..")) {
            snprintf(err, errsz, "componente de caminho invalido ('%s') em: %.200s", tok, raw);
            return -1;
        }
        if (strlen(tok) > 255) {
            snprintf(err, errsz, "nome muito longo em: %.200s", raw);
            return -1;
        }
        if (depth < 8)
            comp[depth] = tok;
        depth++;
    }
    if (!s->top[0])
        snprintf(s->top, sizeof s->top, "%s", comp[0]);
    else if (strcmp(s->top, comp[0])) {
        snprintf(err, errsz, "o pacote deve conter um unico diretorio raiz (encontrados '%s' e '%s')",
                 s->top, comp[0]);
        return -1;
    }
    bool reg = ft == AE_IFREG, dir = ft == AE_IFDIR;
    if (depth == 1) {
        if (!dir) {
            snprintf(err, errsz, "arquivo fora do diretorio do bundle: %.200s (esperado <id>/...)", raw);
            return -1;
        }
        *k = K_TOP;
    } else if (depth == 2 && !strcmp(comp[1], "manifest.conf") && reg) {
        *k = K_MANIFEST;
    } else if (depth == 2 && !strcmp(comp[1], "backgrounds")) {
        if (!dir) {
            snprintf(err, errsz, "'backgrounds' deve ser um diretorio");
            return -1;
        }
        *k = K_BGDIR;
    } else if (depth == 3 && !strcmp(comp[1], "backgrounds") && reg && image_name_valid(comp[2])) {
        *k = K_IMAGE;
        snprintf(img, IMG_NAME_MAX + 1, "%s", comp[2]);
    } else {
        *k = K_SKIP;
    }
    return 0;
}

static int check_limits(struct archive_entry *e, struct scan *s, char *err, size_t errsz)
{
    if (++s->entries > LIMIT_ENTRIES) {
        snprintf(err, errsz, "pacote com entradas demais (limite: %ld)", LIMIT_ENTRIES);
        return -1;
    }
    if (archive_entry_filetype(e) != AE_IFREG)
        return 0;
    if (!archive_entry_size_is_set(e)) {
        snprintf(err, errsz, "entrada sem tamanho declarado");
        return -1;
    }
    long long sz = archive_entry_size(e);
    if (sz < 0 || sz > LIMIT_FILE_BYTES) {
        snprintf(err, errsz, "arquivo grande demais no pacote (%s; limite por arquivo: %lld MiB)",
                 archive_entry_pathname(e), LIMIT_FILE_BYTES >> 20);
        return -1;
    }
    s->total += sz;
    if (s->total > LIMIT_TOTAL_BYTES) {
        snprintf(err, errsz, "tamanho descompactado excede o limite de %lld GiB", LIMIT_TOTAL_BYTES >> 30);
        return -1;
    }
    return 0;
}

/* Le exatamente ate n bytes do conteudo da entrada atual */
static ssize_t read_n(struct archive *a, void *buf, size_t n)
{
    size_t got = 0;
    while (got < n) {
        la_ssize_t r = archive_read_data(a, (char *)buf + got, n - got);
        if (r < 0)
            return -1;
        if (r == 0)
            break;
        got += (size_t)r;
    }
    return (ssize_t)got;
}

static int read_meta(struct archive *a, struct archive_entry *e, char **out, size_t *len,
                     const char *what, char *err, size_t errsz)
{
    if (*out) {
        snprintf(err, errsz, "%s duplicado no pacote", what);
        return -1;
    }
    long long sz = archive_entry_size(e);
    if (sz > LIMIT_META_BYTES) {
        snprintf(err, errsz, "%s grande demais", what);
        return -1;
    }
    *out = malloc((size_t)sz + 1);
    if (!*out) {
        snprintf(err, errsz, "sem memoria");
        return -1;
    }
    ssize_t r = read_n(a, *out, (size_t)sz);
    if (r != sz) {
        snprintf(err, errsz, "falha ao ler %s: %s", what, archive_error_string(a));
        return -1;
    }
    (*out)[sz] = '\0';
    *len = (size_t)sz;
    return 0;
}

static int name_cmp(const void *a, const void *b)
{
    return strcmp(*(char *const *)a, *(char *const *)b);
}

static void scan_skip(struct scan *s, const char *shown)
{
    s->skipped++;
    if (!s->skipped_example[0])
        snprintf(s->skipped_example, sizeof s->skipped_example, "%.255s", shown);
}

/* Imagem com cabecalho head: registra como utilizavel ou ignorada */
static int scan_image(struct scan *s, const char *name, const unsigned char *head, ssize_t got,
                      long long size, char *err, size_t errsz)
{
    char pe[128];
    if (png_check_buf(head, (size_t)got, NULL, pe, sizeof pe) < 0) {
        s->invalid_images++;
        if (!s->invalid_example[0])
            snprintf(s->invalid_example, sizeof s->invalid_example, "%.255s: %s", name, pe);
        return 0;
    }
    if (s->nnames == s->cap) {
        size_t cap = s->cap ? s->cap * 2 : 64;
        char **nn = realloc(s->names, cap * sizeof *nn);
        if (!nn) {
            snprintf(err, errsz, "sem memoria");
            return -1;
        }
        s->names = nn;
        s->cap = cap;
    }
    if (!(s->names[s->nnames] = strdup(name))) {
        snprintf(err, errsz, "sem memoria");
        return -1;
    }
    s->nnames++;
    s->image_bytes += size;
    return 0;
}

static int scan_finish(struct scan *s, struct kawall_info *ki, bool check_top, char *err, size_t errsz);

/* Passagem 1: valida tudo sem escrever no disco */
static int scan_archive(const char *path, struct scan *s, struct kawall_info *ki, char *err, size_t errsz)
{
    memset(s, 0, sizeof *s);
    memset(ki, 0, sizeof *ki);
    struct archive *a = open_archive(path, err, errsz);
    if (!a)
        return -1;
    struct archive_entry *e;
    int r, rc = -1;
    char img[IMG_NAME_MAX + 1];
    while ((r = archive_read_next_header(a, &e)) == ARCHIVE_OK || r == ARCHIVE_WARN) {
        enum kind k;
        if (check_limits(e, s, err, errsz) < 0)
            goto out;
        int c = classify(e, s, &k, img, err, errsz);
        if (c < 0)
            goto out;
        if (k == K_MANIFEST) {
            if (read_meta(a, e, &s->manifest, &s->manifest_len, "manifest.conf", err, errsz) < 0)
                goto out;
        } else if (k == K_IMAGE) {
            if (++s->images > LIMIT_IMAGES) {
                snprintf(err, errsz, "imagens demais no pacote (limite: %ld)", LIMIT_IMAGES);
                goto out;
            }
            unsigned char head[29];
            ssize_t got = read_n(a, head, sizeof head);
            if (got < 0) {
                snprintf(err, errsz, "falha ao ler %s: %s", img, archive_error_string(a));
                goto out;
            }
            if (scan_image(s, img, head, got, archive_entry_size(e), err, errsz) < 0)
                goto out;
        } else if (k == K_SKIP && c == 0) {
            scan_skip(s, archive_entry_pathname(e));
        }
    }
    if (r != ARCHIVE_EOF) {
        snprintf(err, errsz, "pacote corrompido ou formato nao suportado: %s", archive_error_string(a));
        goto out;
    }
    if (s->entries == 0) {
        snprintf(err, errsz, "pacote vazio");
        goto out;
    }
    if (!s->manifest) {
        snprintf(err, errsz, "estrutura invalida: %s/manifest.conf ausente", s->top[0] ? s->top : "<id>");
        goto out;
    }
    rc = scan_finish(s, ki, true, err, errsz);
out:
    archive_read_free(a);
    return rc;
}

/* Validacao comum (pacote e pasta), depois de lidos manifesto e imagens.
 * check_top: o diretorio raiz do pacote deve ser igual ao ID. */
static int scan_finish(struct scan *s, struct kawall_info *ki, bool check_top, char *err, size_t errsz)
{
    struct bundle *b = &ki->meta;
    if (parse_manifest(s->manifest, s->manifest_len, b, err, errsz) < 0)
        return -1;
    if (check_top && strcmp(s->top, b->id)) {
        snprintf(err, errsz, "diretorio raiz do pacote ('%s') difere do ID do manifesto ('%s')", s->top, b->id);
        return -1;
    }
    if (s->nnames == 0) {
        snprintf(err, errsz, "nenhuma imagem utilizavel em %s/backgrounds/ (PNG compativel com o GRUB)", b->id);
        if (s->invalid_example[0]) {
            size_t l = strlen(err);
            snprintf(err + l, errsz - l, "; ex.: %s", s->invalid_example);
        }
        return -1;
    }
    qsort(s->names, s->nnames, sizeof *s->names, name_cmp);
    for (size_t i = 1; i < s->nnames; i++)
        if (!strcmp(s->names[i], s->names[i - 1])) {
            snprintf(err, errsz, "imagem duplicada no pacote: %s", s->names[i]);
            return -1;
        }
    b->nimg = b->nvalid = s->nnames;
    b->total = s->image_bytes;
    b->valid = true;
    ki->skipped = s->skipped;
    snprintf(ki->skipped_example, sizeof ki->skipped_example, "%s", s->skipped_example);
    return 0;
}

int kawall_inspect(const char *path, struct kawall_info *ki, char *err, size_t errsz)
{
    struct scan s;
    int r = scan_archive(path, &s, ki, err, errsz);
    scan_free(&s);
    return r;
}

/* Grava o conteudo da entrada atual em dirfd/name (nome ja validado);
 * head: bytes ja lidos do inicio da entrada */
static int extract_to(struct archive *a, struct archive_entry *e, int dirfd, const char *name,
                      const void *head, size_t headlen, char *err, size_t errsz)
{
    long long declared = archive_entry_size(e), written = (long long)headlen;
    int fd = openat(dirfd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) {
        snprintf(err, errsz, "falha ao criar %s: %s", name, strerror(errno));
        return -1;
    }
    char buf[1 << 16];
    la_ssize_t r = 0;
    int rc = -1;
    if (write_all(fd, head, headlen) < 0)
        goto werr;
    while ((r = archive_read_data(a, buf, sizeof buf)) > 0) {
        if ((written += r) > declared) {
            snprintf(err, errsz, "%s excede o tamanho declarado", name);
            goto out;
        }
        if (write_all(fd, buf, (size_t)r) < 0)
            goto werr;
    }
    if (r < 0)
        snprintf(err, errsz, "falha ao ler %s do pacote: %s", name, archive_error_string(a));
    else if (written != declared)
        snprintf(err, errsz, "%s: tamanho divergente", name);
    else
        rc = 0;
    goto out;
werr:
    snprintf(err, errsz, "falha ao gravar %s: %s", name, strerror(errno));
out:
    close(fd);
    return rc;
}

/* Passagem 2: extracao controlada para tmpdir */
static int extract_archive(const char *path, const char *tmpdir, long *n_out, char *err, size_t errsz)
{
    struct scan s;
    memset(&s, 0, sizeof s);
    struct archive *a = open_archive(path, err, errsz);
    if (!a)
        return -1;
    int tfd = -1, bfd = -1, rc = -1;
    long n = 0;
    if ((tfd = open(tmpdir, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)) < 0 ||
        mkdirat(tfd, "backgrounds", 0755) < 0 ||
        (bfd = openat(tfd, "backgrounds", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)) < 0) {
        snprintf(err, errsz, "falha ao preparar %s: %s", tmpdir, strerror(errno));
        goto out;
    }
    struct archive_entry *e;
    int r;
    char img[IMG_NAME_MAX + 1];
    bool got_manifest = false;
    while ((r = archive_read_next_header(a, &e)) == ARCHIVE_OK || r == ARCHIVE_WARN) {
        enum kind k;
        if (check_limits(e, &s, err, errsz) < 0 || classify(e, &s, &k, img, err, errsz) < 0)
            goto out;
        if (k == K_MANIFEST) {
            if (got_manifest) {
                snprintf(err, errsz, "metadados duplicados no pacote");
                goto out;
            }
            got_manifest = true;
            if (extract_to(a, e, tfd, "manifest.conf", NULL, 0, err, errsz) < 0)
                goto out;
        } else if (k == K_IMAGE) {
            unsigned char head[29];
            char pe[128];
            ssize_t got = read_n(a, head, sizeof head);
            if (got < 0) {
                snprintf(err, errsz, "falha ao ler %s: %s", img, archive_error_string(a));
                goto out;
            }
            if (png_check_buf(head, (size_t)got, NULL, pe, sizeof pe) < 0)
                continue; /* ignorada (mesma decisao da passagem 1) */
            if (extract_to(a, e, bfd, img, head, (size_t)got, err, errsz) < 0)
                goto out;
            n++;
        }
    }
    if (r != ARCHIVE_EOF) {
        snprintf(err, errsz, "erro ao ler o pacote: %s", archive_error_string(a));
        goto out;
    }
    if (syncfs(tfd) < 0)
        warnmsg("syncfs falhou: %s", strerror(errno));
    *n_out = n;
    rc = 0;
out:
    if (bfd >= 0)
        close(bfd);
    if (tfd >= 0)
        close(tfd);
    archive_read_free(a);
    scan_free(&s);
    return rc;
}

/* ---------------------------------------------------------------------
 * Origem alternativa: pasta de bundle ja extraida
 *
 * Aceita DIR com manifest.conf + backgrounds/, ou DIR contendo um unico
 * subdiretorio nesse formato (o resultado de "tar -xf <id>.kawall"). O
 * conteudo continua nao confiavel e segue as mesmas regras do pacote:
 * links simbolicos e arquivos especiais sao recusados, mesmos limites de
 * tamanho e quantidade, somente manifest.conf e backgrounds/<imagem>.png
 * sao lidos (o resto e ignorado sem ser aberto), e cada arquivo e copiado
 * (nunca movido ou ligado) para o temporario em bundles/.
 * --------------------------------------------------------------------- */

/* Tipo de DIR/name sem seguir links; recusa link e arquivo especial */
static int stat_child(int dfd, const char *name, const char *shown, struct stat *st, char *err, size_t errsz)
{
    if (fstatat(dfd, name, st, AT_SYMLINK_NOFOLLOW) < 0) {
        snprintf(err, errsz, "%s: %s", shown, strerror(errno));
        return -1;
    }
    if (S_ISLNK(st->st_mode)) {
        snprintf(err, errsz, "link simbolico nao permitido: %s", shown);
        return -1;
    }
    if (!S_ISREG(st->st_mode) && !S_ISDIR(st->st_mode)) {
        snprintf(err, errsz, "arquivo especial (dispositivo/fifo/socket) nao permitido: %s", shown);
        return -1;
    }
    return 0;
}

/* Abre um arquivo regular (sem seguir links), conferindo o tipo apos abrir */
static int open_reg(int dfd, const char *name, const char *shown, long long *size, char *err, size_t errsz)
{
    int fd = openat(dfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    struct stat st;
    if (fd < 0) {
        snprintf(err, errsz, "%s: %s", shown, strerror(errno));
        return -1;
    }
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) {
        snprintf(err, errsz, "%s nao e um arquivo regular", shown);
        close(fd);
        return -1;
    }
    if (st.st_size > LIMIT_FILE_BYTES) {
        snprintf(err, errsz, "arquivo grande demais (%s; limite por arquivo: %lld MiB)", shown,
                 LIMIT_FILE_BYTES >> 20);
        close(fd);
        return -1;
    }
    *size = st.st_size;
    return fd;
}


static bool has_manifest(const char *dir)
{
    char p[PATH_MAX];
    struct stat st;
    return pathf(p, sizeof p, "%s/manifest.conf", dir) == 0 && lstat(p, &st) == 0;
}

/* DIR ou DIR/<unico subdiretorio> com manifest.conf -> out */
static int resolve_bundle_dir(const char *path, char *out, size_t outsz, char *err, size_t errsz)
{
    if (has_manifest(path))
        return pathf(out, outsz, "%s", path) == 0 ? 0 : -1;
    DIR *d = opendir(path);
    if (!d) {
        snprintf(err, errsz, "%s: %s", path, strerror(errno));
        return -1;
    }
    struct dirent *de;
    int found = 0;
    char cand[PATH_MAX];
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.')
            continue;
        if (pathf(cand, sizeof cand, "%s/%s", path, de->d_name) < 0 || !is_dir(cand) || !has_manifest(cand))
            continue;
        if (found++ == 0)
            snprintf(out, outsz, "%s", cand);
    }
    closedir(d);
    if (found == 1)
        return 0;
    if (found > 1)
        snprintf(err, errsz, "%s contem mais de um bundle; informe a pasta de um deles", path);
    else
        snprintf(err, errsz, "nenhum bundle em %s (esperado manifest.conf e backgrounds/ na pasta "
                             "ou num unico subdiretorio)", path);
    return -1;
}

/* Passagem 1 para pasta: valida tudo sem escrever no disco */
static int scan_dir(const char *dir, struct scan *s, struct kawall_info *ki, char *err, size_t errsz)
{
    memset(s, 0, sizeof *s);
    memset(ki, 0, sizeof *ki);
    int dfd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC), fd = -1, rc = -1;
    DIR *top = NULL, *bd = NULL;
    struct stat st;
    long long sz;
    if (dfd < 0) {
        snprintf(err, errsz, "%s: %s", dir, strerror(errno));
        return -1;
    }

    /* manifest.conf */
    if (fstatat(dfd, "manifest.conf", &st, AT_SYMLINK_NOFOLLOW) < 0 && errno == ENOENT) {
        snprintf(err, errsz, "estrutura invalida: manifest.conf ausente");
        goto out;
    }
    if (stat_child(dfd, "manifest.conf", "manifest.conf", &st, err, errsz) < 0)
        goto out;
    if (!S_ISREG(st.st_mode)) {
        snprintf(err, errsz, "'manifest.conf' deve ser um arquivo");
        goto out;
    }
    if ((fd = open_reg(dfd, "manifest.conf", "manifest.conf", &sz, err, errsz)) < 0)
        goto out;
    if (sz > LIMIT_META_BYTES) {
        snprintf(err, errsz, "manifest.conf grande demais");
        goto out;
    }
    if (!(s->manifest = malloc((size_t)sz + 1))) {
        snprintf(err, errsz, "sem memoria");
        goto out;
    }
    if (read_full(fd, s->manifest, (size_t)sz) != sz) {
        snprintf(err, errsz, "falha ao ler manifest.conf");
        goto out;
    }
    s->manifest[sz] = '\0';
    s->manifest_len = (size_t)sz;
    close(fd);
    fd = -1;

    /* backgrounds/ */
    if (fstatat(dfd, "backgrounds", &st, AT_SYMLINK_NOFOLLOW) < 0 && errno == ENOENT) {
        snprintf(err, errsz, "estrutura invalida: backgrounds/ ausente");
        goto out;
    }
    if (stat_child(dfd, "backgrounds", "backgrounds", &st, err, errsz) < 0)
        goto out;
    if (!S_ISDIR(st.st_mode)) {
        snprintf(err, errsz, "'backgrounds' deve ser um diretorio");
        goto out;
    }
    int bfd = openat(dfd, "backgrounds", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (bfd < 0 || !(bd = fdopendir(bfd))) {
        snprintf(err, errsz, "backgrounds/: %s", strerror(errno));
        if (bfd >= 0)
            close(bfd);
        goto out;
    }
    struct dirent *de;
    char shown[300];
    while ((de = readdir(bd))) {
        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
            continue;
        if (++s->entries > LIMIT_ENTRIES) {
            snprintf(err, errsz, "pasta com entradas demais (limite: %ld)", LIMIT_ENTRIES);
            goto out;
        }
        snprintf(shown, sizeof shown, "backgrounds/%.255s", de->d_name);
        if (stat_child(dirfd(bd), de->d_name, shown, &st, err, errsz) < 0)
            goto out;
        if (S_ISDIR(st.st_mode) || !image_name_valid(de->d_name)) {
            scan_skip(s, shown);
            continue;
        }
        if (++s->images > LIMIT_IMAGES) {
            snprintf(err, errsz, "imagens demais na pasta (limite: %ld)", LIMIT_IMAGES);
            goto out;
        }
        if ((fd = open_reg(dirfd(bd), de->d_name, shown, &sz, err, errsz)) < 0)
            goto out;
        s->total += sz;
        if (s->total > LIMIT_TOTAL_BYTES) {
            snprintf(err, errsz, "tamanho total excede o limite de %lld GiB", LIMIT_TOTAL_BYTES >> 30);
            goto out;
        }
        unsigned char head[29];
        ssize_t got = read_full(fd, head, sizeof head);
        close(fd);
        fd = -1;
        if (got < 0) {
            snprintf(err, errsz, "falha ao ler %s", shown);
            goto out;
        }
        if (scan_image(s, de->d_name, head, got, sz, err, errsz) < 0)
            goto out;
    }

    /* Demais entradas da pasta: ignoradas (nunca abertas) */
    int tfd = dup(dfd);
    if (tfd >= 0 && (top = fdopendir(tfd))) {
        while ((de = readdir(top)))
            if (strcmp(de->d_name, ".") && strcmp(de->d_name, "..") && strcmp(de->d_name, "manifest.conf") &&
                strcmp(de->d_name, "backgrounds"))
                scan_skip(s, de->d_name);
    } else if (tfd >= 0) {
        close(tfd);
    }
    rc = scan_finish(s, ki, false, err, errsz);
out:
    if (fd >= 0)
        close(fd);
    if (bd)
        closedir(bd);
    if (top)
        closedir(top);
    close(dfd);
    return rc;
}

/* Copia srcfd para dstdir/name (O_EXCL, 0644); head ja lido do inicio */
static int copy_to(int srcfd, const void *head, size_t headlen, int dstdir, const char *name, char *err,
                   size_t errsz)
{
    int out = openat(dstdir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (out < 0) {
        snprintf(err, errsz, "falha ao criar %s: %s", name, strerror(errno));
        return -1;
    }
    char buf[1 << 16];
    long long total = (long long)headlen;
    ssize_t r;
    if (write_all(out, head, headlen) < 0)
        goto werr;
    while ((r = read_full(srcfd, buf, sizeof buf)) > 0) {
        if ((total += r) > LIMIT_FILE_BYTES) {
            snprintf(err, errsz, "%s cresceu alem do limite durante a copia", name);
            close(out);
            return -1;
        }
        if (write_all(out, buf, (size_t)r) < 0)
            goto werr;
    }
    if (r < 0) {
        snprintf(err, errsz, "falha ao ler %s: %s", name, strerror(errno));
        close(out);
        return -1;
    }
    if (close(out) == 0)
        return 0;
    out = -1;
werr:
    snprintf(err, errsz, "falha ao gravar %s: %s", name, strerror(errno));
    if (out >= 0)
        close(out);
    return -1;
}

/* Passagem 2 para pasta: copia manifesto e imagens validas para tmpdir */
static int extract_dir(const char *dir, const char *tmpdir, long *n_out, char *err, size_t errsz)
{
    int dfd = -1, sbfd = -1, tfd = -1, bfd = -1, fd = -1, rc = -1;
    DIR *bd = NULL;
    long n = 0;
    long long sz;
    if ((dfd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC)) < 0) {
        snprintf(err, errsz, "%s: %s", dir, strerror(errno));
        goto out;
    }
    if ((tfd = open(tmpdir, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)) < 0 ||
        mkdirat(tfd, "backgrounds", 0755) < 0 ||
        (bfd = openat(tfd, "backgrounds", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)) < 0) {
        snprintf(err, errsz, "falha ao preparar %s: %s", tmpdir, strerror(errno));
        goto out;
    }
    if ((fd = open_reg(dfd, "manifest.conf", "manifest.conf", &sz, err, errsz)) < 0 ||
        copy_to(fd, NULL, 0, tfd, "manifest.conf", err, errsz) < 0)
        goto out;
    close(fd);
    fd = -1;
    if ((sbfd = openat(dfd, "backgrounds", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) < 0 ||
        !(bd = fdopendir(sbfd))) {
        snprintf(err, errsz, "backgrounds/: %s", strerror(errno));
        goto out;
    }
    sbfd = -1; /* agora pertence a bd */
    struct dirent *de;
    struct stat st;
    char shown[300];
    while ((de = readdir(bd))) {
        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
            continue;
        snprintf(shown, sizeof shown, "backgrounds/%.255s", de->d_name);
        if (stat_child(dirfd(bd), de->d_name, shown, &st, err, errsz) < 0)
            goto out;
        if (S_ISDIR(st.st_mode) || !image_name_valid(de->d_name))
            continue;
        if ((fd = open_reg(dirfd(bd), de->d_name, shown, &sz, err, errsz)) < 0)
            goto out;
        unsigned char head[29];
        char pe[128];
        ssize_t got = read_full(fd, head, sizeof head);
        if (got < 0) {
            snprintf(err, errsz, "falha ao ler %s", shown);
            goto out;
        }
        if (png_check_buf(head, (size_t)got, NULL, pe, sizeof pe) == 0) {
            if (copy_to(fd, head, (size_t)got, bfd, de->d_name, err, errsz) < 0)
                goto out;
            n++;
        }
        close(fd);
        fd = -1;
    }
    if (syncfs(tfd) < 0)
        warnmsg("syncfs falhou: %s", strerror(errno));
    *n_out = n;
    rc = 0;
out:
    if (fd >= 0)
        close(fd);
    if (bd)
        closedir(bd);
    if (sbfd >= 0)
        close(sbfd);
    if (bfd >= 0)
        close(bfd);
    if (tfd >= 0)
        close(tfd);
    if (dfd >= 0)
        close(dfd);
    return rc;
}

/* Remove diretorios temporarios de importacoes/remocoes interrompidas */
static void cleanup_stale(void)
{
    DIR *d = opendir(P.bundles_dir);
    if (!d)
        return;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (strncmp(de->d_name, ".import-", 8) && strncmp(de->d_name, ".remove-", 8) &&
            strncmp(de->d_name, ".old-", 5))
            continue;
        char p[PATH_MAX];
        if (pathf(p, sizeof p, "%s/%s", P.bundles_dir, de->d_name) == 0 && is_dir(p)) {
            if (rm_rf(p) == 0)
                note("Removido temporario de operacao interrompida: %s", de->d_name);
        }
    }
    closedir(d);
}

/* Substituicao atomica (ou instalacao sem sobrescrever) */
static int install_dir(const char *tmp, const char *dest, bool replace, char *err, size_t errsz)
{
    if (replace) {
        if (renameat2(AT_FDCWD, tmp, AT_FDCWD, dest, RENAME_EXCHANGE) == 0)
            return 0; /* versao antiga agora esta em tmp */
        if (errno != EINVAL && errno != ENOSYS) {
            snprintf(err, errsz, "falha ao substituir %s: %s", dest, strerror(errno));
            return -1;
        }
        /* Filesystem sem RENAME_EXCHANGE: dois renames com rollback */
        char old[PATH_MAX];
        pathf(old, sizeof old, "%s/.old-%ld", P.bundles_dir, (long)getpid());
        if (rename(dest, old) < 0) {
            snprintf(err, errsz, "falha ao mover a versao anterior: %s", strerror(errno));
            return -1;
        }
        if (rename(tmp, dest) < 0) {
            int e = errno;
            rename(old, dest);
            snprintf(err, errsz, "falha ao instalar: %s (versao anterior restaurada)", strerror(e));
            return -1;
        }
        rename(old, tmp);
        return 0;
    }
    if (renameat2(AT_FDCWD, tmp, AT_FDCWD, dest, RENAME_NOREPLACE) == 0)
        return 0;
    if (errno == EINVAL || errno == ENOSYS) {
        if (!exists(dest) && rename(tmp, dest) == 0)
            return 0;
    }
    snprintf(err, errsz, "falha ao instalar em %s: %s", dest, strerror(errno));
    return -1;
}

static void print_summary(const char *path, const struct kawall_info *ki, const struct scan *s)
{
    const struct bundle *b = &ki->meta;
    char sz[32];
    human_size(b->total, sz, sizeof sz);
    msg("Bundle valido: %s", path);
    note("ID:         %s", b->id);
    note("Nome:       %s", b->name);
    if (b->desc[0])
        note("Descricao:  %s", b->desc);
    note("Versao:     %s", b->version);
    if (b->author[0])
        note("Autor:      %s", b->author);
    note("Imagens:    %zu (%s)", b->nimg, sz);
    if (s && s->invalid_images)
        warnmsg("%ld imagem(ns) incompativel(is) com o GRUB sera(ao) ignorada(s) (ex.: %s)",
                s->invalid_images, s->invalid_example);
    if (ki->skipped)
        warnmsg("%ld entrada(s) nao reconhecida(s) sera(ao) ignorada(s) (ex.: %s)", ki->skipped,
                ki->skipped_example);
}

int cmd_import_bundle(const char *path)
{
    char err[512];
    struct stat st;

    /* 1. existencia, legibilidade e tipo (pacote .kawall ou pasta extraida) */
    if (stat(path, &st) < 0) {
        errmsg("%s: %s", path, strerror(errno));
        return KAM_EUSAGE;
    }
    bool from_dir = S_ISDIR(st.st_mode);
    if (!from_dir && !S_ISREG(st.st_mode)) {
        errmsg("%s nao e um arquivo regular nem uma pasta (esperado um pacote .kawall ou a pasta de um bundle)",
               path);
        return KAM_EUSAGE;
    }
    if (access(path, from_dir ? R_OK | X_OK : R_OK) < 0) {
        errmsg("%s: sem permissao de leitura", path);
        return KAM_EPRIV;
    }
    char src[PATH_MAX];
    if (from_dir) {
        if (resolve_bundle_dir(path, src, sizeof src, err, sizeof err) < 0) {
            errmsg("bundle invalido: %s", err);
            return KAM_EBUNDLE;
        }
    } else {
        snprintf(src, sizeof src, "%s", path);
        size_t pl = strlen(path);
        if (pl < 7 || strcmp(path + pl - 7, ".kawall"))
            warnmsg("%s nao tem a extensao .kawall; validando mesmo assim", path);
    }

    int rc;
    if (!O.dry_run && (rc = require_root("--import-bundle")))
        return rc;

    /* 2-6. estrutura, metadados, ID/versao, imagens, quantidade/tamanho */
    struct scan s;
    struct kawall_info ki;
    if ((from_dir ? scan_dir(src, &s, &ki, err, sizeof err) : scan_archive(src, &s, &ki, err, sizeof err)) < 0) {
        errmsg("bundle invalido: %s", err);
        scan_free(&s);
        return KAM_EBUNDLE;
    }
    print_summary(src, &ki, &s);
    long expected = (long)s.nnames;
    scan_free(&s);
    struct bundle *nb = &ki.meta;

    int lk = -1;
    if (!O.dry_run && (lk = kam_lock()) < 0)
        return KAM_EFAIL;

    /* 7. conflitos */
    char dest[PATH_MAX];
    pathf(dest, sizeof dest, "%s/%s", P.bundles_dir, nb->id);
    bool replace = false;
    struct bundle cur;
    rc = KAM_OK;
    if (exists(dest)) {
        if (!is_dir(dest)) {
            errmsg("%s existe e nao e um diretorio", dest);
            rc = KAM_ECONFLICT;
            goto out;
        }
        bundle_load(dest, nb->id, &cur);
        const char *cv = cur.valid ? cur.version : "0.0.0";
        int c = semver_cmp(nb->version, cv);
        bundle_free(&cur);
        replace = true;
        if (c > 0) {
            msg("Atualizacao: '%s' instalado na versao %s%s -> %s", nb->id, cv,
                cur.valid ? "" : " (instalacao invalida)", nb->version);
            if (O.dry_run)
                goto out;
            if ((rc = confirm_rc("Atualizar o bundle (a configuracao e preservada)", true)))
                goto out;
        } else if (c == 0) {
            if (!O.force) {
                msg("O bundle '%s' ja esta instalado na versao %s; nada a fazer.", nb->id, cv);
                note("Para reinstalar, use --force.");
                rc = O.dry_run ? KAM_OK : KAM_ECONFLICT;
                goto out;
            }
            if (O.dry_run)
                goto out;
            if ((rc = confirm_rc("Reinstalar a mesma versao", false)))
                goto out;
        } else {
            if (!O.force) {
                errmsg("downgrade recusado: '%s' instalado (%s) e mais novo que o pacote (%s).", nb->id, cv,
                       nb->version);
                note("Use --force para substituir mesmo assim.");
                rc = KAM_ECONFLICT;
                goto out;
            }
            if (O.dry_run)
                goto out;
            if ((rc = confirm_rc("Substituir pela versao MAIS ANTIGA", false)))
                goto out;
        }
    } else if (O.dry_run) {
        msg("O bundle '%s' nao esta instalado; a importacao seria permitida.", nb->id);
        goto out;
    }

    /* 9. extracao em temporario no filesystem de destino */
    if (mkdir_p(P.bundles_dir, 0755) < 0) {
        errmsg("nao foi possivel criar %s: %s", P.bundles_dir, strerror(errno));
        rc = errno == EACCES ? KAM_EPRIV : KAM_EFAIL;
        goto out;
    }
    cleanup_stale();
    char tmp[PATH_MAX];
    pathf(tmp, sizeof tmp, "%s/.import-%s-XXXXXX", P.bundles_dir, nb->id);
    if (!mkdtemp(tmp)) {
        errmsg("nao foi possivel criar diretorio temporario: %s", strerror(errno));
        rc = KAM_EFAIL;
        goto out;
    }
    msg("%s %zu imagens...", from_dir ? "Copiando" : "Extraindo", nb->nimg);
    long extracted = 0;
    if ((from_dir ? extract_dir(src, tmp, &extracted, err, sizeof err)
                  : extract_archive(src, tmp, &extracted, err, sizeof err)) < 0) {
        errmsg("falha na %s: %s", from_dir ? "copia" : "extracao", err);
        rm_rf(tmp);
        rc = KAM_EBUNDLE;
        goto out;
    }

    /* 10. validacao do conteudo extraido */
    struct bundle chk;
    if (bundle_load(tmp, nb->id, &chk) < 0 || chk.nvalid != (size_t)expected ||
        extracted != expected || strcmp(chk.version, nb->version)) {
        errmsg("validacao pos-extracao falhou (%s); nada foi instalado",
               chk.err[0] ? chk.err : "conteudo divergente");
        bundle_free(&chk);
        rm_rf(tmp);
        rc = KAM_EBUNDLE;
        goto out;
    }
    bundle_free(&chk);
    chmod(tmp, 0755);

    /* 11. instalacao atomica */
    if (install_dir(tmp, dest, replace, err, sizeof err) < 0) {
        errmsg("%s", err);
        rm_rf(tmp);
        rc = KAM_EFAIL;
        goto out;
    }
    fsync_dir(P.bundles_dir);
    if (replace && rm_rf(tmp) < 0)
        warnmsg("versao anterior nao pode ser apagada de %s", tmp);

    /* 12-13. sem indice; selecao atual nao e alterada */
    msg("Bundle '%s' %s (versao %s).", nb->id, replace ? "atualizado" : "importado", nb->version);
    struct prefs c;
    bool have;
    if (prefs_load(&c, &have) == KAM_OK) {
        char fid[ID_MAX + 1] = "", fname[IMG_NAME_MAX + 1] = "";
        if (!strcmp(c.mode, "fixed") && sscanf(c.background, "%64[^/]/%255s", fid, fname) == 2 &&
            !strcmp(fid, nb->id)) {
            char ip[PATH_MAX];
            pathf(ip, sizeof ip, "%s/backgrounds/%s", dest, fname);
            if (!is_regular(ip))
                warnmsg("a imagem fixa configurada (%s) nao existe na nova versao; ajuste com --set-background",
                        c.background);
        }
        if (!have || (!strcmp(c.mode, "set") && !c.bundle[0]))
            note("Para usa-lo: sudo %s --set-bundle %s", KAM_PROG, nb->id);
    }
out:
    if (lk >= 0)
        close(lk);
    return rc;
}

static int kawall_filter(const struct dirent *de)
{
    size_t n = strlen(de->d_name);
    return de->d_name[0] != '.' && n > 7 && !strcmp(de->d_name + n - 7, ".kawall");
}

int cmd_list_available(const char *dir_arg)
{
    char dir[PATH_MAX];
    if (dir_arg)
        snprintf(dir, sizeof dir, "%s", dir_arg);
    else
        pathf(dir, sizeof dir, "%s/bundles", P.payload_dir);
    struct dirent **list;
    int n = scandir(dir, &list, kawall_filter, alphasort);
    if (n < 0) {
        if (errno == ENOENT) {
            msg("Nenhuma origem local de bundles em %s", dir);
            note("Informe um diretorio: %s --list-available-bundles DIR", KAM_PROG);
            return KAM_OK;
        }
        errmsg("%s: %s", dir, strerror(errno));
        return KAM_EFAIL;
    }
    if (n == 0) {
        msg("Nenhum pacote .kawall em %s", dir);
        free(list);
        return KAM_OK;
    }
    msg("Bundles disponiveis em %s", dir);
    printf("\n  %-20s %-10s %8s %11s  %-24s %s\n", "ID", "VERSAO", "IMAGENS", "TAMANHO", "SITUACAO", "ARQUIVO");
    for (int i = 0; i < n; i++) {
        char p[PATH_MAX], err[512];
        struct kawall_info ki;
        pathf(p, sizeof p, "%s/%s", dir, list[i]->d_name);
        if (kawall_inspect(p, &ki, err, sizeof err) < 0) {
            printf("  %-20s %-10s %8s %11s  %-24s %s\n", "?", "-", "-", "-", "invalido", list[i]->d_name);
            printf("  %-20s %s\n", "", err);
        } else {
            char sz[32], inst[PATH_MAX], status[64];
            struct bundle cur;
            human_size(ki.meta.total, sz, sizeof sz);
            pathf(inst, sizeof inst, "%s/%s", P.bundles_dir, ki.meta.id);
            if (!is_dir(inst)) {
                snprintf(status, sizeof status, "nao instalado");
            } else {
                bundle_load(inst, ki.meta.id, &cur);
                const char *cv = cur.valid ? cur.version : "invalido";
                int c = semver_cmp(ki.meta.version, cur.valid ? cur.version : "0.0.0");
                if (c > 0)
                    snprintf(status, sizeof status, "atualizacao (inst. %.10s)", cv);
                else if (c == 0)
                    snprintf(status, sizeof status, "instalado");
                else
                    snprintf(status, sizeof status, "inst. mais novo (%.8s)", cv);
                bundle_free(&cur);
            }
            printf("  %-20s %-10s %8zu %11s  %-24s %s\n", ki.meta.id, ki.meta.version, ki.meta.nimg, sz, status,
                   list[i]->d_name);
        }
        free(list[i]);
    }
    free(list);
    return KAM_OK;
}
