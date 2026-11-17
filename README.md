# Kawaii Arch Theme

Tema GRUB minimalista para Arch Linux, derivado do
[KawaiiGRUB](https://github.com/Gabbar-v7/KawaiiGRUB). Os wallpapers ficam em
**bundles** fora da partição de boot e podem trocar a cada inicialização.
O gerenciamento é feito por um programa de linha de comando compilado, o
**Kawaii Arch Manager**.

O repositório traz só o wallpaper padrão. Os bundles são montados por você,
com imagens que você tenha direito de usar (ver
[Bundles de wallpapers](#bundles-de-wallpapers)).

<!-- Captura de tela: adicione docs/screenshot.png e descomente a linha abaixo. -->
<!-- ![Kawaii Arch Theme](docs/screenshot.png) -->

- **Um único wallpaper em `/boot`.** A biblioteca de wallpapers fica em
  `/var/lib/kawaii-arch-manager/bundles/`, e o tema usa só `background.png`.
- **Troca automática opcional** a cada boot, com quatro modos de seleção.
- **Visual "liquid glass":** caixa do terminal em vidro escuro translúcido e
  contorno de vidro no menu de boot, pensados para combinar com qualquer
  wallpaper.
- **Tom adaptável:** em wallpapers claros, o texto, os ícones, as bordas, a
  seleção, a barra de tempo e o logo ficam escuros; nos escuros, claros.
- **Logo da distribuição:** escolhido pelo `/etc/os-release`, com o do Arch
  como padrão.
- **Nada é obrigatório:** sem nenhum componente opcional e sem bundles, o
  tema funciona com o wallpaper padrão.

## Componentes

| Componente | Versão | Instalado em | Obrigatório |
|---|---|---|---|
| Tema GRUB | 3.0.0 | `/boot/grub/themes/kawaii-arch-theme/` | sim |
| Kawaii Arch Manager (C, binário nativo) | 1.2.0 | `/usr/bin/kawaii-arch-manager` | não |
| Background Helper (bash) | 2.1.0 | `/usr/lib/kawaii-arch-manager/grub-random-bg.sh` | não |
| Serviço systemd | rev 2 | `/usr/lib/systemd/system/grub-random-bg.service` | não (exige o helper) |
| Bundles de wallpapers (não incluídos no repositório) | por bundle | `/var/lib/kawaii-arch-manager/bundles/<id>/` | não |

Cada componente tem sua própria versão (SemVer) e é atualizado de forma
independente, sem downgrade automático.

## Requisitos

- GRUB 2 com saída gráfica (`gfxterm`). O instalador detecta `/boot/grub` ou
  `/boot/grub2` e aceita `--grub-dir`.
- `bash`, `coreutils` e `systemd` (este último só para o serviço).
- Para compilar o manager: `gcc`, `make`, `libarchive` e `zlib`. No Arch:
  `pacman -S --needed base-devel libarchive zlib`. Sem eles, o instalador
  avisa e continua com o tema e os demais componentes (o tom do tema fica
  sempre escuro, porque é o manager que mede a claridade do wallpaper).
- Só para desenvolvimento: `python3` (testes) e Python 3 com Pillow e NumPy
  (`tools/make_glass.py` e `tools/make_light_assets.py`).

## Instalação rápida

```bash
git clone https://github.com/rafaelmotacr/kawaii-arch-theme.git
cd kawaii-arch-theme
# opcional: coloque seus bundles em bundles/<id>/ (ver bundles/README.md)
sudo ./install.sh
```

O instalador faz todas as perguntas antes de alterar qualquer coisa. Para
aceitar os padrões sem perguntas: `sudo ./install.sh --yes`.

Num clone novo, a pasta `bundles/` só tem um README. Sem bundles, o tema usa
o wallpaper padrão (`grub-theme/background.png`), e a troca automática não
tem o que sortear até você
[adicionar bundles](#bundles-de-wallpapers), na instalação ou depois.

## Instalador (`install.sh`)

```bash
sudo ./install.sh                        # interativo
sudo ./install.sh --yes                  # padrões: instala os 3 componentes e
                                         # todos os bundles da pasta bundles/; o
                                         # serviço só é habilitado se já estava
                                         # habilitado ou com --enable-service
sudo ./install.sh --bundles meu-bundle,2 # só esses bundles da pasta bundles/
sudo ./install.sh --no-bundles           # nenhum bundle: wallpaper padrão
sudo ./install.sh --fresh                # instalação limpa (ver abaixo)
sudo ./install.sh --uninstall [--purge]  # remoção (ver abaixo)
```

Opções:

| Opção | Efeito |
|---|---|
| `--yes` | responde com o padrão de cada pergunta |
| `--with-manager` / `--without-manager` | instala ou recusa o manager |
| `--with-helper` / `--without-helper` | instala ou recusa o Background Helper |
| `--with-service` / `--without-service` | instala ou recusa o serviço (exige o helper) |
| `--no-components` | recusa os três componentes opcionais |
| `--enable-service` | habilita o serviço (consentimento explícito) |
| `--bundles all\|none\|ID,...` | bundles da pasta local `bundles/` a instalar (aceita IDs ou os números da lista) |
| `--no-bundles` | o mesmo que `--bundles none` |
| `--logo` / `--no-logo` | exibe ou oculta o logo da distribuição abaixo do menu |
| `--grub-dir DIR` | diretório do GRUB (padrão: detectado) |
| `--fresh` | instalação limpa |
| `--keep-config` / `--no-keep-config` | só com `--fresh`: mantém ou descarta a configuração de wallpapers |
| `--uninstall [--purge]` | remove o tema e os componentes |

### Reinstalação e atualização

Rodar o instalador de novo é seguro, porque ele é idempotente:

- nada é reinstalado sem necessidade, e não há downgrade;
- o tema só é substituído quando a versão do pacote (`grub-theme/VERSION`) é
  maior que a instalada; o wallpaper ativo é preservado;
- a unidade systemd só é reescrita quando o conteúdo muda, e só nesse caso
  roda `daemon-reload`;
- `backgrounds.conf` e os bundles instalados nunca são sobrescritos;
- `grub-mkconfig` só roda quando `/etc/default/grub` foi alterado, ou quando
  o `grub.cfg` não referencia o tema ou suas fontes. Trocar de wallpaper
  nunca exige isso.

Quando altera `/etc/default/grub`, o instalador salva um backup em
`/etc/default/grub.bak-kawaii-arch-theme` (só na primeira vez).

### Instalação limpa (`--fresh`)

Apaga tudo o que foi instalado e reinstala a partir da pasta do projeto, como
numa máquina nova: tema (inclusive o wallpaper ativo e qualquer alteração no
`theme.txt`), manager e payload, helper, unidade systemd e
`/var/lib/kawaii-arch-manager` (bundles, `backgrounds.conf` e estado). A
exceção é a configuração de wallpapers, se você escolher mantê-la.

- Todas as perguntas e a confirmação vêm **antes** de apagar qualquer coisa.
  O instalador lista o que será removido e aponta os bundles instalados que
  não estão na pasta local `bundles/` (por exemplo, os importados com
  `--import-bundle`), porque eles serão perdidos. Para mantê-los, copie as
  pastas deles de `/var/lib/kawaii-arch-manager/bundles/` para `bundles/`
  antes de rodar o `--fresh`. A confirmação é `[s/N]`; com `--yes`, o próprio
  `--fresh` vale como confirmação.
- **Manter a configuração de wallpapers.** Se existir um `backgrounds.conf`,
  o instalador mostra o modo atual e pergunta se ele deve ser mantido
  (`[S/n]`; com `--yes`, mantém). Ao manter:
  - `backgrounds.conf` (modo, bundle do modo `set`, wallpaper do modo `fixed`)
    e `state/last-background` voltam intactos; `paths.conf` é regenerado;
  - o wallpaper ativo continua o mesmo; no modo `fixed`, é o wallpaper fixo
    escolhido;
  - se a configuração usa um bundle da pasta `bundles/` que não foi
    selecionado, ele é incluído automaticamente; se usa um bundle importado,
    esse bundle é preservado.

  `--keep-config` e `--no-keep-config` decidem sem perguntar. Se o
  instalador falhar no meio, ele informa onde guardou a configuração.
- As demais perguntas usam os padrões de uma instalação nova: o serviço só
  volta habilitado com `--enable-service` ou se você escolher.
- `/etc/default/grub` e `grub.cfg` são preservados.
- Combina com as demais opções. Não combina com `--uninstall`.

### Desinstalação

```bash
sudo ./install.sh --uninstall           # remove serviço, helper, manager e tema
sudo ./install.sh --uninstall --purge   # também apaga bundles, configuração e estado
```

Sem `--purge`, os dados em `/var/lib/kawaii-arch-manager` são preservados.
O instalador oferece comentar o `GRUB_THEME` em `/etc/default/grub` e
regenerar o `grub.cfg`.

## Bundles de wallpapers

O repositório não inclui bundles: monte os seus com imagens que você tenha
direito de usar (ver [`THIRD_PARTY.md`](THIRD_PARTY.md)). Um bundle é uma
coleção de wallpapers com um manifesto:

```text
meu-bundle/
├── manifest.conf       ID="meu-bundle"  VERSION="1.0.0"  [NAME] [AUTHOR] [DESCRIPTION]
└── backgrounds/*.png
```

- **ID:** `[a-z0-9][a-z0-9_-]{0,63}`, permanente.
- **VERSION:** SemVer.
- **NAME, AUTHOR, DESCRIPTION:** opcionais (sem `NAME`, o ID é exibido).
- **Imagens:** PNG compatíveis com o leitor do GRUB (8 ou 16 bits;
  cinza/RGB/RGBA; sem paleta; não entrelaçadas). Imagens incompatíveis são
  ignoradas com aviso. A quantidade é sempre contada, e a numeração pode ter
  lacunas.
- **Tamanho:** prefira a resolução da sua tela. Imagens muito grandes
  deixam o GRUB lento para desenhar o menu.

Há três formas de adicionar bundles:

1. **Na instalação:** coloque as pastas em `bundles/<id>/`, dentro do clone
   (o nome da pasta precisa ser igual ao `ID`; o git ignora essa pasta), e
   rode o `install.sh`. Ele lista os bundles e
   pergunta quais instalar (Enter = todos, `n` = nenhum, ou números/IDs).
   Bundles já instalados com versão igual ou maior são preservados.
2. **Pacote `.kawall`:** `sudo kawaii-arch-manager --import-bundle arquivo.kawall`.
   Para criar um: `tools/make-kawall.sh meu-bundle/ [saida.kawall]`.
3. **Pasta extraída:** `sudo kawaii-arch-manager --import-bundle pasta/`. A
   pasta pode ser o próprio bundle (`manifest.conf` + `backgrounds/`) ou
   conter um único bundle num subdiretório, como fica depois de
   `tar -xf meu-bundle.kawall`.

Depois de adicionar bundles, escolha o modo com
`sudo kawaii-arch-manager --set-mode ...` (o padrão é `global`) e, se quiser
um wallpaper novo já no próximo boot, rode `sudo kawaii-arch-manager --randomize`.

### Formato `.kawall` e segurança da importação

Um `.kawall` é um tar (sem compressão, gzip, xz, zstd ou bzip2) com um único
diretório raiz igual ao ID. O pacote e a pasta extraída são tratados como
**não confiáveis**, e a importação é feita em duas passagens:

1. **Validação sem escrita.** O manager rejeita:
   - `..` e caminhos absolutos;
   - links simbólicos e hard links (em pastas, links simbólicos);
   - dispositivos, FIFOs e sockets;
   - mais de um diretório raiz (ou mais de um bundle na pasta);
   - nomes duplicados;
   - conteúdo acima dos limites: 512 MiB por arquivo, 8 GiB no total, 20 000
     entradas e 10 000 imagens.
2. **Cópia** apenas de `manifest.conf` e `backgrounds/*.png`:
   - cada arquivo é criado com `openat(O_EXCL|O_NOFOLLOW)` e permissão 0644,
     num diretório temporário em `bundles/`; o resto é ignorado;
   - o conteúdo copiado é validado de novo;
   - a instalação usa `renameat2(RENAME_EXCHANGE)`, que preserva a versão
     anterior até a conclusão.

Nada do pacote é executado. Uma versão nova pede confirmação; a mesma
versão ou uma mais antiga é recusada (a menos que se use `--force`). A
configuração é sempre preservada, e um bundle selecionado não pode ser
removido antes de se escolher outro.

## Kawaii Arch Manager

```text
kawaii-arch-manager --status                    componentes, versões, configuração, serviço
kawaii-arch-manager --list-bundles              bundles instalados (ID, versão, imagens, tamanho)
kawaii-arch-manager --list-available-bundles [DIR]   pacotes .kawall disponíveis localmente
kawaii-arch-manager --tone ARQUIVO.png          tom do wallpaper: dark ou light
sudo kawaii-arch-manager --import-bundle ARQUIVO.kawall | PASTA
sudo kawaii-arch-manager --remove-bundle ID
sudo kawaii-arch-manager --set-bundle ID
sudo kawaii-arch-manager --set-mode fixed|set|global|balanced
sudo kawaii-arch-manager --set-background ID/arquivo.png
sudo kawaii-arch-manager --randomize            aplica agora (via helper, ou seleção interna)
sudo kawaii-arch-manager --update               helper, serviço e bundles a partir do payload local
sudo kawaii-arch-manager --install-helper | --install-service
sudo kawaii-arch-manager --enable-service | --disable-service | --start-service | --stop-service
sudo kawaii-arch-manager --uninstall service|helper|manager|data
```

Opções globais: `--yes` (confirma automaticamente), `--force` (reinstala a
mesma versão ou permite downgrade) e `--dry-run` (só valida ou simula; aceito
por `--import-bundle`, `--randomize` e `--update`).

Os comandos de consulta funcionam como usuário comum. Operações de escrita
exigem root e mostram o comando com `sudo`; o manager nunca se eleva sozinho.

O **payload** (`/usr/share/kawaii-arch-manager/payload/`) é a cópia local,
feita pelo instalador, do helper, do modelo da unidade e dos pacotes
`.kawall` que estavam em `bundles/` na instalação. É dele que vêm
`--install-helper`, `--install-service`, `--update` e a lista padrão de
`--list-available-bundles`. Bundles instalados como pastas não entram no
payload.

**Códigos de saída:** 0 sucesso · 1 falha operacional · 2 argumento inválido ·
3 bundle ou configuração inválido · 4 conflito (já instalado, em uso,
dependência ausente, downgrade) · 5 sem privilégios ou partição indisponível ·
6 cancelado pelo usuário. O helper usa os mesmos códigos de 0 a 5 (4 = lock
ocupado).

## Modos de seleção

A configuração fica em `/var/lib/kawaii-arch-manager/config/backgrounds.conf`:

```ini
MODE="set"
SELECTED_BUNDLE="meu-bundle"
SELECTED_BACKGROUND=""        # ID/arquivo.png, usado no modo fixed
```

| Modo | Comportamento |
|---|---|
| `fixed` | sempre `SELECTED_BACKGROUND` |
| `set` | imagem aleatória de `SELECTED_BUNDLE` |
| `global` | uniforme entre **todas as imagens** de todos os bundles (padrão) |
| `balanced` | primeiro um bundle uniforme, depois uma imagem dele |

A última imagem aplicada (`state/last-background`) não se repete quando há
alternativa. Se o bundle configurado for removido ou ficar inválido, o helper
não escolhe outro em silêncio: registra o erro, preserva o `background.png`
atual e, se ele não existir, usa o `fallback.png`.

## Background Helper e serviço

O helper:
- lê a configuração diretamente, sem `source` e sem depender do manager;
- usa `flock` e confere a montagem do tema;
- copia a imagem para `background.png.tmp` no próprio diretório do tema,
  valida, faz `sync` e então o `rename(2)` atômico sobre `background.png`;
- só depois atualiza `last-background`;
- por fim, ajusta o [tom do tema](#tom-claro-ou-escuro) ao wallpaper aplicado.

Ele nunca altera os bundles e nunca roda `grub-mkconfig`. No `theme.txt`, só
troca os valores gerenciados pelo tom, e só quando eles mudam.
`grub-random-bg.sh --retone` reaplica o tom ao wallpaper ativo sem trocá-lo.

O caminho real do tema fica em `config/paths.conf` (`THEME_DIR`,
`EXPECTED_MOUNT`). O helper se recusa a escrever se o ponto de montagem não
for o esperado, ou se um ponto declarado no `fstab` para o tema não estiver
montado. Assim ele nunca escreve no diretório subjacente de um `/boot`
desmontado.

A unidade:
- é `oneshot` e tem `RequiresMountsFor=` com o diretório real do tema;
- usa `ProtectSystem=strict`, com escrita somente no tema e em `state/`, sem
  capabilities e sem rede;
- nunca é habilitada sem escolha explícita;
- se falhar, não impede o boot.

Logs: `journalctl -u grub-random-bg.service`.

## Visual

O tema mantém o layout minimalista do KawaiiGRUB: só o menu de boot (ícone +
nome de cada sistema), o logo da distribuição (opcional) e a barra de tempo
(uma faixa, sem fundo, que cresce na base da tela). Sobre essa base:

- **Caixa do terminal** (mensagens de carregamento e console,
  `tones/<tom>/terminal_box_*.png`): vidro escuro neutro com 72% de
  opacidade e contorno claro (escuro no tom `light`). A cor neutra acompanha qualquer paleta de wallpaper. A opacidade foi
  calibrada para manter o texto do GRUB legível até sobre áreas brancas. O
  GRUB não desfoca o fundo, então o efeito de vidro vem da transparência, do
  contorno e de um reflexo interno.
- **Contorno do menu de boot** (`tones/<tom>/boot_menu_box_*.png`, via
  `menu_pixmap_style`): o mesmo contorno, sem preenchimento. O GRUB desenha
  essa moldura dentro dos limites do menu e reserva 16 px de cada lado. Por
  isso os limites no `theme.txt` são a área das entradas expandida em 16 px
  por lado.

Para ajustar o vidro (por exemplo, a opacidade), use
[`tools/make_glass.py`](#ferramentas).

### Tom claro ou escuro

Texto branco some num wallpaper claro, e texto escuro, num escuro. Por isso,
sempre que um wallpaper é aplicado, a claridade dele é medida nas áreas onde
há texto (o menu e o logo), e o tema passa a usar um de dois tons:

| | `dark` (wallpaper escuro, padrão) | `light` (wallpaper claro) |
|---|---|---|
| Texto do menu | `#dddddd`, selecionado `#ffffff` | `#1c1c22`, selecionado `#000000` |
| Ícones | brancos (`icon-sets/dark/`) | escuros (`icon-sets/light/`) |
| Bordas do terminal e do menu, seleção, barra de tempo | claras (`tones/dark/`) | escuras (`tones/light/`) |
| Logo | `logos/<distro>-dark.png` | `logos/<distro>-light.png` |

O preenchimento da caixa do terminal é o mesmo nos dois tons: o vidro escuro
já deixa o texto do terminal legível em qualquer fundo.

Como funciona:
- **Medição:** `kawaii-arch-manager --tone ARQUIVO.png` decodifica o PNG e
  escolhe o tom que dá mais contraste médio ao texto. O helper e o
  instalador usam esse comando. Sem o manager, o tom é sempre `dark`, que é
  o visual padrão do tema.
- **Cores, bordas, seleção, barra e logo:** o helper reescreve só essas
  linhas do `theme.txt` (os caminhos `tones/dark/` ↔ `tones/light/`,
  `item_color`, `selected_item_color` e o arquivo do logo). As cores de
  cada tom vêm de `tones/<tom>/colors.conf`.
- **Ícones:** o GRUB só lê ícones de `icons/`, então o helper copia para lá
  o conjunto do tom, um arquivo por vez (troca atômica). O marcador
  `icons/.tone` registra o tom aplicado. Os arquivos só são copiados quando
  o tom muda.
- O tom atual aparece em `kawaii-arch-manager --status`. Para reaplicá-lo
  ao wallpaper ativo: `sudo /usr/lib/kawaii-arch-manager/grub-random-bg.sh --retone`.

### Logo da distribuição

O logo é `logos/<id>-<tom>.png`, sem subpastas. O helper lê o
`/etc/os-release` e tenta o `ID` e depois cada `ID_LIKE`. Se nenhum arquivo
existir, usa o do Arch (`arch-dark.png` ou `arch-light.png`). Por exemplo, o
EndeavourOS (`ID=endeavouros`, `ID_LIKE=arch`) mostra o logo do Arch até
alguém adicionar `endeavouros-dark.png` e `endeavouros-light.png`.

Para suportar outra distribuição, adicione os dois PNGs em
`grub-theme/logos/`, com até 256x85 px, 8 bits RGBA e sem entrelaçamento. O
nome é o `ID` do `os-release`. Depois suba a versão do tema.

## Solução de problemas

| Sintoma | O que verificar |
|---|---|
| O tema não aparece | `GRUB_THEME` em `/etc/default/grub` aponta para `.../kawaii-arch-theme/theme.txt`; `GRUB_TERMINAL_OUTPUT=console` impede o tema (o instalador oferece comentar a linha); rode `sudo grub-mkconfig -o /boot/grub/grub.cfg` |
| A instalação não lista nenhum bundle | num clone novo, `bundles/` está vazia; coloque bundles ali ou importe-os depois com `--import-bundle` |
| O wallpaper não troca a cada boot | é preciso ter bundles instalados (`kawaii-arch-manager --list-bundles`) e o serviço instalado **e** habilitado (`--status`); veja `journalctl -u grub-random-bg.service` |
| Erro 5 / "partição não montada" | o tema está numa partição que não estava montada; confira `EXPECTED_MOUNT` em `/var/lib/kawaii-arch-manager/config/paths.conf` |
| Nome de entrada cortado no menu | aumente `width` do `boot_menu` no `theme.txt`, mantendo os +32 px do contorno |
| Texto do terminal difícil de ler | regenere a caixa com mais opacidade: `python3 tools/make_glass.py --opacity 0.8` (e `--tone light`) |
| Texto/ícones claros num wallpaper claro | o tom é medido pelo manager: confira se ele está instalado e o tom em `--status`; veja o que ele mede com `kawaii-arch-manager --tone /boot/grub/themes/kawaii-arch-theme/background.png` e reaplique com `sudo /usr/lib/kawaii-arch-manager/grub-random-bg.sh --retone` |
| Logo de outra distribuição não aparece | o arquivo precisa ser `logos/<ID>-dark.png` e `logos/<ID>-light.png`, com o `ID` (ou um `ID_LIKE`) do `/etc/os-release` |
| Menu lento para aparecer | wallpaper muito grande; use imagens na resolução da tela |

## Desenvolvimento

### Estrutura do repositório

```text
install.sh                      instalador (bootstrap): tema + componentes opcionais
grub-theme/                     arquivos do tema: theme.txt, fontes, background.png
                                padrão, fallback.png, VERSION e
  tones/{dark,light}/           molduras, seleção, barra e cores de cada tom
  icon-sets/{dark,light}/       ícones de cada tom
  icons/                        ícones ativos (cópia de um icon-set; GRUB lê daqui)
  logos/                        logos por distribuição: <id>-<tom>.png
bundles/                        bundles locais para o instalador (ignorados pelo git,
                                exceto bundles/README.md)
helper/grub-random-bg.sh        Background Helper
systemd/grub-random-bg.service.in   modelo da unidade (@THEME_DIR@)
manager/                        código-fonte C + Makefile do manager
tools/make-kawall.sh            empacota a pasta de um bundle em .kawall
tools/make_glass.py             extra: regenera as molduras liquid glass
tools/make_light_assets.py      extra: gera seleção, barra e ícones do tom light
tests/run-tests.sh              testes em sandbox (não exigem root)
licenses/                       textos das licenças de terceiros (OFL)
AGENTS.md                       contexto do projeto para agentes e colaboradores
```

### Testes

```bash
tests/run-tests.sh [--keep]
```

Os testes compilam o manager e rodam o helper, o manager e o instalador numa
sandbox (`KAWAII_ROOT`), com um `systemctl` e um `grub-mkconfig` falsos. Os
bundles são gerados pelos próprios testes, então funcionam num clone sem
bundles. Não exigem root nem alteram o sistema. Cobrem:
- importação de `.kawall` e de pastas, atualização e downgrade de bundles;
- pacotes e pastas maliciosos (path traversal, links, arquivos especiais,
  limites);
- os quatro modos e suas distribuições de probabilidade;
- a medição do tom (`--tone`) em todos os formatos de PNG aceitos e com PNGs
  inválidos, a troca de ícones, cores, bordas e logo, a retomada de uma
  cópia interrompida e a escolha do logo pelo `os-release`;
- casos de falha (partição desmontada, `fstab`, configuração inválida,
  fallback) e o diretório do tema bind-montado, como faz o `ReadWritePaths=`;
- instalação completa, seleção de bundles, pacote sem bundles, atualização
  sem downgrade, idempotência, `--fresh` (inclusive cancelamento e
  `--keep-config`), dependência serviço → helper e remoção.

### Ferramentas

- **`tools/make-kawall.sh PASTA [SAIDA.kawall]`** empacota a pasta de um
  bundle num `.kawall` determinístico (dono root, permissões 0644/0755, zstd
  ou gzip).
- **`tools/make_glass.py`** (script extra, **sem versão própria**, ao
  contrário dos componentes) gera `terminal_box_*.png` e
  `boot_menu_box_*.png` em `grub-theme/tones/<tom>/`. Requer Python 3 com
  Pillow e NumPy.

  ```sh
  python3 tools/make_glass.py                 # tom dark (contorno claro)
  python3 tools/make_glass.py --tone light    # tom light (contorno escuro)
  python3 tools/make_glass.py --opacity 0.65  # vidro do terminal mais claro
  python3 tools/make_glass.py --out /tmp/x    # gera em outro diretório
  ```

- **`tools/make_light_assets.py`** (extra, sem versão própria) gera as peças
  do tom `light` a partir das do `dark`: a seleção e a faixa da barra em
  `tones/light/`, e os ícones em `icon-sets/light/` (glifos em tons de cinza
  com a luminosidade invertida; ícones coloridos são copiados sem mudança).
  Rode depois de mudar um ícone ou a seleção do tom `dark`.

Os PNGs gerados fazem parte do tema: ao alterá-los, suba a versão do tema.
Ao mudar `icon-sets/dark/`, copie-o também para `icons/` (o conjunto
padrão do pacote).

### Versões

| Mudou | Suba | Onde |
|---|---|---|
| qualquer arquivo de `grub-theme/` | versão do tema | `grub-theme/VERSION` e a tabela de componentes |
| `manager/src/` | versão do manager | `VERSION` no `manager/Makefile`, a tabela e os testes que conferem `--version` |
| `helper/grub-random-bg.sh` | versão do helper | `VERSION="..."` no script, a tabela e o teste `helper --version` |
| `systemd/grub-random-bg.service.in` | revisão da unidade | a tabela |
| imagens ou manifesto de um bundle | versão do bundle | `VERSION` no `manifest.conf` |

Use SemVer: patch para correções e ajustes, minor para funções ou recursos
visuais novos compatíveis, major para mudanças incompatíveis. O
`install.sh` e as ferramentas não têm versão própria.

## Garantias de projeto

| Garantia | Como é cumprida |
|---|---|
| Um único wallpaper ativo em `/boot` | `theme.txt` → `background.png`; teste "/boot contém só…" |
| Bundles fora de `/boot` | `/var/lib/kawaii-arch-manager/bundles` |
| Manager compilado em `/usr/bin` | C + libarchive; o instalador verifica ELF e `--version` |
| Bundle validado antes de instalar | importação em duas passagens + revalidação |
| Bundles adicionados sem reinstalar o tema | `--import-bundle` (pacote ou pasta) |
| Helper sem o manager; manager sem helper e serviço | testes "helper funciona sem o manager" e "randomize sem helper" |
| Serviço só com o helper e só habilitado com escolha explícita | instalador e `--install-service` (rc 4); `--enable-service` ou pergunta |
| Componentes opcionais e independentes | perguntas e `--with/--without-*`, `--no-components` |
| Substituição atômica; falha preserva o anterior | `.tmp` + `rename(2)`; testes de falha |
| Não escreve com `/boot` desmontado | `EXPECTED_MOUNT` + `fstab` (rc 5) |
| Versões independentes, sem downgrade | SemVer por componente; `--status` / `--update` |
| Reinstalação preserva dados e configuração | testes de atualização, idempotência e `--keep-config` |
| Troca de wallpaper sem `grub-mkconfig` | teste com `grub-mkconfig` falso |
| Tom ajustado sem quebrar o tema | só linhas gerenciadas do `theme.txt`, escrita atômica e só quando muda; sem o manager, tom `dark` |

Observação: as fontes `.pf2` ficam na raiz do tema, porque o
`/etc/grub.d/00_header` só as carrega de lá.

## Licença e créditos

O código e os arquivos próprios estão sob a licença **MIT** (ver
[`LICENSE`](LICENSE)), mantendo o aviso do KawaiiGRUB, do qual este projeto
deriva.

- [KawaiiGRUB](https://github.com/Gabbar-v7/KawaiiGRUB), de Gabbar: base do
  tema, ícones e peças do menu (MIT).
- CyberRe, de L. Henrique Lopes (HENK): inspiração da barra de carregamento.
- Fontes Public Sans e Terminus: SIL OFL 1.1 (ver `licenses/`).
- Wallpaper padrão: rafaelmotacr.

Origem e licença de cada parte, marcas e o uso de wallpapers estão em
[`THIRD_PARTY.md`](THIRD_PARTY.md).
