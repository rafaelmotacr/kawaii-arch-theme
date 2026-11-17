/* kawaii-arch-manager - tom (claro/escuro) de um wallpaper
 *
 * Decodifica o PNG (somente o formato aceito pelo GRUB: 8/16 bits,
 * cinza/RGB/cinza+alfa/RGBA, sem entrelacamento) e mede a claridade nas
 * areas onde o tema desenha texto: o menu e o logo. O resultado decide
 * se o tema usa o tom "dark" (texto/icones claros, para wallpaper escuro)
 * ou "light" (texto/icones escuros, para wallpaper claro).
 *
 * Criterio: para cada pixel amostrado, o texto escuro (#1c1c22) da mais
 * contraste que o claro (#ffffff) quando (L + 0.05)^2 > 1.05 * (Ld + 0.05),
 * sendo L a luminancia relativa do pixel. Usamos a media geometrica de
 * (L + 0.05) na area: o tom escolhido e o que maximiza o contraste medio
 * (em escala logaritmica), o que tambem pesa as regioes mistas. */
#include "kam.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>

/* Areas do texto, em fracao da imagem (o GRUB estica o wallpaper para a
 * tela). Menu: left 5%, top 36%; icone + nome ocupam ~420 px de 1920
 * (ate ~27%) e as primeiras entradas (~4 x 83 px de 1080) ficam ate ~64%,
 * onde quase sempre ha texto (o resto do menu costuma ficar vazio).
 * Logo: left 5%, 256x85 px acima da barra (~88% a 97% em 1080p).
 * Calibrado nos 44 wallpapers dos bundles originais. */
static const struct { double x0, y0, x1, y1; } AREAS[] = {
    {0.05, 0.36, 0.27, 0.64},
    {0.05, 0.88, 0.19, 0.97},
};
#define NAREAS (sizeof AREAS / sizeof AREAS[0])
#define SAMPLES_PER_AXIS 160    /* amostragem por area (passo uniforme) */
#define TEXT_DARK_L 0.0111      /* luminancia de #1c1c22 */

struct reader {
    FILE *f;
    unsigned w, h;
    int depth, color, chans, bpp;   /* bpp: bytes por pixel */
    size_t stride;
    unsigned char *cur, *prev;
    size_t filled;                  /* bytes de cur (inclui o filtro) */
    unsigned y;                     /* linha atual */
    unsigned ymax;                  /* ultima linha necessaria (exclusiva) */
    double lin[256];
    double acc;
    unsigned long long n;
    /* limites amostrados por area */
    unsigned ax0[NAREAS], ax1[NAREAS], ay0[NAREAS], ay1[NAREAS], sx[NAREAS], sy[NAREAS];
};

static uint32_t be32(const unsigned char *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static int paeth(int a, int b, int c)
{
    int p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c);
    return (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
}

static int unfilter(struct reader *r)
{
    unsigned char *x = r->cur + 1, *p = r->prev + 1;
    size_t n = r->stride, bpp = (size_t)r->bpp;
    switch (r->cur[0]) {
    case 0: break;
    case 1: for (size_t i = bpp; i < n; i++) x[i] += x[i - bpp]; break;
    case 2: for (size_t i = 0; i < n; i++) x[i] += p[i]; break;
    case 3:
        for (size_t i = 0; i < n; i++)
            x[i] += (unsigned char)(((i >= bpp ? x[i - bpp] : 0) + p[i]) / 2);
        break;
    case 4:
        for (size_t i = 0; i < n; i++)
            x[i] += (unsigned char)paeth(i >= bpp ? x[i - bpp] : 0, p[i], i >= bpp ? p[i - bpp] : 0);
        break;
    default: return -1;
    }
    return 0;
}

static void sample_row(struct reader *r)
{
    const unsigned char *x = r->cur + 1;
    int step = r->depth / 8;   /* usa o byte mais significativo em 16 bits */
    for (size_t k = 0; k < NAREAS; k++) {
        if (r->y < r->ay0[k] || r->y >= r->ay1[k] || (r->y - r->ay0[k]) % r->sy[k])
            continue;
        for (unsigned px = r->ax0[k]; px < r->ax1[k]; px += r->sx[k]) {
            const unsigned char *s = x + (size_t)px * (size_t)r->bpp;
            double L, a = 1.0;
            if (r->color == 0 || r->color == 4) {
                L = r->lin[s[0]];
                if (r->color == 4)
                    a = s[step] / 255.0;
            } else {
                L = 0.2126 * r->lin[s[0]] + 0.7152 * r->lin[s[step]] + 0.0722 * r->lin[s[2 * step]];
                if (r->color == 6)
                    a = s[3 * step] / 255.0;
            }
            L *= a;   /* transparencia: desktop-color do tema e preto */
            r->acc += log(L + 0.05);
            r->n++;
        }
    }
}

/* Recebe bytes descompactados; processa linhas completas */
static int feed(struct reader *r, const unsigned char *d, size_t len)
{
    while (len && r->y < r->ymax) {
        size_t need = r->stride + 1 - r->filled, take = len < need ? len : need;
        memcpy(r->cur + r->filled, d, take);
        r->filled += take;
        d += take;
        len -= take;
        if (r->filled == r->stride + 1) {
            if (unfilter(r) < 0)
                return -1;
            sample_row(r);
            unsigned char *t = r->prev;
            r->prev = r->cur;
            r->cur = t;
            r->filled = 0;
            r->y++;
        }
    }
    return 0;
}

static int read_exact(FILE *f, void *buf, size_t n)
{
    return fread(buf, 1, n, f) == n ? 0 : -1;
}

/* png_tone_score: media de log(L + 0.05) nas areas do texto */
static int png_tone_score(const char *path, double *score, char *err, size_t errsz)
{
    struct reader r = {0};
    unsigned char hdr[33], buf[65536], out[65536];
    z_stream z = {0};
    int rc = -1, zinit = 0;

    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0 || !(r.f = fdopen(fd, "rb"))) {
        snprintf(err, errsz, "%s", strerror(errno));
        if (fd >= 0)
            close(fd);
        return -1;
    }
    struct png_info pi;
    if (read_exact(r.f, hdr, sizeof hdr) < 0 || png_check_buf(hdr, sizeof hdr, &pi, err, errsz) < 0) {
        if (!err[0])
            snprintf(err, errsz, "PNG truncado");
        goto out;
    }
    r.w = pi.w;
    r.h = pi.h;
    r.depth = pi.depth;
    r.color = pi.color;
    r.chans = r.color == 0 ? 1 : r.color == 2 ? 3 : r.color == 4 ? 2 : 4;
    r.bpp = r.chans * r.depth / 8;
    r.stride = (size_t)r.w * (size_t)r.bpp;
    r.cur = calloc(1, r.stride + 1);
    r.prev = calloc(1, r.stride + 1);
    if (!r.cur || !r.prev) {
        snprintf(err, errsz, "sem memoria");
        goto out;
    }
    for (int i = 0; i < 256; i++) {
        double c = i / 255.0;
        r.lin[i] = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
    }
    for (size_t k = 0; k < NAREAS; k++) {
        r.ax0[k] = (unsigned)(AREAS[k].x0 * r.w);
        r.ax1[k] = (unsigned)(AREAS[k].x1 * r.w);
        r.ay0[k] = (unsigned)(AREAS[k].y0 * r.h);
        r.ay1[k] = (unsigned)(AREAS[k].y1 * r.h);
        if (r.ax1[k] <= r.ax0[k])
            r.ax1[k] = r.ax0[k] + 1;
        if (r.ay1[k] <= r.ay0[k])
            r.ay1[k] = r.ay0[k] + 1;
        if (r.ax1[k] > r.w)
            r.ax1[k] = r.w;
        if (r.ay1[k] > r.h)
            r.ay1[k] = r.h;
        r.sx[k] = (r.ax1[k] - r.ax0[k]) / SAMPLES_PER_AXIS;
        r.sy[k] = (r.ay1[k] - r.ay0[k]) / SAMPLES_PER_AXIS;
        if (!r.sx[k])
            r.sx[k] = 1;
        if (!r.sy[k])
            r.sy[k] = 1;
        if (r.ay1[k] > r.ymax)
            r.ymax = r.ay1[k];
    }
    if (inflateInit(&z) != Z_OK) {
        snprintf(err, errsz, "falha ao iniciar a zlib");
        goto out;
    }
    zinit = 1;
    /* hdr ja contem o IHDR completo (8 + 4 + 4 + 13 + CRC 4) */
    for (;;) {
        unsigned char ch[8];
        if (read_exact(r.f, ch, 8) < 0) {
            snprintf(err, errsz, "PNG truncado (sem IEND)");
            goto out;
        }
        uint32_t len = be32(ch);
        if (len > 0x7fffffffu) {
            snprintf(err, errsz, "chunk invalido");
            goto out;
        }
        if (!memcmp(ch + 4, "IEND", 4))
            break;
        if (memcmp(ch + 4, "IDAT", 4)) {
            if (fseeko(r.f, (off_t)len + 4, SEEK_CUR) < 0) {
                snprintf(err, errsz, "PNG truncado");
                goto out;
            }
            continue;
        }
        while (len) {
            size_t take = len < sizeof buf ? len : sizeof buf;
            if (read_exact(r.f, buf, take) < 0) {
                snprintf(err, errsz, "PNG truncado (IDAT)");
                goto out;
            }
            len -= (uint32_t)take;
            z.next_in = buf;
            z.avail_in = (uInt)take;
            while (z.avail_in && r.y < r.ymax) {
                z.next_out = out;
                z.avail_out = sizeof out;
                int zr = inflate(&z, Z_NO_FLUSH);
                if (zr != Z_OK && zr != Z_STREAM_END && zr != Z_BUF_ERROR) {
                    snprintf(err, errsz, "dados compactados invalidos");
                    goto out;
                }
                if (feed(&r, out, sizeof out - z.avail_out) < 0) {
                    snprintf(err, errsz, "filtro de linha invalido");
                    goto out;
                }
                if (zr == Z_STREAM_END || (zr == Z_BUF_ERROR && z.avail_out))
                    break;
            }
            if (r.y >= r.ymax)
                goto done;   /* as linhas restantes nao sao usadas */
        }
        if (fseeko(r.f, 4, SEEK_CUR) < 0) {   /* CRC */
            snprintf(err, errsz, "PNG truncado");
            goto out;
        }
    }
done:
    if (r.y < r.ymax || !r.n) {
        snprintf(err, errsz, "PNG incompleto (%u de %u linhas)", r.y, r.h);
        goto out;
    }
    *score = r.acc / (double)r.n;
    rc = 0;
out:
    if (zinit)
        inflateEnd(&z);
    free(r.cur);
    free(r.prev);
    fclose(r.f);
    return rc;
}

int png_tone(const char *path, const char **tone, double *score_out, char *err, size_t errsz)
{
    double score;
    err[0] = '\0';
    if (png_tone_score(path, &score, err, errsz) < 0)
        return -1;
    /* texto escuro vence quando (L+0.05)^2 > 1.05 * (Ld+0.05) */
    double threshold = 0.5 * log(1.05 * (TEXT_DARK_L + 0.05));
    *tone = score > threshold ? "light" : "dark";
    if (score_out)
        *score_out = exp(score) - 0.05;   /* luminancia "media" equivalente */
    return 0;
}

int cmd_tone(const char *path)
{
    const char *tone;
    double eq;
    char err[256];
    if (png_tone(path, &tone, &eq, err, sizeof err) < 0) {
        errmsg("nao foi possivel medir %s: %s", path, err);
        return KAM_EBUNDLE;
    }
    printf("%s\n", tone);
    if (getenv("KAM_TONE_DEBUG"))
        fprintf(stderr, "%s: luminancia equivalente %.3f (limiar %.3f)\n", path, eq,
                sqrt(1.05 * (TEXT_DARK_L + 0.05)) - 0.05);
    return KAM_OK;
}
