# AGENTS.md: contexto do projeto

Guia para agentes de código e colaboradores. Ele resume a especificação
original (que não é publicada) e as decisões tomadas depois dela. Leia antes
de alterar qualquer coisa; o [`README.md`](README.md) é a documentação de uso.
As regras de desenvolvimento (por exemplo, **sem compatibilidade com versões
anteriores**) estão em [`RULES.md`](RULES.md).

## 1. O que é

O **Kawaii Arch Theme** é um tema GRUB para Arch Linux derivado do
[KawaiiGRUB](https://github.com/Gabbar-v7/KawaiiGRUB) (MIT), com a barra de
carregamento inspirada no tema CyberRe. Ele evoluiu de "tema + wallpapers em `/boot` +
script" para um sistema modular:

| Termo | O que é | Onde fica |
|---|---|---|
| Tema | `theme.txt`, fontes `.pf2`, `tones/{dark,light}/` (molduras, seleção, barra, cores), `icon-sets/{dark,light}/` + `icons/` (ativo), `logos/<distro>-<tom>.png`, `background.png` (único wallpaper ativo) e `fallback.png` | `grub-theme/` → `/boot/grub/themes/kawaii-arch-theme/` |
| Manager | `kawaii-arch-manager`, binário C (libarchive) | `manager/` → `/usr/bin/` |
| Helper | `grub-random-bg.sh`: escolhe e aplica um wallpaper | `helper/` → `/usr/lib/kawaii-arch-manager/` |
| Serviço | `grub-random-bg.service`, oneshot no boot | `systemd/*.in` → `/usr/lib/systemd/system/` |
| Bundle | coleção de wallpapers: `manifest.conf` + `backgrounds/*.png` | `bundles/<id>/` (local, não versionado) → `/var/lib/kawaii-arch-manager/bundles/<id>/` |
| `.kawall` | tar de um bundle, com raiz `<id>/` | gerado por `tools/make-kawall.sh` |
| Payload | cópia local do helper, do modelo da unidade, do modelo `preferences.conf` e dos `.kawall` de `bundles/`, usada pelo manager para instalar/atualizar | `/usr/share/kawaii-arch-manager/payload/` |
| Preferências | `preferences.conf`: MODE, SELECTED_BUNDLE, SELECTED_BACKGROUND, LOGO, MENU_BOX, TONE; **fonte da verdade** (o `theme.txt` é derivado) | `config/preferences.conf` (modelo comentado) → `/var/lib/kawaii-arch-manager/config/` |
| Dados | `config/preferences.conf`, `config/paths.conf` (caminhos, gerado), `state/last-background`, locks | `/var/lib/kawaii-arch-manager/` |

## 2. Regras que não podem ser quebradas

Herdadas da especificação original (e cobertas pelos testes):

1. **Nenhum componente opcional é obrigatório.** O tema funciona sem manager,
   helper, serviço ou bundles, com o `background.png` padrão. A ausência de
   um componente nunca é erro fatal.
2. **Independência:** o helper funciona sem o manager (lê a configuração e os
   bundles direto); o manager funciona sem helper e sem serviço; o serviço
   exige o helper.
3. **`/boot` guarda um único wallpaper ativo** (`background.png`) e o
   `fallback.png`. A biblioteca fica em `/var/lib`. O `theme.txt` sempre usa
   `desktop-image: "background.png"`.
4. **Troca atômica:** copiar para `background.png.tmp` no mesmo diretório,
   validar, `sync`, `rename(2)`. Nunca mover nem alterar o original do
   bundle. Uma falha preserva o wallpaper válido anterior.
   `last-background` só é atualizado depois do sucesso.
5. **Nunca rodar `grub-mkconfig` para trocar wallpaper.** O instalador só o
   roda quando `/etc/default/grub` muda ou o `grub.cfg` não referencia o tema
   ou as fontes.
6. **Não escrever num `/boot` desmontado:** `paths.conf` guarda
   `EXPECTED_MOUNT`; o helper confere a montagem e o `fstab`; a unidade usa
   `RequiresMountsFor=`.
7. **O serviço só é habilitado com consentimento explícito**
   (`--enable-service` ou pergunta). `--yes` só preserva o estado anterior.
8. **Bundles são não confiáveis:** validação em duas passagens, sem path
   traversal, links ou arquivos especiais, com limites de tamanho e
   quantidade, nada executado, instalação atômica (`renameat2`).
9. **SemVer independente por componente, sem downgrade automático.** Versão
   inválida conta como `0.0.0`.
10. **Preservar dados do usuário:** atualizar ou reinstalar não apaga bundles
    nem `preferences.conf`. Só `--fresh` (com confirmação) e
    `--uninstall --purge` apagam dados.
11. **Instalador idempotente:** uma segunda execução não altera nada sem
    motivo, não roda `daemon-reload` sem necessidade e não muda o estado do
    serviço.
12. **Todas as perguntas vêm antes de qualquer alteração.**
13. **Visual minimalista:** só o menu, o logo opcional e a barra de tempo.
    Mudanças visuais exigem pedido explícito (ver o histórico abaixo).

## 3. Histórico após a especificação

A especificação original descrevia a arquitetura de tema 2.0.0, manager
1.0.0, helper 2.0.0 e unidade rev 2. Depois disso, a pedido do mantenedor:

1. **Caixa do terminal "liquid glass"** (tema 2.1.0). Os `terminal_box_*.png`
   deixaram de ser preto opaco e viraram um vidro escuro **neutro**
   (RGB 10,10,12) com **72% de opacidade**, contorno claro (mais forte em
   cima), reflexo interno e sombra externa leve. A primeira versão tinha
   tom azulado e 62%, ajustados só para um wallpaper; foi refeita porque o
   wallpaper é dinâmico. Os 72% foram calibrados nos 49 wallpapers dos
   bundles originais para que o texto do GRUB (`#AAAAAA`) mantenha contraste
   de ~3,5:1 até sobre branco puro (~7:1 no caso típico). Limite: o GRUB não
   desfoca nem adapta a caixa ao wallpaper; uma imagem fixa serve para
   todos.
2. **`--fresh` com `--keep-config` / `--no-keep-config`** (tema 2.1.0).
   Pergunta feita **só** no `--fresh` (as outras execuções já preservam a
   configuração), com padrão "sim". Mantém o arquivo de preferências (hoje `preferences.conf`),
   `last-background` e o wallpaper ativo (no modo `fixed`, a imagem fixa).
   Inclui automaticamente o bundle de `bundles/` usado pela configuração e
   preserva o bundle importado de que ela depende. Os dados ficam numa
   guarda temporária ao lado de `/var/lib/kawaii-arch-manager` durante o wipe.
3. **Contorno do menu de boot** (tema 2.2.0). `boot_menu_box_*.png` via
   `menu_pixmap_style`: a mesma geometria e o mesmo contorno do terminal,
   **sem preenchimento** (o menu já é transparente; não há `menu_c`). Uma
   cópia literal das bordas do terminal criaria uma faixa escura de ~13 px.
   Como o GRUB desenha a moldura **dentro** dos limites e reserva 16 px por
   lado, os limites do `boot_menu` foram expandidos:
   `left = 5%-16`, `top = 36%-16`, `width = 522` (490 + 32),
   `height = 44%+32`. Assim, as entradas ficam onde estavam.
4. **`tools/make_glass.py`**: gera as duas molduras e reproduz os PNGs atuais
   byte a byte. É uma ferramenta extra, não versionada.
5. **Preparação para publicação** (tema 2.2.1, manager 1.1.0):
   - licença MIT, mantendo o aviso do KawaiiGRUB; `THIRD_PARTY.md` e
     `licenses/` (OFL das fontes);
   - **bundles fora do repositório** (os wallpapers originais são arte de
     terceiros, sem licença de redistribuição); `bundles/` fica só local, com
     um README;
   - novo wallpaper padrão, de autoria do mantenedor;
   - removidas 8 fontes `.pf2` sem uso (ficaram `PublicSans_Bold_21` e
     `terminus-16`);
   - o manager passou a importar **pastas extraídas**
     (`--import-bundle PASTA`), com as mesmas regras de segurança;
   - os testes geram o próprio pacote de teste com bundles sintéticos;
   - a especificação original foi para o `.gitignore`.
6. **Tom adaptável e logo por distribuição** (tema 3.0.0, manager 1.2.0,
   helper 2.1.0). Wallpapers claros deixavam ilegíveis o texto, os ícones
   brancos, a faixa da barra e a palavra "arch" do logo. Decisões do
   mantenedor: nada de configuração por bundle (`tones.conf`), cache ou
   geração em tempo de boot; só dois tons com arquivos fixos, escolhidos no
   momento em que o wallpaper é definido.
   - **Medição:** `kawaii-arch-manager --tone ARQ` (`manager/src/tone.c`,
     zlib) decodifica o PNG e amostra o menu (x 5–27%, y 36–64%) e o logo
     (x 5–19%, y 88–97%). Escolhe `light` se a média geométrica de
     (L + 0,05) passa de √(1,05 × (0,0111 + 0,05)), ou seja, quando o texto
     `#1c1c22` dá mais contraste médio que o branco. Calibrado nos 44
     wallpapers locais (8 ficam `light`). Não depende de `paths_init`.
   - **Aplicação:** só no helper (`apply_tone`, também via `--retone`).
     O manager sem helper instalado roda `bash payload/grub-random-bg.sh
     --retone`, depois de soltar o lock. O instalador roda o helper do
     pacote no fim (`apply_theme_tone`, depois dos componentes, porque o
     manager pode ter acabado de ser instalado). Sem o manager: `dark`.
   - **`theme.txt`:** o helper reescreve **só** as linhas não comentadas
     (e as `#[logo] ` do bloco do logo desativado) com `"tones/dark|light/"`,
     `item_color`, `selected_item_color` e `file = "logos/..."`. As cores
     vêm de `tones/<tom>/colors.conf`. A escrita é atômica e só acontece se
     algo mudar. O `theme.txt` do pacote é o tom `dark` e funciona sozinho.
   - **Ícones:** o GRUB só lê `<tema>/icons/` (`icon_manager.c`, sem
     subpastas; `icondir` fica no `grub.cfg`), e o `/boot` FAT não tem
     links nem troca atômica de pastas. Por isso o helper apaga
     `icons/.tone`, copia `icon-sets/<tom>/` arquivo a arquivo (sem
     reescrever os iguais) e grava `.tone` por último. O pacote traz
     `icons/` = `icon-sets/dark/` com `.tone` = `dark`.
   - **Logo:** `logos/<id>-<tom>.png`; o `ID` e cada `ID_LIKE` de
     `/etc/os-release` (via `conf_get`), com fallback `arch`.
   - O preenchimento do terminal é igual nos dois tons; mudam o contorno e a
     sombra/brilho externo (`make_glass.py --tone light`). A seleção, a
     barra e os ícones `light` vêm de `tools/make_light_assets.py`.
   - Mudança de regra: antes o helper "nunca alterava o `theme.txt`".
7. **Contorno do menu e logo pelo manager** (tema 3.1.0, manager 1.3.0,
   helper 2.1.1). O contorno do menu passou a ser opcional (padrão ligado),
   com `--menu-box`/`--no-menu-box` no instalador e
   `kawaii-arch-manager --menu-box on|off`; o logo ganhou
   `kawaii-arch-manager --logo on|off`.
   - Referência de tamanho: os `select_*` são idênticos aos do KawaiiGRUB, e
     as métricas das entradas não mudaram. Só os limites do `boot_menu`
     mudaram:
     - KawaiiGRUB: 7%, 41%, 40%, 65%;
     - este tema antes do contorno: 5%, 36%, 490, 44%;
     - com o contorno: +16 px por lado.
     Sem o contorno, voltam os limites de antes do contorno, e as entradas
     não se mexem.
   - Mecanismo: dois blocos dentro do `boot_menu`, `menu-box` (limites +16
     e `menu_pixmap_style`) e `no-menu-box` (limites originais). Só um fica
     ativo; o outro tem as linhas com o prefixo `#[menu] ` na coluna 0. O
     GRUB aceita comentários dentro de componentes (`read_object` em
     `theme_loader.c`). O logo usa o mesmo esquema (`#[logo] `).
   - Estado originalmente só no `theme.txt` (desde o item 8, vem de
     `LOGO`/`MENU_BOX` no `preferences.conf`). As funções genéricas são `block_has`, `block_active` e
     `block_set` no `install.sh` e `manager/src/layout.c` no manager.
   - O helper atualiza o tom também nas linhas `#[menu] `, para o contorno
     religar no tom certo.
8. **Preferências centralizadas** (tema 3.1.1, manager 1.4.0, helper 2.2.0).
   Todas as escolhas do usuário ficam em
   `/var/lib/kawaii-arch-manager/config/preferences.conf` (substitui o
   `backgrounds.conf`, sem migração: ver `RULES.md`). O serviço fica fora.
   - Chaves: `MODE`, `SELECTED_BUNDLE`, `SELECTED_BACKGROUND`, `LOGO`,
     `MENU_BOX` (`on|off`), `TONE` (`auto|dark|light`). O modelo comentado
     `config/preferences.conf` é a fonte única dos padrões; o instalador o
     copia na primeira instalação e para o payload.
   - Gravação no lugar: o manager (`prefs_save`) e o instalador
     (`pref_set`) trocam só o valor da linha da chave; comentários, ordem e
     chaves desconhecidas ficam. Chave ausente vai para o fim.
   - `kawaii-arch-manager --reload-confs` (`reload.c`): valida tudo antes
     (valor inválido ou bundle/imagem ausente em `set`/`fixed` aborta sem
     aplicar; chave desconhecida só avisa), aplica `LOGO`/`MENU_BOX` numa
     escrita (`layout_apply`), aplica um wallpaper só se o ativo não
     corresponde ao modo (`fixed`/`set`; `global`/`balanced` não sorteiam)
     e reaplica o tom (`retone_now`: helper instalado ou do payload).
   - `--logo`/`--menu-box` gravam a preferência e aplicam. O instalador lê
     `LOGO`/`MENU_BOX` como padrão das perguntas e grava as respostas; o
     `--fresh` sem manter as preferências volta aos padrões.
   - `TONE`: o helper força `dark`/`light`; `auto` mede o wallpaper.
   - `--status` mostra as preferências e avisa quando o `theme.txt` difere.

## 4. Convenções

- **Idioma:** documentação e mensagens em português. O README usa acentos;
  scripts, código C e mensagens de terminal ficam em ASCII (sem acentos).
- **Bash:** `set -euo pipefail` (o helper usa `set -uo pipefail` e trata cada
  erro); nunca `source` em arquivos de configuração (use os parsers
  `conf_get`); escrita atômica (`write_atomic`, `.tmp` + `mv`); validação de
  PNG por cabeçalho (`png_ok`).
- **C:** C11, `-Wall -Wextra` sem avisos; `openat` com `O_NOFOLLOW`/`O_EXCL`
  para conteúdo não confiável; códigos de saída `KAM_*` (0 a 6).
- **Sandbox:** todos os caminhos aceitam o prefixo `KAWAII_ROOT` (e
  `KAWAII_SYSTEMCTL`, `KAWAII_SKIP_ROOT_CHECK`) para os testes. Nunca teste
  no sistema real.
- **GRUB:** PNG só de 8/16 bits, cinza/RGB/RGBA, sem paleta, não
  entrelaçado. Tamanhos e posições no `theme.txt` aceitam expressões como
  `5%-16`.

## 5. Testes

```bash
tests/run-tests.sh [--keep]
```

- Todo comportamento novo ou corrigido precisa de teste. A suíte deve
  terminar com 0 falhas.
- Os testes do instalador usam um pacote copiado para a sandbox (`$PKGT`),
  com bundles sintéticos (`alpha`, `beta`, `gamma`); não dependem de
  `bundles/` do repositório.
- O teste "/boot contém só um wallpaper ativo + fallback" ignora os PNGs de
  `icons/`, `icon-sets/`, `tones/` e `logos/`. PNGs novos na raiz do tema
  precisam entrar no filtro.
- Os testes de tom geram PNGs sólidos (`mksolid`) e usam uma sandbox
  própria (`$R2`) com o tema completo do pacote.
- Testes que conferem versões: `--version` do manager (duas vezes) e
  `helper --version`.

## 6. Versões

- **Tema** (`grub-theme/VERSION`): suba a cada mudança em `grub-theme/`, ou
  uma atualização normal não aplica os arquivos novos (o instalador só
  substitui o tema se a versão do pacote for maior).
- **Manager** (`VERSION` no `manager/Makefile`), **helper** (`VERSION=` no
  script), **unidade** (revisão) e **bundles** (`manifest.conf`): cada um na
  sua origem.
- Atualize também a tabela de componentes do README e os testes que fixam
  versões.
- Patch para correções e ajustes; minor para funções ou recursos visuais
  novos compatíveis; major para mudanças incompatíveis.

Versões atuais: tema 3.1.1, manager 1.4.0, helper 2.2.0, unidade rev 2.

## 7. Armadilhas conhecidas

- `menu_pixmap_style` e `terminal-box`: as molduras são desenhadas **dentro**
  da área declarada, e o padding é o tamanho dos tiles (16 px).
- Os limites do `boot_menu` existem em dois blocos (`menu-box` com +16 px
  por lado e `no-menu-box` sem): ao mudar posição ou tamanho, altere os
  dois. O prefixo `#[menu] `/`#[logo] ` fica na coluna 0, antes da
  indentação, e os marcadores `# >>> nome`/`# <<< nome` precisam ficar
  sozinhos na linha.
- As fontes `.pf2` precisam ficar na **raiz** do tema: o
  `/etc/grub.d/00_header` só carrega as de lá, e o `grub.cfg` gerado lista
  todas. Mudar o conjunto de fontes exige regenerar o `grub.cfg` (o
  instalador detecta isso).
- `progress_bar` com `highlight_style` (mesmo sem `bar_style`) usa só
  imagens: `fg_color`, `bg_color` e `border_color` são ignorados (ver
  `gui_progress_bar.c` do GRUB). E `fill_rect` do GRUB não mistura alfa: cores
  com transparência saem opacas. Para mudar a barra, altere o PNG.
- Caminhos com subpasta funcionam em todo o `theme.txt` (molduras,
  `file =`), exceto os ícones, que o GRUB só procura em `icons/`.
- Ao mudar `icon-sets/dark/`, atualize também `icons/` do pacote, que é o
  conjunto padrão (o teste "pacote: icons/ = icon-sets/dark" confere). Não
  edite à mão o `theme.txt` instalado nas linhas gerenciadas pelo tom: o
  helper as reescreve.
- O nome de fonte no `theme.txt` é o nome interno do PF2 (por exemplo,
  `Public Sans Bold 21`, `Terminus Regular 16`), não o nome do arquivo.
- O instalador só aceita bundles em `bundles/<id>/` com o nome da pasta igual
  ao `ID`; o manager aceita qualquer nome de pasta (o ID vem do manifesto).
- `background.png` e `fallback.png` do pacote são o mesmo arquivo; o
  instalador não copia o `background.png` do pacote quando já existe um
  wallpaper ativo.

## 8. Licenças

- Código e arquivos próprios: MIT (`LICENSE`, com os avisos de Gabbar e
  rafaelmotacr).
- Terceiros: ver `THIRD_PARTY.md`. Não adicione arte, ícones ou fontes sem
  registrar a origem e a licença lá. Não versione wallpapers sem licença de
  redistribuição.
