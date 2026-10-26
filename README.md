# Atualizar Aplicativos

Script PowerShell para atualizar aplicativos instalados com o `winget`.

## Recursos

- Mostra o andamento de cada atualização com barra de progresso e indicadores ✓/✗.
- Executa atualizações no escopo do usuário, em modo silencioso, para evitar solicitações de UAC.
- Aceita automaticamente os termos de pacotes e fontes.
- Salva detalhes de falhas em `C:\TEMP\Atualizar aplicativos`.

## Como usar

1. Abra o PowerShell.
2. Vá até a pasta onde está o script.
3. Execute:

```powershell
.\Atualizar-Aplicativos.ps1
```

## Observações

- É necessário ter o **App Installer** instalado, pois ele fornece o comando `winget`.
- Aplicativos que exigem instalação no escopo da máquina não são atualizados pelo script para evitar janelas de elevação.
- O log é criado somente quando há falha.
