# Usage bridge — prova local

Conector de consulta única, escrito em Objective-C com autorização manual AppKit.
Integrado à build de desenvolvimento v0.5.0; ainda não foi publicado em release.
Consulta cotas sem abrir telas do ChatGPT/Codex ou Claude.

## Rodar

```sh
make usage-check                 # compila universal e valida o parser, sem rede
build/usage-bridge               # consulta única com credenciais locais
build/usage-bridge --diagnostic  # etapas de execução, sem valores de credenciais
make usage-authorizer           # monta o app de autorização manual
open 'build/Fuzoo Usage Bridge.app'
# Depois de conectar, executar a mesma build, sem recompilar:
'build/Fuzoo Usage Bridge.app/Contents/MacOS/usage-bridge' --background
```

A execução real requer consentimento para reutilizar as sessões locais. O padrão
não permite prompts do Chaves. `--allow-keychain-prompt` permite o diálogo do
macOS somente nessa execução manual. Para conectar, prefira abrir o app acima:
isso registra a identidade do app e mantém a interface disponível para o
diálogo do macOS. A sonda não altera listas de acesso programaticamente; a
autorização é controlada pelo macOS e pelo usuário.

## Fontes

- Codex: token e conta de `~/.codex/auth.json`, em leitura, para
  `https://chatgpt.com/backend-api/wham/usage`.
- Claude: primeiro `~/.claude/.credentials.json` para
  `https://api.anthropic.com/api/oauth/usage`.
- Claude Desktop: quando não há OAuth disponível, lê somente `sessionKey` e
  `lastActiveOrg` do domínio `claude.ai` no banco Cookies do próprio Claude.
  Usa `Claude Safe Storage` para descriptografá-los em memória e consulta
  `https://claude.ai/api/organizations/<organização-ativa>/usage`.

O item de Chaves do Claude Code não é consultado: nesta máquina a fonte
disponível e validada é o Desktop. Isso evita um diálogo de outro aplicativo
antes de tentar a fonte correta.

Os endpoints são internos e sujeitos a mudanças. Referência de pesquisa:
[CodexBar, Codex OAuth](https://github.com/steipete/CodexBar/blob/main/docs/codex-oauth.md)
e [Claude](https://github.com/steipete/CodexBar/blob/main/docs/claude.md).
Implementação local independente, sem incorporar a biblioteca do projeto.

## Contrato

- No modo CLI, só saída JSON com cotas, resets, captura e estados de falha.
  O modo de autorização exibe o resultado em alerta nativo e grava apenas o
  resultado sanitizado em `/private/tmp/fuzoo-usage-authorize-result.json`.
  `--agent` faz a consulta sem foco nem diálogo e grava o resultado em
  `/private/tmp/fuzoo-usage-background-result.json`. Esses arquivos são
  diagnósticos, não constituem um canal de integração confiável com o app.
- Percentuais são **restantes** em ambos os serviços.
- Valor ausente, inválido ou acesso negado nunca se transforma em `0%`.
- Credenciais não são exibidas, persistidas, renovadas nem alteradas.
- Sem leitura de conversas, varredura de histórico, navegador ou OCR.
- Banco do Claude aberto somente para leitura; cookies de outros domínios não
  entram na consulta. Nenhuma outra rota de conta é consultada.
- Sessão HTTP efêmera, sem cache nem armazenamento de cookies; redirects recusados.
- Timeout HTTP de 15 s; deadline de 45 s no modo automático, incluindo Chaves.
  A autorização manual aguarda a interação com o diálogo nativo.
- Nenhum serviço instalado, agendamento ou processo residente.
- O build normal inclui o conector em `Contents/Helpers/UsageBridge.app`, com
  assinatura própria antes da assinatura do app principal. `make check` verifica
  as duas arquiteturas e a assinatura completa e executa os testes offline.
- A integração usa stdout de uma tarefa filha, não os arquivos temporários do
  diagnóstico. Ao desligar, cancela a tarefa, remove o item e seu observador.
- `src/AIUsage.m` controla o item opcional e os snapshots em memória. Desligado
  por padrão, ele só é instanciado quando a opção está ligada.
- O timer de minuto existente dispara consultas a cada cinco minutos (ou mais
  lentamente em falhas). Não há timer adicional. A leitura é assíncrona.
- Dados com mais de dez minutos ou cujo reset passou viram `—`. Falhas descartam
  saldos anteriores para não apresentar dados de outra conta como atuais.
- A pausa por 429/Retry-After bloqueia também o comando manual de atualização.

## Evidência e critérios de integração

Em 16/11/2026, os dois serviços retornaram dados reais sem navegação de interface:
Codex 19% da sessão / 87% da semana restantes; Claude Desktop 82% da sessão /
96% da semana restantes. O reset do Claude retornou 19:00 em Campo Grande.
São amostras pontuais, não limites fixos dos planos.

Uma consulta posterior concluiu em 391 ms com ambos os mecanismos de prompt
desligados: Codex retornou uma amostra nova; Claude retornou acesso indisponível
no Chaves (`-25293`). Foi necessário autorizar a build final e repetir os testes
sem recompilar entre eles. A lista de aplicativos confiáveis do item contém o
conector e o próprio Claude. Builds com assinatura ad-hoc mudam de identidade ao
serem recompiladas: o acesso deve ser revalidado depois de mudanças no binário.
Uma tentativa anterior sem o bloqueio adicional de diálogos legados atingiu o
deadline de 45 s; isso motivou bloquear também esses diálogos por padrão.

O parser tem verificações offline para ausência de dado, valores fora do
intervalo, strings, booleanos, saldo esgotado e preservação do reset. O binário
da sonda é universal (Intel/Apple Silicon). Após a autorização da build final,
duas consultas consecutivas em modo automático retornaram ambos os serviços,
sem diálogos, em 724 ms e 822 ms. A segunda retornou Codex 92% da sessão / 85%
da semana restantes e Claude 81% / 96% restantes, com resets.

Na segunda execução, `/usr/bin/time -l` observou 0,10 s de CPU (0,07 user +
0,03 sys), ~5,0 MB de pico de footprint e ~14,3 MB de RSS máximo; o processo
terminou em 0,84 s. Esses números são uma observação local da sonda, não o
consumo adicional do fuzoo. Não há medição de monitoramento contínuo: a sonda
não estava integrada na ocasião dessa medição, nem instalada como serviço.

## Validação da integração (17/11/2026)

Testes offline cobrem dados inválidos, saldo zero legítimo, formatos de reset,
expiração e ausência independente das janelas semanal e de cinco horas.
`tests/AIUsageLiveCheck.m` verifica o caminho assíncrono real com o helper
instalado, títulos do menu, bloqueio de consulta dentro do intervalo, ocultação
de snapshots antigos e cancelamento da tarefa ao desligar.

Na primeira build integrada, os dois provedores retornaram dados reais e o
fuzoo em repouso, com o item ligado, apresentou `phys_footprint` de 11,1 MB e CPU
observada de 0,0% neste Mac. São observações locais, não um teto universal.
Revalidar a autorização do Chaves após mudanças na assinatura do conector.
