/* kawaii-arch-manager - SemVer 2.0.0 (validacao e precedencia) */
#include "kam.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

static bool num_ok(const char *s, size_t n)
{
    if (n == 0)
        return false;
    if (n > 1 && s[0] == '0')
        return false;
    for (size_t i = 0; i < n; i++)
        if (!isdigit((unsigned char)s[i]))
            return false;
    return true;
}

static bool ident_list_ok(const char *s, size_t n, bool numeric_no_lead0)
{
    if (n == 0)
        return false;
    size_t start = 0;
    for (size_t i = 0; i <= n; i++) {
        if (i == n || s[i] == '.') {
            size_t len = i - start;
            if (len == 0)
                return false;
            bool all_digit = true;
            for (size_t k = start; k < i; k++) {
                char c = s[k];
                if (!isalnum((unsigned char)c) && c != '-')
                    return false;
                if (!isdigit((unsigned char)c))
                    all_digit = false;
            }
            if (numeric_no_lead0 && all_digit && len > 1 && s[start] == '0')
                return false;
            start = i + 1;
        }
    }
    return true;
}

bool semver_valid(const char *v)
{
    if (!v || !*v || strlen(v) > 63)
        return false;
    const char *plus = strchr(v, '+');
    size_t core_len = plus ? (size_t)(plus - v) : strlen(v);
    const char *dash = memchr(v, '-', core_len);
    size_t ver_len = dash ? (size_t)(dash - v) : core_len;

    const char *p = v;
    for (int part = 0; part < 3; part++) {
        const char *end = v + ver_len;
        const char *dot = part < 2 ? memchr(p, '.', (size_t)(end - p)) : end;
        if (!dot)
            return false;
        if (!num_ok(p, (size_t)(dot - p)))
            return false;
        p = dot + 1;
    }
    if (p != v + ver_len + 1)
        return false;
    if (dash && !ident_list_ok(dash + 1, core_len - ver_len - 1, true))
        return false;
    if (plus && !ident_list_ok(plus + 1, strlen(plus + 1), false))
        return false;
    return true;
}

static int cmp_ull(unsigned long long a, unsigned long long b) { return a < b ? -1 : a > b; }

static bool all_digits(const char *s, size_t n)
{
    for (size_t i = 0; i < n; i++)
        if (!isdigit((unsigned char)s[i]))
            return false;
    return n > 0;
}

static int cmp_prerelease(const char *a, size_t an, const char *b, size_t bn)
{
    size_t i = 0, j = 0;
    while (i < an || j < bn) {
        if (i >= an)
            return -1;
        if (j >= bn)
            return 1;
        size_t ie = i, je = j;
        while (ie < an && a[ie] != '.')
            ie++;
        while (je < bn && b[je] != '.')
            je++;
        bool ad = all_digits(a + i, ie - i), bd = all_digits(b + j, je - j);
        int c;
        if (ad && bd)
            c = cmp_ull(strtoull(a + i, NULL, 10), strtoull(b + j, NULL, 10));
        else if (ad)
            c = -1;
        else if (bd)
            c = 1;
        else {
            size_t la = ie - i, lb = je - j, m = la < lb ? la : lb;
            c = memcmp(a + i, b + j, m);
            c = c ? (c < 0 ? -1 : 1) : cmp_ull(la, lb);
        }
        if (c)
            return c;
        i = ie + 1;
        j = je + 1;
        if (ie >= an && je >= bn)
            break;
        if (ie >= an)
            return -1;
        if (je >= bn)
            return 1;
    }
    return 0;
}

/* -1 se a<b, 0 se iguais, 1 se a>b. Versoes invalidas valem 0.0.0. */
int semver_cmp(const char *a, const char *b)
{
    if (!semver_valid(a))
        a = "0.0.0";
    if (!semver_valid(b))
        b = "0.0.0";
    unsigned long long x[3], y[3];
    char *e;
    const char *p = a, *q = b;
    for (int i = 0; i < 3; i++) {
        x[i] = strtoull(p, &e, 10);
        p = e + 1;
        y[i] = strtoull(q, &e, 10);
        q = e + 1;
        int c = cmp_ull(x[i], y[i]);
        if (c)
            return c;
    }
    size_t al = strcspn(a, "+"), bl = strcspn(b, "+");
    const char *ad = memchr(a, '-', al), *bd = memchr(b, '-', bl);
    if (!ad && !bd)
        return 0;
    if (!ad)
        return 1;
    if (!bd)
        return -1;
    return cmp_prerelease(ad + 1, (size_t)(a + al - ad - 1), bd + 1, (size_t)(b + bl - bd - 1));
}
