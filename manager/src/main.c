/* kawaii-arch-manager - interface de linha de comando */
#include "kam.h"

#include <getopt.h>
#include <locale.h>
#include <stdlib.h>
#include <string.h>

static void usage(FILE *f)
{
    fprintf(f,
"Uso: %s COMANDO [OPCOES]\n"
"\n"
"Gerencia o Kawaii Arch Theme do GRUB: bundles de wallpapers, modo de\n"
"selecao, Background Helper e servico systemd.\n"
"\n"
"Consulta (usuario comum):\n"
"  --version                     versao do manager\n"
"  --status                      componentes, versoes, configuracao e servico\n"
"  --list-bundles                bundles instalados\n"
"  --list-available-bundles [DIR]  pacotes .kawall disponiveis localmente\n"
"                                (padrao: /usr/share/kawaii-arch-manager/payload/bundles)\n"
"  --tone ARQUIVO.png            tom do wallpaper para o tema: dark (escuro,\n"
"                                texto claro) ou light (claro, texto escuro)\n"
"\n"
"Bundles e selecao (root):\n"
"  --import-bundle ARQ|DIR       valida e importa um pacote .kawall ou a pasta\n"
"                                de um bundle (manifest.conf + backgrounds/)\n"
"  --remove-bundle ID            remove um bundle (pede confirmacao)\n"
"  --set-bundle ID               bundle usado no modo 'set'\n"
"  --set-mode MODO               fixed | set | global | balanced\n"
"  --set-background ID/ARQUIVO   define e aplica um wallpaper fixo (modo fixed)\n"
"  --randomize                   seleciona e aplica um wallpaper agora\n"
"\n"
"Preferencias (/var/lib/kawaii-arch-manager/config/preferences.conf):\n"
"  --reload-confs                aplica o arquivo de preferencias editado (root)\n"
"  Os comandos abaixo e os de selecao tambem gravam nele.\n"
"\n"
"Visual do tema (root; vale a partir do proximo boot):\n"
"  --logo on|off                 exibe/oculta o logo da distribuicao\n"
"  --menu-box on|off             exibe/oculta o contorno de vidro do menu\n"
"\n"
"Componentes (root):\n"
"  --update                      atualiza helper, servico e bundles instalados\n"
"                                a partir do payload local (sem downgrade)\n"
"  --install-helper              instala/atualiza o Background Helper\n"
"  --install-service             instala a unidade systemd (exige o helper;\n"
"                                nao a habilita)\n"
"  --enable-service              habilita e executa o servico\n"
"  --disable-service             para e desabilita o servico\n"
"  --start-service               executa o servico uma vez\n"
"  --stop-service                para o servico\n"
"  --uninstall COMPONENTE        service | helper | manager | data\n"
"                                (bundles e configuracao so saem com 'data')\n"
"\n"
"Opcoes:\n"
"  -y, --yes                     responde 'sim' as confirmacoes\n"
"      --force                   permite reinstalar a mesma versao ou downgrade\n"
"  -n, --dry-run                 apenas valida/simula (import, randomize, update,\n"
"                                logo, menu-box, reload-confs)\n"
"  -h, --help                    esta ajuda\n"
"\n"
"Codigos de saida: 0 sucesso, 1 falha operacional, 2 argumento invalido,\n"
"3 bundle/configuracao invalido, 4 conflito, 5 sem privilegios ou particao\n"
"indisponivel, 6 cancelado pelo usuario.\n",
            KAM_PROG);
}

enum cmd {
    C_NONE = 0, C_VERSION, C_STATUS, C_LIST, C_LIST_AVAIL, C_IMPORT, C_REMOVE, C_SET_BUNDLE,
    C_SET_MODE, C_SET_BG, C_RANDOMIZE, C_UPDATE, C_INST_HELPER, C_INST_SERVICE, C_ENABLE,
    C_DISABLE, C_START, C_STOP, C_UNINSTALL, C_TONE, C_LOGO, C_MENU_BOX, C_RELOAD, C_HELP
};

int main(int argc, char **argv)
{
    setlocale(LC_CTYPE, "");
    static const struct option opts[] = {
        {"version", no_argument, 0, C_VERSION},
        {"status", no_argument, 0, C_STATUS},
        {"list-bundles", no_argument, 0, C_LIST},
        {"list-available-bundles", optional_argument, 0, C_LIST_AVAIL},
        {"import-bundle", required_argument, 0, C_IMPORT},
        {"remove-bundle", required_argument, 0, C_REMOVE},
        {"set-bundle", required_argument, 0, C_SET_BUNDLE},
        {"set-mode", required_argument, 0, C_SET_MODE},
        {"set-background", required_argument, 0, C_SET_BG},
        {"randomize", no_argument, 0, C_RANDOMIZE},
        {"update", no_argument, 0, C_UPDATE},
        {"install-helper", no_argument, 0, C_INST_HELPER},
        {"install-service", no_argument, 0, C_INST_SERVICE},
        {"enable-service", no_argument, 0, C_ENABLE},
        {"disable-service", no_argument, 0, C_DISABLE},
        {"start-service", no_argument, 0, C_START},
        {"stop-service", no_argument, 0, C_STOP},
        {"uninstall", required_argument, 0, C_UNINSTALL},
        {"tone", required_argument, 0, C_TONE},
        {"logo", required_argument, 0, C_LOGO},
        {"menu-box", required_argument, 0, C_MENU_BOX},
        {"reload-confs", no_argument, 0, C_RELOAD},
        {"help", no_argument, 0, C_HELP},
        {"yes", no_argument, 0, 'y'},
        {"force", no_argument, 0, 'f'},
        {"dry-run", no_argument, 0, 'n'},
        {0, 0, 0, 0},
    };
    enum cmd cmd = C_NONE;
    const char *arg = NULL;
    int c;
    opterr = 0;
    while ((c = getopt_long(argc, argv, "+yhnV", opts, NULL)) != -1) {
        switch (c) {
        case 'y': O.yes = true; continue;
        case 'f': O.force = true; continue;
        case 'n': O.dry_run = true; continue;
        case 'h': c = C_HELP; break;
        case 'V': c = C_VERSION; break;
        case '?':
            fprintf(stderr, "%s: opcao invalida ou sem argumento: %s (use --help)\n", KAM_PROG,
                    argv[optind - 1]);
            return KAM_EUSAGE;
        default: break;
        }
        if (cmd != C_NONE && cmd != (enum cmd)c) {
            fprintf(stderr, "%s: informe apenas um comando por vez (use --help)\n", KAM_PROG);
            return KAM_EUSAGE;
        }
        cmd = (enum cmd)c;
        arg = optarg;
        /* --list-available-bundles DIR (argumento opcional separado) */
        if (c == C_LIST_AVAIL && !arg && optind < argc && argv[optind][0] != '-')
            arg = argv[optind++];
    }
    if (optind < argc) {
        fprintf(stderr, "%s: argumento inesperado: %s (use --help)\n", KAM_PROG, argv[optind]);
        return KAM_EUSAGE;
    }
    if (cmd == C_HELP) {
        usage(stdout);
        return KAM_OK;
    }
    if (cmd == C_VERSION) {
        printf("%s %s\n", KAM_PROG, KAM_VERSION);
        return KAM_OK;
    }
    if (cmd == C_TONE)
        return cmd_tone(arg);   /* somente leitura; nao depende da instalacao */
    if (cmd == C_NONE) {
        usage(stderr);
        return KAM_EUSAGE;
    }
    int rc = paths_init();
    if (rc)
        return rc;

    switch (cmd) {
    case C_STATUS: return cmd_status();
    case C_LIST: return cmd_list_bundles();
    case C_LIST_AVAIL: return cmd_list_available(arg);
    case C_IMPORT: return cmd_import_bundle(arg);
    case C_REMOVE: return cmd_remove_bundle(arg);
    case C_SET_BUNDLE: return cmd_set_bundle(arg);
    case C_SET_MODE: return cmd_set_mode(arg);
    case C_SET_BG: return cmd_set_background(arg);
    case C_RANDOMIZE: return cmd_randomize();
    case C_UPDATE: return cmd_update();
    case C_INST_HELPER: return cmd_install_helper();
    case C_INST_SERVICE: return cmd_install_service();
    case C_ENABLE: return cmd_enable_service();
    case C_DISABLE: return cmd_disable_service();
    case C_START: return cmd_start_service();
    case C_STOP: return cmd_stop_service();
    case C_UNINSTALL: return cmd_uninstall(arg);
    case C_LOGO: return cmd_set_logo(arg);
    case C_MENU_BOX: return cmd_set_menu_box(arg);
    case C_RELOAD: return cmd_reload_confs();
    default: return KAM_EUSAGE;
    }
}
