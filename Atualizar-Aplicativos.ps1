#Requires -Version 5.1
<#
.SYNOPSIS
    Atualiza aplicativos instalados usando o winget, sem solicitar UAC.

.DESCRIPTION
    Consulta as atualizações disponíveis, atualiza cada pacote no escopo do usuário
    em modo silencioso e registra o resultado em log.

    Aplicativos instalados no escopo da máquina são ignorados por padrão, pois exigem
    elevação. Use -IncludeMachineScope em um PowerShell aberto como Administrador para
    incluí-los.

.PARAMETER DryRun
    Apenas lista as atualizações disponíveis. Nada é instalado.

.PARAMETER NonInteractive
    Não faz perguntas. Útil para tarefas agendadas.

.PARAMETER AutoPinInapplicable
    Fixa automaticamente (winget pin add --blocking) os pacotes cuja atualização não é
    aplicável ao computador, para não tentar novamente nas próximas execuções.

.PARAMETER IncludeMachineScope
    Inclui aplicativos instalados para todos os usuários. Requer execução como
    Administrador.

.PARAMETER Include
    Lista de padrões (nome ou ID) que devem ser atualizados. Aceita curingas.
    Exemplo: -Include 'Microsoft.*','Google.Chrome'

.PARAMETER Exclude
    Lista de padrões (nome ou ID) que não devem ser atualizados. Aceita curingas.
    Exemplo: -Exclude 'Microsoft.Edge*','*Teams*'

.PARAMETER LogPath
    Arquivo .log ou diretório onde o log será gravado. Por padrão:
    %LOCALAPPDATA%\Atualizar-Aplicativos\logs

.PARAMETER Quiet
    Mostra apenas o resumo final e as falhas.

.EXAMPLE
    .\Atualizar-Aplicativos.ps1

.EXAMPLE
    .\Atualizar-Aplicativos.ps1 -DryRun

.EXAMPLE
    .\Atualizar-Aplicativos.ps1 -NonInteractive -AutoPinInapplicable -LogPath C:\Logs

.EXAMPLE
    .\Atualizar-Aplicativos.ps1 -Include 'Microsoft.*' -Exclude 'Microsoft.Edge*'
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NonInteractive,
    [switch]$AutoPinInapplicable,
    [switch]$IncludeMachineScope,
    [string[]]$Include,
    [string[]]$Exclude,
    [string]$LogPath,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $OutputEncoding = [Console]::OutputEncoding
}
catch {
    # Hosts sem console (por exemplo, tarefas agendadas) podem recusar a alteração.
    Write-Verbose 'Não foi possível definir a codificação de saída para UTF-8.'
}

$script:LogRetention = 10
$script:LogLines = [System.Collections.Generic.List[string]]::new()
$script:CanPrompt = (-not $NonInteractive) -and [Environment]::UserInteractive
$script:WingetSources = $null

function Add-LogLine {
    param([string]$Text)
    $script:LogLines.Add($Text)
}

function Get-WingetSource {
    <#
        Nomes das fontes configuradas. São usados para identificar a coluna de
        origem nas linhas da tabela do winget.
    #>
    if ($null -ne $script:WingetSources) { return $script:WingetSources }

    $sources = [System.Collections.Generic.List[string]]::new()
    $sources.Add('winget')
    $sources.Add('msstore')

    try {
        $raw = (& winget.exe source list 2>&1 | Out-String) -replace "`r", ''
        if ($LASTEXITCODE -eq 0) {
            $inTable = $false
            foreach ($line in ($raw -split "`n")) {
                if ($line.Trim() -match '^-{3,}$') { $inTable = $true; continue }
                if (-not $inTable -or [string]::IsNullOrWhiteSpace($line)) { continue }

                $first = (($line.Trim() -split '\s{2,}')[0]).Trim()
                if (-not $first -or $first -match '^(Nome|Name)$') { continue }
                if (-not ($sources -contains $first)) { $sources.Add($first) }
            }
        }
    }
    catch {
        # Em caso de falha, mantém as fontes padrão (winget e msstore).
        Write-Verbose "Não foi possível listar as fontes do winget: $($_.Exception.Message)"
    }

    $script:WingetSources = @($sources)
    return $script:WingetSources
}

function ConvertFrom-WingetUpgradeTable {
    <#
        Converte a tabela de "winget upgrade" em objetos.

        O winget não mantém as colunas alinhadas entre as linhas (um nome comprido
        desloca as colunas seguintes), então a leitura é feita da direita para a
        esquerda: origem, versão disponível, versão instalada e ID são os últimos
        campos; o que sobrar é o nome do pacote.
    #>
    param(
        [string]$Text,
        [string[]]$Sources
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $lines = ($Text -replace "`r", '') -split "`n"
    $separatorIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -match '^-{3,}$') { $separatorIndex = $i; break }
    }
    if ($separatorIndex -lt 0) {
        # Sem tabela: normalmente significa que não há atualizações disponíveis.
        return @()
    }

    $packages = [System.Collections.Generic.List[object]]::new()
    for ($i = $separatorIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $tokens = @($line -split '\s+')
        $hasSource = $false
        if ($tokens.Count -ge 2) {
            $last = $tokens[$tokens.Count - 1]
            foreach ($source in $Sources) {
                if ($source -eq $last -or ($last.Length -ge 2 -and $source.StartsWith($last, [System.StringComparison]::OrdinalIgnoreCase))) {
                    $hasSource = $true
                    break
                }
            }
        }

        $offset = 0
        if ($hasSource) { $offset = 1 }

        # Uma linha válida tem, no mínimo: nome, ID, versão e versão disponível.
        if ($tokens.Count -lt (4 + $offset)) { break }

        $id = $tokens[$tokens.Count - 3 - $offset]
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+~\-]*$') { break }

        $name = ($tokens[0..($tokens.Count - 4 - $offset)] -join ' ')
        if ([string]::IsNullOrWhiteSpace($name)) { break }

        $packages.Add([PSCustomObject]@{
                Name              = $name
                PackageIdentifier = $id
                Version           = $tokens[$tokens.Count - 2 - $offset]
                Available         = $tokens[$tokens.Count - 1 - $offset]
            })
    }

    if ($packages.Count -eq 0) {
        throw 'A tabela do winget foi encontrada, mas nenhuma atualização pôde ser interpretada.'
    }

    return @($packages)
}

function Get-WingetPackage {
    param([switch]$MachineScope)

    $queryArgs = @('upgrade', '--include-unknown', '--accept-source-agreements', '--disable-interactivity')
    if (-not $MachineScope) { $queryArgs += @('--scope', 'user') }

    $raw = (& winget.exe @queryArgs 2>&1 | Out-String) -replace "`r", ''
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Não foi possível consultar as atualizações (código $exitCode).`n$($raw.Trim())"
    }

    return @(ConvertFrom-WingetUpgradeTable -Text $raw -Sources (Get-WingetSource))
}

function Test-PackagePattern {
    param(
        [string]$Id,
        [string]$Name,
        [string[]]$Patterns
    )

    if (-not $Patterns -or $Patterns.Count -eq 0) { return $false }
    foreach ($pattern in $Patterns) {
        if ($Id -like $pattern -or $Name -like $pattern) { return $true }
    }
    return $false
}

function Get-LogFilePath {
    param([string]$Requested)

    $fileName = 'winget-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    if ($Requested) {
        if ([System.IO.Path]::GetExtension($Requested) -ieq '.log') { return $Requested }
        return (Join-Path $Requested $fileName)
    }

    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TEMP }
    return (Join-Path (Join-Path $base 'Atualizar-Aplicativos\logs') $fileName)
}

function Save-SessionLog {
    param([string]$Path)

    try {
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        [System.IO.File]::WriteAllLines($Path, [string[]]$script:LogLines, [System.Text.UTF8Encoding]::new($true))
        return $true
    }
    catch {
        Write-Host "Não foi possível gravar o log em '$Path': $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Remove-OldLog {
    param([string]$Directory)

    try {
        $files = @(Get-ChildItem -LiteralPath $Directory -Filter 'winget-*.log' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
        if ($files.Count -le $script:LogRetention) { return }
        $files | Select-Object -Skip $script:LogRetention | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        # Limpeza de logs é best-effort.
        Write-Verbose "Não foi possível remover logs antigos: $($_.Exception.Message)"
    }
}

function Write-SummaryLine {
    param(
        [string]$Status,
        [string]$Name,
        [int]$Current,
        [int]$Total,
        [double]$Seconds
    )

    $symbol = '-'
    $color = 'Yellow'
    if ($Status -eq 'Updated') { $symbol = '✓'; $color = 'Green' }
    elseif ($Status -eq 'Failed') { $symbol = '✗'; $color = 'Red' }

    $width = 20
    $filled = [Math]::Floor(($Current / $Total) * $width)
    $bar = ('#' * $filled) + ('-' * ($width - $filled))
    Write-Host ("  {0} [{1}] {2}/{3} - {4} ({5:N1}s)" -f $symbol, $bar, $Current, $Total, $Name, $Seconds) -ForegroundColor $color
}

function Set-WingetPin {
    param(
        [string]$Id,
        [string]$Name
    )

    $pinArgs = @('pin', 'add', '--id', $Id, '--exact', '--blocking', '--accept-source-agreements', '--disable-interactivity')
    $pinOutput = (& winget.exe @pinArgs 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ '$Name' foi fixado e não será tentado novamente." -ForegroundColor Green
        Write-Host "    Para reverter: winget pin remove --id $Id" -ForegroundColor DarkGray
        Add-LogLine "Pin: $Id -> OK"
        Add-LogLine ''
        return $true
    }

    Write-Host "  ✗ Não foi possível fixar '$Name'." -ForegroundColor Red
    if ($pinOutput) { Write-Host $pinOutput }
    Add-LogLine "Pin: $Id -> FALHOU: $pinOutput"
    Add-LogLine ''
    return $false
}

$startedAt = Get-Date
$logFile = Get-LogFilePath -Requested $LogPath
$exitCode = 0

try {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'O winget não foi encontrado. Instale ou atualize o App Installer pela Microsoft Store.'
    }

    $wingetVersion = (& winget.exe --version 2>&1 | Out-String).Trim()

    $isAdministrator = $false
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        $isAdministrator = $false
    }

    if ($IncludeMachineScope -and -not $isAdministrator) {
        throw 'A opção -IncludeMachineScope exige privilégios de Administrador. Abra o PowerShell como Administrador ou remova a opção.'
    }

    $scopeLabel = if ($IncludeMachineScope) { 'usuário e máquina (elevado)' } else { 'usuário' }

    Add-LogLine ("Data: {0}" -f $startedAt.ToString('yyyy-MM-dd HH:mm:ss'))
    Add-LogLine ("Computador: {0}" -f $env:COMPUTERNAME)
    Add-LogLine ("Usuário: {0}" -f [Environment]::UserName)
    Add-LogLine ("Winget: {0}" -f $wingetVersion)
    Add-LogLine ("Escopo: {0}" -f $scopeLabel)
    Add-LogLine ''

    Write-Host 'Verificando atualizações disponíveis...' -ForegroundColor Cyan
    $packages = @(Get-WingetPackage -MachineScope:$IncludeMachineScope | Where-Object { $_ })

    if ($packages.Count -eq 0) {
        if (-not $IncludeMachineScope) {
            $allPackages = @(Get-WingetPackage -MachineScope | Where-Object { $_ })
            if ($allPackages.Count -gt 0) {
                Write-Host ("Nenhuma atualização no escopo do usuário. {0} atualização(ões) exigem Administrador (-IncludeMachineScope)." -f $allPackages.Count) -ForegroundColor Yellow
                Add-LogLine ("Atualizações fora do escopo do usuário: {0}" -f $allPackages.Count)
                exit 0
            }
        }

        Write-Host 'Nenhuma atualização disponível.' -ForegroundColor Green
        Add-LogLine 'Nenhuma atualização disponível.'
        exit 0
    }

    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($package in $packages) {
        if ($Include -and -not (Test-PackagePattern -Id $package.PackageIdentifier -Name $package.Name -Patterns $Include)) {
            continue
        }
        if ($Exclude -and (Test-PackagePattern -Id $package.PackageIdentifier -Name $package.Name -Patterns $Exclude)) {
            continue
        }
        $selected.Add($package)
    }

    $filteredOut = $packages.Count - $selected.Count
    Write-Host ("{0} atualização(ões) encontrada(s)." -f $packages.Count) -ForegroundColor Cyan
    if ($filteredOut -gt 0) {
        Write-Host ("{0} ignorada(s) pelos filtros -Include/-Exclude." -f $filteredOut) -ForegroundColor DarkYellow
        Add-LogLine ("Pacotes ignorados por filtros: {0}" -f $filteredOut)
    }

    if ($selected.Count -eq 0) {
        Write-Host 'Nenhuma atualização corresponde aos filtros informados.' -ForegroundColor Yellow
        Add-LogLine 'Nenhuma atualização corresponde aos filtros informados.'
        exit 0
    }

    if ($DryRun) {
        Write-Host "`nModo de simulação: nada será instalado." -ForegroundColor Yellow
        foreach ($package in $selected) {
            Write-Host ("  - {0} ({1}) {2} -> {3}" -f $package.Name, $package.PackageIdentifier, $package.Version, $package.Available)
        }
        Write-Host ("`n{0} pacote(s) seriam atualizados." -f $selected.Count) -ForegroundColor Cyan
        exit 0
    }

    $total = $selected.Count
    $updated = 0
    $failed = 0
    $skipped = 0
    $pinned = 0
    $rebootRequired = $false

    for ($index = 0; $index -lt $total; $index++) {
        $package = $selected[$index]
        $current = $index + 1
        $id = $package.PackageIdentifier
        $name = $package.Name

        if (-not $Quiet) {
            Write-Host ("`n[{0}/{1}] Atualizando: {2} ({3})" -f $current, $total, $name, $id) -ForegroundColor White
        }

        $arguments = @(
            'upgrade', '--id', $id, '--exact', '--include-unknown', '--silent',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        )
        if (-not $IncludeMachineScope) { $arguments += @('--scope', 'user') }

        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $output = (& winget.exe @arguments 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
        $timer.Stop()
        $seconds = $timer.Elapsed.TotalSeconds
        $status = 'Failed'

        if ($code -eq 0) {
            $status = 'Updated'
            $updated++
        }
        elseif ($code -eq 3010 -or $code -eq 1641) {
            $status = 'Updated'
            $updated++
            $rebootRequired = $true
        }
        elseif ($code -eq -1978335189) {
            # 0x8A15002B: nenhuma atualização aplicável ao computador.
            $status = 'NotApplicable'
            $skipped++
        }
        else {
            $failed++
        }

        $statusLabel = switch ($status) {
            'Updated' { 'Atualizado' }
            'Failed' { 'Falhou' }
            default { 'Não aplicável' }
        }

        Add-LogLine ("===== {0} ({1}) =====" -f $name, $id)
        Add-LogLine ("Status: {0} | Código: {1} | Duração: {2:N1}s" -f $statusLabel, $code, $seconds)
        if ($output) { Add-LogLine $output }
        Add-LogLine ''

        if ($status -eq 'NotApplicable') {
            if (-not $Quiet) {
                Write-Host ("  - {0}: atualização não aplicável a este computador." -f $name) -ForegroundColor Yellow
            }

            if ($AutoPinInapplicable) {
                if (Set-WingetPin -Id $id -Name $name) { $pinned++ }
            }
            elseif ($script:CanPrompt) {
                $answer = Read-Host "    Deseja fixar '$name' para não tentar novamente? [s/N]"
                if ($answer -match '^(s|sim|y|yes)$') {
                    if (Set-WingetPin -Id $id -Name $name) { $pinned++ }
                }
            }
        }

        if (-not $Quiet) {
            if ($status -ne 'NotApplicable') {
                Write-SummaryLine -Status $status -Name $name -Current $current -Total $total -Seconds $seconds
            }
        }
        elseif ($status -eq 'Failed') {
            Write-Host ("  ✗ {0} (código {1})" -f $name, $code) -ForegroundColor Red
        }
    }

    $duration = (Get-Date) - $startedAt
    $summary = "Resumo: {0} atualizado(s), {1} falha(s), {2} ignorado(s), {3} fixado(s) em {4:hh\:mm\:ss}." -f `
        $updated, $failed, $skipped, $pinned, $duration

    Add-LogLine $summary
    if ($rebootRequired) { Add-LogLine 'Reinício necessário para concluir uma ou mais atualizações.' }

    Write-Host "`n$summary" -ForegroundColor Cyan
    if ($rebootRequired) {
        Write-Host 'Reinicie o computador para concluir as atualizações pendentes.' -ForegroundColor Yellow
    }

    if ($failed -gt 0) { $exitCode = 1 }

    if (Save-SessionLog -Path $logFile) {
        Write-Host ("Log: {0}" -f $logFile) -ForegroundColor DarkGray
        Remove-OldLog -Directory (Split-Path -Parent $logFile)
    }
}
catch {
    $message = $_.Exception.Message
    Write-Host "`nErro: $message" -ForegroundColor Red

    Add-LogLine ("Data: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Add-LogLine 'Erro fatal:'
    Add-LogLine $message
    if ($_.ScriptStackTrace) { Add-LogLine $_.ScriptStackTrace }

    if (Save-SessionLog -Path $logFile) {
        Write-Host ("Log: {0}" -f $logFile) -ForegroundColor DarkGray
        Remove-OldLog -Directory (Split-Path -Parent $logFile)
    }
    $exitCode = 2
}

exit $exitCode
