/* kawaii-arch-manager - utilitarios de E/S, processos e mensagens */
#include "kam.h"

#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static bool color_out(void) { return isatty(STDOUT_FILENO); }
static bool color_err(void) { return isatty(STDERR_FILENO); }

void msg(const char *fmt, ...)
{
    va_list ap;
    fputs(color_out() ? "\033[32m==>\033[0m " : "==> ", stdout);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    fputc('\n', stdout);
}

void note(const char *fmt, ...)
{
    va_list ap;
    fputs("    ", stdout);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    fputc('\n', stdout);
}

void warnmsg(const char *fmt, ...)
{
    va_list ap;
    fflush(stdout);
    fputs(color_err() ? "\033[33maviso:\033[0m " : "aviso: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

void errmsg(const char *fmt, ...)
{
    va_list ap;
    fflush(stdout);
    fputs(color_err() ? "\033[31merro:\033[0m " : "erro: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

/* Elevacao explicita: nunca chama sudo sozinho, apenas orienta. */
int require_root(const char *what)
{
    if (geteuid() == 0 || getenv("KAWAII_SKIP_ROOT_CHECK"))
        return KAM_OK;
    errmsg("%s requer privilegios de administrador.", what);
    fprintf(stderr, "       Execute novamente com: sudo %s ...\n", KAM_PROG);
    return KAM_EPRIV;
}

int confirm(const char *question, bool def)
{
    char line[64];
    const char *hint = def ? "[S/n]" : "[s/N]";

    if (O.yes) {
        printf("? %s %s %s (--yes)\n", question, hint, "s");
        return 1;
    }
    if (!isatty(STDIN_FILENO)) {
        errmsg("confirmacao necessaria (\"%s\"), mas nao ha terminal; use --yes", question);
        return -1;
    }
    for (;;) {
        printf("%s? %s %s ", color_out() ? "\033[36m" : "", question, hint);
        if (color_out())
            fputs("\033[0m", stdout);
        fflush(stdout);
        if (!fgets(line, sizeof line, stdin))
            return -1;
        trim(line);
        if (!line[0])
            return def ? 1 : 0;
        if (!strcasecmp(line, "s") || !strcasecmp(line, "sim") ||
            !strcasecmp(line, "y") || !strcasecmp(line, "yes"))
            return 1;
        if (!strcasecmp(line, "n") || !strcasecmp(line, "nao") ||
            !strcasecmp(line, "não") || !strcasecmp(line, "no"))
            return 0;
        warnmsg("responda 's' ou 'n'");
    }
}

int confirm_rc(const char *question, bool def)
{
    int r = confirm(question, def);
    if (r > 0)
        return KAM_OK;
    if (r == 0)
        msg("Operacao cancelada.");
    return r < 0 ? KAM_ECONFLICT : KAM_ECANCEL;
}

int pathf(char *out, size_t sz, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(out, sz, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= sz) {
        out[0] = '\0';
        return -1;
    }
    return 0;
}

char *read_file(const char *path, size_t max, size_t *len)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
        return NULL;
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || (size_t)st.st_size > max) {
        close(fd);
        errno = EFBIG;
        return NULL;
    }
    size_t cap = (size_t)st.st_size + 1, n = 0;
    char *buf = malloc(cap);
    if (!buf) {
        close(fd);
        return NULL;
    }
    for (;;) {
        if (n + 1 >= cap) {
            if (cap > max) {
                free(buf);
                close(fd);
                errno = EFBIG;
                return NULL;
            }
            char *nb = realloc(buf, cap * 2);
            if (!nb) {
                free(buf);
                close(fd);
                return NULL;
            }
            buf = nb;
            cap *= 2;
        }
        ssize_t r = read(fd, buf + n, cap - n - 1);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            free(buf);
            close(fd);
            return NULL;
        }
        if (r == 0)
            break;
        n += (size_t)r;
    }
    close(fd);
    buf[n] = '\0';
    if (len)
        *len = n;
    return buf;
}

int fsync_dir(const char *dir)
{
    int fd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    int r = fsync(fd);
    close(fd);
    return r;
}

static void dirname_of(const char *path, char *out, size_t sz)
{
    snprintf(out, sz, "%s", path);
    char *s = strrchr(out, '/');
    if (!s)
        snprintf(out, sz, ".");
    else if (s == out)
        out[1] = '\0';
    else
        *s = '\0';
}

static int write_all(int fd, const void *data, size_t len)
{
    const char *p = data;
    while (len) {
        ssize_t w = write(fd, p, len);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        p += w;
        len -= (size_t)w;
    }
    return 0;
}

int write_file_atomic(const char *path, const char *data, size_t len, mode_t mode)
{
    char tmp[PATH_MAX], dir[PATH_MAX];
    if (pathf(tmp, sizeof tmp, "%s.tmp.XXXXXX", path) < 0)
        return -1;
    int fd = mkostemp(tmp, O_CLOEXEC);
    if (fd < 0)
        return -1;
    if (write_all(fd, data, len) < 0 || fchmod(fd, mode) < 0 || fsync(fd) < 0) {
        int e = errno;
        close(fd);
        unlink(tmp);
        errno = e;
        return -1;
    }
    close(fd);
    if (rename(tmp, path) < 0) {
        int e = errno;
        unlink(tmp);
        errno = e;
        return -1;
    }
    dirname_of(path, dir, sizeof dir);
    fsync_dir(dir);
    return 0;
}

/* Copia src para tmp (mesmo diretorio do destino), confere o tamanho,
 * fsync e rename(2) atomico sobre dst. Em falha, dst fica intacto. */
int copy_file_atomic(const char *src, const char *dst, const char *tmp, mode_t mode)
{
    char dir[PATH_MAX];
    int in = open(src, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (in < 0)
        return -1;
    struct stat st;
    if (fstat(in, &st) < 0 || !S_ISREG(st.st_mode)) {
        close(in);
        errno = EINVAL;
        return -1;
    }
    unlink(tmp);
    int out = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (out < 0) {
        int e = errno;
        close(in);
        errno = e;
        return -1;
    }
    char buf[1 << 16];
    long long total = 0;
    int rc = 0;
    for (;;) {
        ssize_t r = read(in, buf, sizeof buf);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            rc = -1;
            break;
        }
        if (r == 0)
            break;
        if (write_all(out, buf, (size_t)r) < 0) {
            rc = -1;
            break;
        }
        total += r;
    }
    int e = errno;
    close(in);
    if (rc == 0 && total != (long long)st.st_size) {
        rc = -1;
        e = EIO;
    }
    if (rc == 0 && (fchmod(out, mode) < 0 || fsync(out) < 0)) {
        rc = -1;
        e = errno;
    }
    close(out);
    if (rc == 0 && rename(tmp, dst) < 0) {
        rc = -1;
        e = errno;
    }
    if (rc < 0) {
        unlink(tmp);
        errno = e;
        return -1;
    }
    dirname_of(dst, dir, sizeof dir);
    fsync_dir(dir);
    return 0;
}

int mkdir_p(const char *path, mode_t mode)
{
    char buf[PATH_MAX];
    if (pathf(buf, sizeof buf, "%s", path) < 0)
        return -1;
    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(buf, mode) < 0 && errno != EEXIST)
                return -1;
            *p = '/';
        }
    }
    if (mkdir(buf, mode) < 0 && errno != EEXIST)
        return -1;
    return is_dir(buf) ? 0 : -1;
}

static int rm_cb(const char *p, const struct stat *sb, int flag, struct FTW *ftw)
{
    (void)sb;
    (void)flag;
    (void)ftw;
    return remove(p) < 0 && errno != ENOENT ? -1 : 0;
}

/* Remocao recursiva sem seguir links e sem atravessar filesystems */
int rm_rf(const char *path)
{
    struct stat st;
    if (lstat(path, &st) < 0)
        return errno == ENOENT ? 0 : -1;
    if (!S_ISDIR(st.st_mode))
        return unlink(path);
    return nftw(path, rm_cb, 32, FTW_DEPTH | FTW_PHYS | FTW_MOUNT);
}

bool is_regular(const char *path)
{
    struct stat st;
    return lstat(path, &st) == 0 && S_ISREG(st.st_mode);
}

bool is_dir(const char *path)
{
    struct stat st;
    return lstat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

bool exists(const char *path)
{
    struct stat st;
    return lstat(path, &st) == 0;
}

bool is_executable(const char *path)
{
    return is_regular(path) && access(path, X_OK) == 0;
}

void human_size(long long b, char *buf, size_t sz)
{
    const char *u[] = {"B", "KiB", "MiB", "GiB", "TiB"};
    double v = (double)b;
    int i = 0;
    while (v >= 1024 && i < 4) {
        v /= 1024;
        i++;
    }
    if (i == 0)
        snprintf(buf, sz, "%lld B", b);
    else
        snprintf(buf, sz, "%.1f %s", v, u[i]);
}

/* Executa argv (sem shell). Captura stdout em out (se dado). Retorna o
 * codigo de saida, ou -1 se nao foi possivel executar. */
int run_cmd(char *const argv[], char *out, size_t outsz, bool quiet)
{
    int pfd[2] = {-1, -1};
    if (out && pipe2(pfd, O_CLOEXEC) < 0)
        return -1;
    fflush(stdout);
    fflush(stderr);
    pid_t pid = fork();
    if (pid < 0) {
        if (out) {
            close(pfd[0]);
            close(pfd[1]);
        }
        return -1;
    }
    if (pid == 0) {
        if (out)
            dup2(pfd[1], STDOUT_FILENO);
        if (quiet) {
            int dn = open("/dev/null", O_WRONLY);
            if (dn >= 0) {
                if (!out)
                    dup2(dn, STDOUT_FILENO);
                dup2(dn, STDERR_FILENO);
            }
        }
        execvp(argv[0], argv);
        _exit(127);
    }
    if (out) {
        close(pfd[1]);
        size_t n = 0;
        for (;;) {
            char tmp[512];
            ssize_t r = read(pfd[0], tmp, sizeof tmp);
            if (r < 0 && errno == EINTR)
                continue;
            if (r <= 0)
                break;
            size_t c = (size_t)r;
            if (outsz && n + c >= outsz)
                c = outsz - 1 - n;
            memcpy(out + n, tmp, c);
            n += c;
        }
        out[outsz ? n : 0] = '\0';
        close(pfd[0]);
        trim(out);
    }
    int status;
    while (waitpid(pid, &status, 0) < 0)
        if (errno != EINTR)
            return -1;
    if (WIFEXITED(status))
        return WEXITSTATUS(status) == 127 ? -1 : WEXITSTATUS(status);
    return -1;
}

int lock_file(const char *path, int timeout_s)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0644);
    if (fd < 0)
        return -1;
    for (int i = 0; i <= timeout_s * 10; i++) {
        if (flock(fd, LOCK_EX | LOCK_NB) == 0)
            return fd;
        if (errno != EWOULDBLOCK) {
            close(fd);
            return -1;
        }
        struct timespec ts = {0, 100 * 1000 * 1000};
        nanosleep(&ts, NULL);
    }
    close(fd);
    errno = EWOULDBLOCK;
    return -1;
}

void trim(char *s)
{
    size_t n = strlen(s);
    while (n && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' ' || s[n - 1] == '\t'))
        s[--n] = '\0';
    size_t i = 0;
    while (s[i] == ' ' || s[i] == '\t')
        i++;
    if (i)
        memmove(s, s + i, n - i + 1);
}

bool utf8_valid(const char *str, size_t n)
{
    const unsigned char *s = (const unsigned char *)str;
    size_t i = 0;
    while (i < n) {
        unsigned char c = s[i];
        size_t len;
        unsigned cp;
        if (c < 0x80) {
            i++;
            continue;
        } else if ((c & 0xE0) == 0xC0) {
            len = 2;
            cp = c & 0x1F;
        } else if ((c & 0xF0) == 0xE0) {
            len = 3;
            cp = c & 0x0F;
        } else if ((c & 0xF8) == 0xF0) {
            len = 4;
            cp = c & 0x07;
        } else {
            return false;
        }
        if (i + len > n)
            return false;
        for (size_t k = 1; k < len; k++) {
            if ((s[i + k] & 0xC0) != 0x80)
                return false;
            cp = (cp << 6) | (s[i + k] & 0x3F);
        }
        if ((len == 2 && cp < 0x80) || (len == 3 && cp < 0x800) ||
            (len == 4 && (cp < 0x10000 || cp > 0x10FFFF)) ||
            (cp >= 0xD800 && cp <= 0xDFFF))
            return false;
        i += len;
    }
    return true;
}

/* Inteiro uniforme em [0, n) via getrandom(2) com rejeicao */
unsigned long long rand_below(unsigned long long n)
{
    if (n <= 1)
        return 0;
    unsigned long long lim = ULLONG_MAX - (ULLONG_MAX % n), r;
    do {
        if (getrandom(&r, sizeof r, 0) != (ssize_t)sizeof r)
            r = ((unsigned long long)rand() << 32) ^ (unsigned long long)rand();
    } while (r >= lim);
    return r % n;
}
