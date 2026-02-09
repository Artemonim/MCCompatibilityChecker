# MCCompatibilityChecker

[Русский](README.md) | [English](README.en.md) | [Español](README.es.md) | [Tiếng Việt](README.vi.md) | [Português](README.pt.md) | [Türkçe](README.tr.md) | [Indonesia](README.id.md) | [中文](README.zh.md)

Diagnóstico automático de conflitos de mods do Minecraft. O script inicia o jogo, captura crashes, lê os logs de erro, encontra o mod culpado e o isola — em um ciclo contínuo até que a coleção de mods funcione.

> Funciona através do [Legacy Launcher](https://llaun.ch/) (sucessor do TLauncher). A inicialização do jogo e a detecção de crashes são feitas através da interface do launcher; a análise de erros baseia-se nos logs padrão do Fabric/Forge/Minecraft.

## Por que utilizar

Você reuniu 200 mods, iniciou o jogo — e ele crashou. Abriu o log — e é uma parede de texto. Removeu um mod aleatoriamente — e teve outro crash. Familiar?

O MCCompatibilityChecker faz o que você faz manualmente, mas de forma automática: remove mods, inicia o jogo, verifica o resultado e repete. Mas em vez de tentativas aleatórias, utiliza um algoritmo com busca binária, análise de erros de Mixin e um mapa de dependências.

O resultado é uma lista de culpados e uma coleção de mods funcional.

## Status do projeto

Versão atual — desenvolvimento ativo (experimental).

- Atualmente, o processamento de grandes grupos de incompatibilidades pode ser instável.
- Para grandes coleções de mods, recomenda-se fazer primeiro um backup da pasta `mods` e utilizar os relatórios/logs após cada execução.

## Como funciona

O diagnóstico ocorre em várias etapas. Cada etapa seguinte é ativada apenas se a anterior não resolveu o problema:

1. **Análise Básica** — lê o log de crash, procura candidatos no texto do erro e os isola por ordem de prioridade de dependência.
2. **Análise de Mixin** — analisa os erros `Mixin apply failed` e `@Mixin target not found`, identifica os mods de origem e destino, e verifica cada um em 1 ou 2 inicializações.
3. **Camadas (Layering)** — remove todos os mods, mantém as bibliotecas principais (core), e adiciona o restante em camadas (por níveis de dependência, em lotes exponenciais). Em caso de crash no lote — triagem e isolamento dentro do lote.
4. **Isolamento (Isolation)** — alternativa final: níveis baseados em dependências, testes exponenciais/binários em níveis iniciais e isolamento linear em níveis posteriores.
5. **Recuperação (Recovery)** — se 3 ou mais "culpados" apresentarem o mesmo erro de Mixin, o script verifica se foram falsos positivos e busca a verdadeira causa raiz.

Descrição detalhada do algoritmo em [doc/Algorithm.md](doc/Algorithm.md).

## Requisitos

- **Windows** (utiliza Win32 UI Automation)
- **PowerShell 5.1+**
- **Legacy Launcher** ([llaun.ch](https://llaun.ch/))
- Minecraft com **Fabric** ou **Forge**

## Dependências de desenvolvimento

- **PSScriptAnalyzer** (módulo PowerShell, necessário para `checker.ps1`)
- **Python 3.x** (necessário para verificação de localizações via `tools/Check-Localization.py`)

Instalação do `PSScriptAnalyzer`:
```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

## Início rápido

1. Clone o repositório ou baixe o arquivo da [versão mais recente](https://github.com/Artemonim/MCCompatibilityChecker/releases/latest):
   ```bash
   git clone https://github.com/Artemonim/MCCompatibilityChecker.git
   ```

2. Copie `config.ini` para `config.local.ini` e indique o caminho para sua pasta de mods:
   ```ini
   [Paths]
   GameModsDir=%APPDATA%\.tlauncher\legacy\Minecraft\game\mods
   ```

3. Abra o Minecraft Launcher.

4. Escreva `./run.ps1` ou `./run.ps1 -verbose` no console do PowerShell.

5. Passe o mouse sobre o botão de inicialização do cliente no launcher.

6. Pressione `Enter` para enviar o comando do console e permitir que o Checker obtenha as coordenadas do botão.

## Configuração

As configurações são definidas em `config.ini` (padrão) e `config.local.ini` (suas personalizações, ignorado pelo git).

| Parâmetro | Descrição |
|-----------|-----------|
| `GameModsDir` | Pasta de mods utilizada pelo jogo |
| `StorageModsDir` | Armazenamento principal de mods (opcional) |
| `LogPath` | Caminho para o arquivo de log do launcher (vazio para detecção automática) |
| `LauncherExePath` | Caminho para o executável do launcher (vazio para conectar a um já iniciado) |
| `EnableMixinAnalysis` | Ativar etapa de análise de Mixin (padrão: `true`) |
| `EnableLayering` | Ativar camadas e isolamento subtrativo (padrão: `true`) |
| `EnableRecovery` | Ativar recuperação de culpados fantasmas (padrão: `false`) |
| `Language` | Idioma das mensagens do console (`[Localization].Language`). Se vazio: automático pelo idioma do SO, padrão `en` |

Locais disponíveis no momento: `en`, `ru`.
Preparados para: `tr_TR`, `pt_BR`, `vi`, `es_ES`, `id_ID`, `zh-CN`.
A busca pela janela de crash do launcher reúne automaticamente padrões de `scripts/locales/*.psd1` (`Ui.CrashWindowTitlePatterns`).
Atualmente inclui `Something broke` / `Something went wrong` (en) e `Что-то сломалось...` (ru). Para novos idiomas, basta adicionar esta lista ao arquivo de locale correspondente.
Se o título da janela do seu launcher for diferente, você pode definir explicitamente `CrashWindowTitlePatterns` em `[Profile:<nome>]` e executar com `-Profile <nome>`.

## Principais parâmetros de inicialização

```bash
.\run.ps1 -Help          # Ajuda resumida
.\run.ps1 -HelpFull      # Ajuda técnica completa
```

| Flag | Descrição |
|------|-----------|
| `-LauncherExePath <caminho>` | Caminho para o launcher (se não especificado na config) |
| `-NoLegacy` | Não salvar mods isolados — excluí-los |
| `-GameLegacy` | Manter cópias dos mods isolados na pasta do jogo |
| `-DryRun` | Mostrar o que será feito sem execução real |
| `-Verbose` | Logs detalhados (no console e em `MCCC.log`) |
| `-UseLinearIsolation` | Busca linear em vez de binária (mais lento, porém mais simples) |
| `-NoCache` | Desativar cache de sessão (reverificar até mesmo configurações bem-sucedidas anteriormente) |
| `-ThoroughStabilityCheck` | Aumentar a janela de verificação de estabilidade das inicializações |
| `-AutoHandleFabricDialog <bool>` | Roteamento automático de diálogos do Fabric sem dependências ausentes |
| `-IgnoreModIds <id1,id2,...>` | Ignorar IDs de mods especificados na limpeza de compatibilidade |
| `-Profile <nome>` | Aplicar perfil de `[Profile:<nome>]` no `config.ini` / `config.local.ini` |

## Verificação de scripts e localizações

O `checker.ps1` verifica:
- Scripts PowerShell via `PSScriptAnalyzer`
- Recursos de localização via `tools/Check-Localization.py`
- Strings `Write-Verbose`/apenas depuração são consideradas de serviço, permanecem em inglês e não entram na cobertura de localização.

Exemplos:
```powershell
.\checker.ps1             # Verificação completa (incluindo locais)
.\checker.ps1 -NoLocales  # Pular verificação de locais
```

Comportamento na ausência do Python:
- Por padrão, isso é um **erro** (o verificador termina com código de erro) para não ignorar falhas no sistema de localização.
- Se você não estiver trabalhando com localização, use `-NoLocales`.

## Estrutura do projeto

```
├── run.ps1                  # Ponto de entrada
├── config.ini               # Configuração padrão
├── checker.ps1              # Linter + verificação de localizações
├── scripts/
│   ├── Auto-Run-LegacyLauncher.ps1      # Orquestrador: inicialização, monitoramento, ciclo
│   ├── Check-Mod-Compatibility.ps1      # Análise Básica
│   ├── Analyze-MixinErrors.ps1          # Análise de Mixin
│   ├── Layer-Mods.ps1                   # Camadas
│   ├── Isolate-Incompatible-Mod.ps1     # Isolamento (alternativa)
│   ├── Recover-PhantomCulprits.ps1      # Recuperação
│   └── Shared-*.ps1                     # Módulos compartilhados
├── tools/
│   ├── Analyze-JarDependencies.ps1      # Análise de dependências JAR
│   ├── Analyze-JarDependencyMap.ps1     # Construção do mapa de dependências
│   └── Restore-ModsFromLog.ps1          # Restauração de mods a partir do relatório
└── doc/
    └── Algorithm.md                     # Descrição detalhada do algoritmo
```

## Para onde vão os mods isolados

Por padrão, os mods isolados são movidos para a pasta `Legacy` dentro de `StorageModsDir` (ou `GameModsDir`, se o armazenamento não estiver definido). Isso permite restaurá-los manualmente com facilidade, caso o resultado do diagnóstico não o satisfaça.

A flag `-NoLegacy` exclui os mods permanentemente. A flag `-GameLegacy` salva adicionalmente uma cópia na pasta do jogo.

## Relatório final (Summary)

Após a conclusão, o script exibe um relatório: tempo de execução, lista de culpados por etapas, mods restaurados (se a Recuperação foi utilizada) e a lista atual de mods isolados.

## Limitações

- Funciona apenas com o Legacy Launcher (a automação da interface está vinculada a ele)
- Apenas Windows (Win32 API para gerenciamento de janelas)
- O diagnóstico requer múltiplas inicializações do jogo — em grandes coleções de mods, isso pode levar um tempo considerável
- Com grandes grupos de incompatibilidades, são possíveis execuções instáveis e interrupções precoces do diagnóstico
- A etapa de Recuperação é experimental no momento e está desativada por padrão
