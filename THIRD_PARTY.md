# Componentes de terceiros

O código e os arquivos próprios do Kawaii Arch Theme estão sob a licença MIT
(ver [`LICENSE`](LICENSE)). Este projeto é derivado do **KawaiiGRUB** e inclui
partes de outros projetos, listadas abaixo com as respectivas licenças. Cada
parte continua sob a licença original.

| Componente | Arquivos | Origem | Licença |
|---|---|---|---|
| KawaiiGRUB (base do tema) | estrutura do `theme.txt`, `tones/dark/select_*.png`, `icon-sets/dark/` e `icons/` (inclusive `memtest86.png` e `snapshots.png`, cópias renomeadas de `memtest.png` e `restart.png` para casar com as classes de entrada desses nomes). `tones/light/select_*.png` e `icon-sets/light/` são versões escuras derivadas desses arquivos (`tools/make_light_assets.py`) | [Gabbar-v7/KawaiiGRUB](https://github.com/Gabbar-v7/KawaiiGRUB), © 2024 Gabbar | MIT (aviso mantido em [`LICENSE`](LICENSE)) |
| CyberRe (inspiração da barra de carregamento) | formato do bloco `progress_bar` do `theme.txt` (posição e altura); cores e `tones/*/progress_highlight_c.png` são próprios | tema GRUB CyberRe, © 2020 L. Henrique Lopes (HENK) ([GNOME-Look / KDE Store](https://store.kde.org/p/1420727)) | a página original não declara licença; o pacote AUR `grub-theme-cyberre` o distribui como CC0 1.0 |
| Public Sans | `PublicSans_Bold_21.pf2` | [uswds/public-sans](https://github.com/uswds/public-sans), © 2015 The Public Sans Project Authors | SIL OFL 1.1 ([`licenses/OFL-1.1-PublicSans.txt`](licenses/OFL-1.1-PublicSans.txt)) |
| Terminus Font | `terminus-16.pf2` | [terminus-font.sourceforge.net](https://terminus-font.sourceforge.net/), © 2012 Dimitar Toshkov Zhekov | SIL OFL 1.1, com o nome reservado "Terminus Font" ([`licenses/OFL-1.1-Terminus.txt`](licenses/OFL-1.1-Terminus.txt)) |

As fontes vêm no formato PF2 do GRUB, convertidas dos originais. Pela OFL,
uma conversão de formato é uma "Modified Version", que continua sob a OFL e
precisa ser distribuída com o aviso de copyright e o texto da licença (os
arquivos em `licenses/`).

## Marcas

Os logotipos em `grub-theme/logos/` (o do Arch Linux em duas versões:
`arch-dark.png`, com texto claro, e `arch-light.png`, a versão oficial com
texto escuro) e os ícones de distribuições e sistemas em
`grub-theme/icon-sets/` e `grub-theme/icons/` (inclusive as versões
recoloridas) são marcas dos respectivos donos. Eles
aparecem aqui apenas para identificar os sistemas no menu de boot. Não estão
cobertos pela licença MIT, e seu uso não indica afiliação nem endosso.

## Wallpapers

- O wallpaper padrão (`grub-theme/background.png` e `fallback.png`) é de
  autoria de rafaelmotacr e é distribuído sob a licença do projeto.
- Os bundles de wallpapers **não** fazem parte deste repositório. Ao criar ou
  importar bundles, use apenas imagens que você tenha direito de usar e, se
  for redistribuí-las, de redistribuir. "Grátis para baixar" não significa
  licença para redistribuir.
