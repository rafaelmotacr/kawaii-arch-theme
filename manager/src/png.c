/* kawaii-arch-manager - validacao de PNG compativel com o leitor do GRUB
 *
 * O leitor PNG do GRUB (video/readers/png.c) aceita somente profundidade
 * 8 ou 16, tipos de cor gray/RGB/gray+alpha/RGBA, compressao/filtro 0 e
 * sem entrelacamento. Uma imagem fora disso deixaria o menu sem fundo. */
#include "kam.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static unsigned be32(const unsigned char *p)
{
    return (unsigned)p[0] << 24 | (unsigned)p[1] << 16 | (unsigned)p[2] << 8 | p[3];
}

int png_check_buf(const unsigned char *b, size_t n, struct png_info *pi, char *err, size_t errsz)
{
    static const unsigned char sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    if (n < 29 || memcmp(b, sig, 8) != 0) {
        snprintf(err, errsz, "nao e um arquivo PNG");
        return -1;
    }
    if (be32(b + 8) != 13 || memcmp(b + 12, "IHDR", 4) != 0) {
        snprintf(err, errsz, "PNG sem cabecalho IHDR valido");
        return -1;
    }
    unsigned w = be32(b + 16), h = be32(b + 20);
    int depth = b[24], color = b[25];
    if (w == 0 || h == 0 || w > 32768 || h > 32768) {
        snprintf(err, errsz, "dimensoes invalidas (%ux%u)", w, h);
        return -1;
    }
    if (depth != 8 && depth != 16) {
        snprintf(err, errsz, "profundidade de %d bits nao suportada pelo GRUB (use 8 ou 16)", depth);
        return -1;
    }
    if (color != 0 && color != 2 && color != 4 && color != 6) {
        snprintf(err, errsz, "tipo de cor %d nao suportado pelo GRUB (PNG indexado/paleta?)", color);
        return -1;
    }
    if (b[26] != 0 || b[27] != 0) {
        snprintf(err, errsz, "metodo de compressao/filtro nao suportado");
        return -1;
    }
    if (b[28] != 0) {
        snprintf(err, errsz, "PNG entrelacado nao e suportado pelo GRUB");
        return -1;
    }
    if (pi) {
        pi->w = w;
        pi->h = h;
        pi->depth = depth;
        pi->color = color;
    }
    return 0;
}

int png_check_file(const char *path, struct png_info *pi, char *err, size_t errsz)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        snprintf(err, errsz, "%s", strerror(errno));
        return -1;
    }
    unsigned char b[29];
    ssize_t got = read_full(fd, b, sizeof b);
    close(fd);
    return png_check_buf(b, got > 0 ? (size_t)got : 0, pi, err, errsz);
}
