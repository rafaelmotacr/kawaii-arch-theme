# RULES.md: regras do projeto

Regras de desenvolvimento definidas pelo mantenedor. Valem para qualquer
pessoa ou agente que altere o projeto. As garantias técnicas do sistema
(troca atômica, `/boot` desmontado, bundles não confiáveis etc.) estão na
seção "Regras que não podem ser quebradas" do [`AGENTS.md`](AGENTS.md).

## 1. Sem compatibilidade com versões anteriores

O projeto não tem base de usuários. Por isso, **não se escreve código de compatibilidade entre versões**:

- nada de migração de arquivos, formatos ou caminhos antigos;
- nada de fallback para ler um arquivo ou formato que deixou de existir;
- nada de manter dois formatos sincronizados;
- nada de tratamento especial para "tema/instalação de versão antiga".

Quando um formato muda, todos os componentes mudam juntos no mesmo commit.
Uma instalação de desenvolvimento antiga se resolve reinstalando
(`install.sh --fresh`) ou ajustando os arquivos à mão.

O que **não** é compatibilidade e continua valendo:
- preservar os dados do usuário (bundles, preferências) ao reinstalar ou
  atualizar com a **mesma** estrutura de arquivos;
- validar entradas. Um arquivo ausente, incompleto ou inválido gera um
  erro claro, não um caminho alternativo;
- versionar cada componente (SemVer), porque o instalador e o `--update`
  usam a versão para decidir o que substituir.

## 2. Simplicidade

- Prefira a solução mais simples que resolve o problema pedido. Nada de
  configuração, cache ou generalização "para o futuro" sem pedido.
- Uma regra de negócio tem uma única implementação. Exemplo: o tom do tema
  só é aplicado pelo helper; o manager e o instalador o chamam.

## 3. Processo

- Mudanças não triviais começam por um plano em `plan.md`, que o mantenedor
  revisa. Depois de aprovado e implementado, o arquivo é removido.
- Mudanças visuais só com pedido explícito.
- Commit e push só quando o mantenedor pedir.

## 4. Qualidade

- Todo comportamento novo ou corrigido tem teste em
  `tests/run-tests.sh`, e a suíte termina com 0 falhas.
- O manager compila sem avisos (`-Wall -Wextra`).
- Cada mudança num componente sobe a versão dele (ver a seção "Versões"
  do `AGENTS.md`), e a documentação (`README.md`, `AGENTS.md`) é
  atualizada junto.

## 5. Idioma

Documentação e mensagens em português. O README e estes arquivos usam
acentos; scripts, código C e mensagens de terminal ficam em ASCII.
