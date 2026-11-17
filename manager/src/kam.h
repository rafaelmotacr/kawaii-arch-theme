/* kawaii-arch-manager - definicoes comuns */
#ifndef KAM_H
#define KAM_H

#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/types.h>

#ifndef KAM_VERSION
#define KAM_VERSION "0.0.0-dev"
#endif

#define KAM_PROG "kawaii-arch-manager"

/* Codigos de saida (documentados em --help) */
enum {
    KAM_OK = 0,        /* sucesso */
    KAM_EFAIL = 1,     /* falha operacional */
    KAM_EUSAGE = 2,    /* erro de argumento */
    KAM_EBUNDLE = 3,   /* bundle/configuracao invalido */
    KAM_ECONFLICT = 4, /* conflito (ja instalado, em uso, dependencia) */
    KAM_EPRIV = 5,     /* falta de privilegios / particao indisponivel */
    KAM_ECANCEL = 6,   /* cancelado pelo usuario */
};

#define THEME_NAME "kawaii-arch-theme"
#define ACTIVE_NAME "background.png"
#define FALLBACK_NAME "fallback.png"
#define HELPER_NAME "grub-random-bg.sh"
#define UNIT_NAME "grub-random-bg.service"
#define UNIT_TEMPLATE "grub-random-bg.service.in"

#define ID_MAX 64
#define NAME_MAX_LEN 128
#define DESC_MAX_LEN 512
#define IMG_NAME_MAX 255

/* Limites de importacao */
#define LIMIT_ENTRIES 20000L
#define LIMIT_IMAGES 10000L
#define LIMIT_FILE_BYTES (512LL * 1024 * 1024)
#define LIMIT_TOTAL_BYTES (8LL * 1024 * 1024 * 1024)
#define LIMIT_META_BYTES (64 * 1024)

/* ------------------------------------------------------------------ */
struct kam_paths {
    char root[PATH_MAX];          /* KAWAII_ROOT (testes) ou "" */
    char data_dir[PATH_MAX];      /* /var/lib/kawaii-arch-manager */
    char bundles_dir[PATH_MAX];
    char config_dir[PATH_MAX];
    char state_dir[PATH_MAX];
    char prefs_conf[PATH_MAX];   /* config/preferences.conf */
    char paths_conf[PATH_MAX];
    char last_bg[PATH_MAX];
    char apply_lock[PATH_MAX];
    char manager_lock[PATH_MAX];
    char lib_dir[PATH_MAX];       /* /usr/lib/kawaii-arch-manager */
    char helper_path[PATH_MAX];
    char share_dir[PATH_MAX];     /* /usr/share/kawaii-arch-manager */
    char payload_dir[PATH_MAX];
    char unit_path[PATH_MAX];     /* /usr/lib/systemd/system/<unit> */
    char bin_path[PATH_MAX];      /* /usr/bin/kawaii-arch-manager */
    char theme_raw[PATH_MAX];     /* caminho real do tema (sem root) */
    char theme_dir[PATH_MAX];     /* root + theme_raw, "" se desconhecido */
    char expected_mount[PATH_MAX];
    char systemctl[PATH_MAX];
    bool theme_from_conf;
};

struct kam_opts {
    bool yes;
    bool force;
    bool dry_run;
};

extern struct kam_paths P;
extern struct kam_opts O;

/* util.c */
void msg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void note(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void warnmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void errmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
int require_root(const char *what);
int confirm(const char *question, bool def); /* 1 sim, 0 nao, -1 sem tty */
int confirm_rc(const char *question, bool def); /* KAM_OK ou codigo */
int pathf(char *out, size_t sz, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
char *read_file(const char *path, size_t max, size_t *len);
int write_file_atomic(const char *path, const char *data, size_t len, mode_t mode);
int copy_file_atomic(const char *src, const char *dst, const char *tmp, mode_t mode);
int mkdir_p(const char *path, mode_t mode);
int rm_rf(const char *path);
int fsync_dir(const char *dir);
bool is_regular(const char *path);   /* arquivo regular, nao link */
bool is_dir(const char *path);       /* diretorio, nao link */
bool exists(const char *path);
bool is_executable(const char *path);
void human_size(long long bytes, char *buf, size_t sz);
int run_cmd(char *const argv[], char *out, size_t outsz, bool quiet);
int lock_file(const char *path, int timeout_s); /* fd ou -1 */
void trim(char *s);
bool utf8_valid(const char *s, size_t n);
unsigned long long rand_below(unsigned long long n);

/* semver.c */
bool semver_valid(const char *v);
int semver_cmp(const char *a, const char *b);

/* config.c */
struct kv_list;
struct kv_list *kv_load(const char *path, int *err);
const char *kv_get(const struct kv_list *l, const char *key);
int kv_set(struct kv_list *l, const char *key, const char *val);
void kv_free(struct kv_list *l);
int kv_parse_buf(struct kv_list *l, const char *buf, size_t len, char *err, size_t errsz);
struct kv_list *kv_new(void);
bool conf_value_safe(const char *v);

/* Preferencias do usuario: config/preferences.conf (fonte da verdade;
 * o theme.txt e derivado delas) */
struct prefs {
    char mode[16];
    char bundle[ID_MAX + 1];
    char background[ID_MAX + 2 + IMG_NAME_MAX];
    char logo[8];       /* on | off */
    char menu_box[8];   /* on | off */
    char tone[8];       /* auto | dark | light */
    char on_fresh[16];  /* backup | override | keep (usado so pelo install.sh) */
};
int paths_init(void);
int prefs_load(struct prefs *c, bool *exists_out);
int prefs_save(const struct prefs *c);
int prefs_check(const struct prefs *c, char *err, size_t errsz); /* valores validos? */
void prefs_warn_unknown(void);
bool onoff_valid(const char *v);
bool tone_valid(const char *v);
bool mode_valid(const char *m);

/* png.c */
struct png_info { unsigned w, h; int depth, color; };
int png_check_buf(const unsigned char *b, size_t n, struct png_info *pi, char *err, size_t errsz);
int png_check_file(const char *path, struct png_info *pi, char *err, size_t errsz);

/* layout.c */
int theme_element_state(const char *which); /* "logo" | "menu-box": 1, 0, -1 */
int layout_apply(int want_logo, int want_menu, bool dry, int *changed);
int theme_write_begin(int *lk);
int cmd_set_logo(const char *arg);
int cmd_set_menu_box(const char *arg);

/* tone.c */
int png_tone(const char *path, const char **tone, double *score_out, char *err, size_t errsz);
int cmd_tone(const char *path);

/* bundle.c */
struct image {
    char name[IMG_NAME_MAX + 1];
    long long size;
    bool valid;
};
struct bundle {
    char id[ID_MAX + 1];
    char name[NAME_MAX_LEN + 1];
    char desc[DESC_MAX_LEN + 1];
    char version[64];
    char author[257];
    char dir[PATH_MAX];
    struct image *imgs;
    size_t nimg;        /* imagens encontradas */
    size_t nvalid;      /* imagens validas */
    long long total;
    bool valid;
    char err[256];
};
bool bundle_id_valid(const char *id);
bool image_name_valid(const char *name);
int parse_manifest(const char *buf, size_t len, struct bundle *b, char *err, size_t errsz);
int bundle_load(const char *dir, const char *expect_id, struct bundle *b);
void bundle_free(struct bundle *b);
int bundles_scan(struct bundle **out, size_t *n);
void bundles_free(struct bundle *v, size_t n);
int kam_lock(void);
struct bundle *bundle_find(struct bundle *v, size_t n, const char *id);
int cmd_list_bundles(void);
int cmd_remove_bundle(const char *id);
int cmd_set_bundle(const char *id);
int cmd_set_mode(const char *mode);
int cmd_set_background(const char *spec);
int config_satisfiable(const struct prefs *c, struct bundle *v, size_t n, bool verbose);

/* import.c */
struct kawall_info {
    struct bundle meta;   /* id, nome, versao, contagem e tamanho */
    long skipped;
    char skipped_example[256];
};
int kawall_inspect(const char *path, struct kawall_info *ki, char *err, size_t errsz);
int cmd_import_bundle(const char *path);
int cmd_list_available(const char *dir);

/* apply.c */
int theme_mount_check(char *err, size_t errsz);
int apply_now(bool announce);
int cmd_randomize(void);
void retone_now(void);

/* reload.c */
int cmd_reload_confs(void);

/* components.c */
void helper_version(const char *path, char *out, size_t sz);
int unit_revision(const char *path);
int cmd_status(void);
int cmd_install_helper(void);
int cmd_install_service(void);
int cmd_enable_service(void);
int cmd_disable_service(void);
int cmd_start_service(void);
int cmd_stop_service(void);
int cmd_uninstall(const char *component);
int cmd_update(void);
bool service_installed(void);
bool helper_installed(void);

#endif
