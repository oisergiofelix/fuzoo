<p align="center">
  <img src="docs/og.png" alt="fuzoo — dois fusos na barra de menus do macOS" width="640">
</p>

<p align="center">
  <b>Dois fusos na barra de menus. ~7 MB de RAM. Mais nada.</b><br>
  <a href="https://oisergiofelix.github.io/fuzoo/">Site</a> ·
  <a href="https://github.com/oisergiofelix/fuzoo/releases/latest/download/fuzoo.dmg">Baixar para macOS</a> ·
  <a href="README.md">English</a>
</p>

---

## Por quê

Trabalho remoto de Campo Grande, uma hora atrás de São Paulo. Todo convite de reunião, todo prazo, todo "falamos às 15h?" virava uma conta de cabeça, o dia inteiro.

Os relógios mundiais que encontrei faziam muito mais do que eu precisava e gastavam muito mais memória do que um relógio deveria. Eu queria o contrário: dois horários na barra de menus e um processo tão pequeno que eu esquecesse que ele está rodando.

Daí nasceu o **fuzoo**.

```
CG 16:16  SP 17:16
```

Ele vem com Campo Grande e São Paulo. Pelo menu você troca, adiciona ou renomeia os relógios.

## Quão pequeno

| | fuzoo |
|---|---|
| Memória (`phys_footprint`) | **~7,7 MB** |
| CPU | **0%**: acorda uma vez por minuto, por microssegundos |
| Tamanho | **~100 KB** para baixar, binário universal |
| Dependências | **nenhuma** |
| Código | **1 arquivo**, ~300 linhas de Objective-C |

Esses ~7 MB são o piso de qualquer coisa que desenhe na barra de menus do macOS (AppKit e a conexão com o WindowServer). Nós medimos: o mesmo relógio reescrito em C puro, chamando o runtime do Objective-C na mão, gastou *mais*. O código do fuzoo em si ocupa poucos KB.

### O que deixa ele tão pequeno

- **Acorda uma vez por minuto.** Um timer de relógio de parede dispara exatamente na virada do minuto e continua certo depois que o Mac dorme e acorda. A tolerância de 1 s deixa o macOS agrupar esse despertar com outros.
- **Sem formatadores de data.** A hora é aritmética pura sobre o offset UTC do fuso.
- **Fusos de verdade.** Identificadores IANA (`America/Campo_Grande`), então horário de verão e mudanças de regra vêm do próprio macOS.
- **Menu preguiçoso.** Ele só é montado quando você clica.
- **Sem frameworks, nibs ou helpers.** Só AppKit.

## Instalar

1. [Baixe o `fuzoo.dmg`](https://github.com/oisergiofelix/fuzoo/releases/latest/download/fuzoo.dmg) e arraste o **fuzoo** para **Aplicativos**.
2. O fuzoo ainda não é notarizado pela Apple, então o macOS bloqueia a primeira abertura. Libere de um destes jeitos:
   - **Ajustes do Sistema → Privacidade e Segurança** → role até o fim → **Abrir Mesmo Assim**, ou
   - no Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/fuzoo.app
     ```
3. Clique no relógio → **Iniciar com o sistema**.
4. **Dica:** o relógio do próprio Mac já mostra a sua hora local. Para não vê-la duas vezes, deixe-o analógico: **Ajustes do Sistema → Central de Controle → Relógio → Opções do Relógio → Analógico**. Aí o fuzoo vira a única hora digital da barra.

O fuzoo nasce ao lado dos ícones do sistema, no canto direito. Para mudar de lugar, segure **⌘** e arraste.

Prefere compilar? Só precisa do Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/oisergiofelix/fuzoo && cd fuzoo && make install
```

## Usar

Clique no relógio na barra de menus:

- **Cada relógio** → escolha uma cidade, **Outro fuso…** (qualquer fuso IANA), **Renomear rótulo…** ou **Remover**
- **Adicionar relógio**
- **Iniciar com o sistema**

A interface segue o idioma do sistema (português ou inglês).

Prefere o terminal? Edite os relógios direto e reabra o app:

```bash
defaults write io.github.oisergiofelix.fuzoo clocks -array \
  '{label=CG;tz="America/Campo_Grande";}' '{label=SP;tz="America/Sao_Paulo";}'
```

## Desenvolver

```bash
make run       # compila e abre
make release   # build/fuzoo.dmg + build/fuzoo.zip
make brand     # regenera ícone e imagens a partir de tools/brand.m
make clean
```

Uma tag `v*` gera e publica a release pelo GitHub Actions.

Contribuições são bem-vindas. Uma regra: **o fuzoo não pode ficar mais pesado.** Se um recurso gasta memória ou acorda o processo com o menu fechado, provavelmente ele não pertence aqui.

## Licença

[MIT](LICENSE) © Sérgio Felix
