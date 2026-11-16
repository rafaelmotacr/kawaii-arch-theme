# bundles/

Coloque aqui, antes de rodar o `install.sh`, os bundles de wallpapers que
você quer oferecer na instalação. O repositório não traz bundles: o conteúdo
desta pasta (exceto este arquivo) é ignorado pelo git.

Cada bundle é uma pasta com o nome igual ao `ID` do manifesto:

```text
bundles/
└── meu-bundle/
    ├── manifest.conf      ID="meu-bundle"  VERSION="1.0.0"  [NAME] [AUTHOR] [DESCRIPTION]
    └── backgrounds/
        ├── background1.png
        └── background2.png
```

- `ID`: `[a-z0-9][a-z0-9_-]{0,63}`, igual ao nome da pasta.
- `VERSION`: SemVer.
- Imagens: PNG de 8 ou 16 bits, cinza/RGB/RGBA, sem paleta e não
  entrelaçado (o formato que o GRUB lê). Imagens fora disso são ignoradas
  com aviso.

Pacotes `.kawall` colocados aqui são copiados para o payload do manager e
aparecem em `kawaii-arch-manager --list-available-bundles`.

Depois da instalação, bundles podem ser adicionados sem o instalador:

```bash
sudo kawaii-arch-manager --import-bundle ~/Downloads/meu-bundle.kawall
sudo kawaii-arch-manager --import-bundle ~/Downloads/meu-bundle/   # pasta extraída
```

Use apenas imagens que você tenha direito de usar (ver `THIRD_PARTY.md`).
