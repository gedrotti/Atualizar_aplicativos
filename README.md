# Atualizar Aplicativos

[![PSScriptAnalyzer](https://github.com/gedrotti/Atualizar_aplicativos/actions/workflows/powershell.yml/badge.svg)](https://github.com/gedrotti/Atualizar_aplicativos/actions/workflows/powershell.yml)

Script PowerShell para atualizar aplicativos instalados com o `winget` no escopo do usuário, sem solicitar UAC.

## Recursos

- Consulta e atualiza cada pacote individualmente, em modo silencioso.
- Não pede elevação: por padrão, considera apenas aplicativos instalados no escopo do usuário.
- Barra de progresso, tempo por pacote e resumo final (atualizados, falhas, ignorados).
- Trata códigos de saída do winget, inclusive **reinício pendente** (`3010`) e **atualização não aplicável** (`0x8A15002B`).
- Filtros por nome ou ID (`-Include` / `-Exclude`), simulação (`-DryRun`) e modo para tarefas agendadas (`-NonInteractive`).
- Log completo em UTF-8, com retenção automática dos 10 mais recentes.
- Detecção de falha por código de saída, sem depender do idioma do Windows.

## Requisitos

- Windows 10 (1809 ou superior) ou Windows 11.
- [App Installer](https://apps.microsoft.com/detail/9nblggh4nns1) com o comando `winget` disponível.
- PowerShell 5.1 ou superior (já incluído no Windows).

## Como usar

1. Baixe o `Atualizar-Aplicativos.ps1` ou clone o repositório.
2. Abra o PowerShell na pasta do script.
3. Execute:

```powershell
.\Atualizar-Aplicativos.ps1
```

Se a política de execução bloquear:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Atualizar-Aplicativos.ps1
```

### Exemplos

```powershell
# Apenas mostra o que seria atualizado
.\Atualizar-Aplicativos.ps1 -DryRun

# Sem perguntas, fixando o que não for aplicável (ideal para agendamento)
.\Atualizar-Aplicativos.ps1 -NonInteractive -AutoPinInapplicable

# Só aplicativos da Microsoft e do Google, exceto o Edge
.\Atualizar-Aplicativos.ps1 -Include 'Microsoft.*','Google.*' -Exclude 'Microsoft.Edge*'

# Log em um arquivo específico
.\Atualizar-Aplicativos.ps1 -LogPath 'D:\Logs\winget.log'

# Incluir aplicativos instalados para todos os usuários (PowerShell como Administrador)
.\Atualizar-Aplicativos.ps1 -IncludeMachineScope
```

## Parâmetros

| Parâmetro | Descrição |
| --- | --- |
| `-DryRun` | Lista as atualizações disponíveis sem instalar nada. |
| `-NonInteractive` | Não faz perguntas. Recomendado para tarefas agendadas. |
| `-AutoPinInapplicable` | Fixa automaticamente (`winget pin add --blocking`) os pacotes cuja atualização não é aplicável, para não tentar novamente. |
| `-IncludeMachineScope` | Inclui aplicativos instalados para todos os usuários. **Exige PowerShell como Administrador.** |
| `-Include` | Padrões de nome ou ID que devem ser atualizados. Aceita curingas. |
| `-Exclude` | Padrões de nome ou ID que não devem ser atualizados. Aceita curingas. |
| `-LogPath` | Arquivo `.log` ou diretório do log. Padrão: `%LOCALAPPDATA%\Atualizar-Aplicativos\logs`. |
| `-Quiet` | Mostra apenas o resumo e as falhas. |

## Escopo e UAC

Por padrão, o script consulta com `--scope user` e atualiza com `--scope user`. Isso significa que **aplicativos instalados para todos os usuários não aparecem na lista**, pois exigiriam elevação.

Se houver atualizações apenas fora do escopo do usuário, o script avisa e sugere `-IncludeMachineScope`. Nesse modo, execute o PowerShell como Administrador; o script **não se auto-eleva** e não abre janelas de UAC sozinho.

## Logs

O log é gravado em `%LOCALAPPDATA%\Atualizar-Aplicativos\logs\winget-AAAAMMDD-HHMMSS.log` e contém:

- versão do winget, escopo, computador e usuário;
- status, código de saída e duração de cada pacote;
- saída do winget para diagnóstico;
- resumo final.

Os 10 logs mais recentes são mantidos. Use `-LogPath` para gravar em outro local. A simulação (`-DryRun`) não gera log.

## Códigos de saída

| Código | Significado |
| --- | --- |
| `0` | Todas as atualizações concluídas (ou nada a fazer). |
| `1` | Uma ou mais atualizações falharam. |
| `2` | Erro fatal (winget ausente, tabela não interpretada, falta de privilégio etc.). |

## Fixar e desafixar pacotes

Quando uma atualização não é aplicável, o script pode fixar o pacote para não tentar novamente:

```powershell
# Automático
.\Atualizar-Aplicativos.ps1 -AutoPinInapplicable

# Manual, durante a execução: responda "s" na pergunta
.\Atualizar-Aplicativos.ps1
```

Para reverter:

```powershell
winget pin remove --id <ID do pacote>
```

## Agendamento

Exemplo de tarefa semanal, executada com o usuário conectado (não use SYSTEM: o winget precisa do perfil do usuário):

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Atualizar-Aplicativos.ps1" -NonInteractive'

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 09:00

Register-ScheduledTask -TaskName 'Atualizar Aplicativos' `
    -Action $action -Trigger $trigger -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable)
```

## Solução de problemas

- **"Nenhuma atualização no escopo do usuário"**: as atualizações disponíveis são de aplicativos instalados para todos os usuários. Rode como Administrador com `-IncludeMachineScope`.
- **"O winget não foi encontrado"**: instale ou atualize o App Installer pela Microsoft Store.
- **"Nenhuma atualização pôde ser interpretada"**: a saída do winget mudou ou a tabela foi truncada. Atualize o winget (`winget upgrade Microsoft.AppInstaller`) e, se persistir, abra uma issue com o log.
- **Log com acentos estranhos**: abra o arquivo no VS Code ou Bloco de Notas; ele é UTF-8 com BOM.

## Licença

[MIT](LICENSE) © 2026 Germano Andre Pedrotti
