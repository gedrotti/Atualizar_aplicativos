# Atualiza aplicativos no escopo do usuário pelo winget, sem solicitar UAC.
# Em caso de falha, salva e exibe os detalhes em C:\TEMP\Atualizar aplicativos.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

$logDirectory = 'C:\TEMP\Atualizar aplicativos'
$logFile = Join-Path $logDirectory ("winget-erros-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$failures = [System.Collections.Generic.List[object]]::new()

function Write-ProgressBar {
    param([int]$Current, [int]$Total, [string]$Name, [bool]$Succeeded)

    $width = 24
    $filled = [Math]::Floor(($Current / $Total) * $width)
    $bar = ('#' * $filled) + ('-' * ($width - $filled))
    $icon = if ($Succeeded) { '✓' } else { '✗' }
    $color = if ($Succeeded) { 'Green' } else { 'Red' }
    Write-Host ("  {0} [{1}] {2}/{3} - {4}" -f $icon, $bar, $Current, $Total, $Name) -ForegroundColor $color
}

function Get-WingetUpgrades {
    # Esta versão do winget não oferece saída JSON para o comando "upgrade".
    $queryOutput = & winget.exe upgrade --include-unknown --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    $queryExitCode = $LASTEXITCODE

    if ($queryExitCode -ne 0) {
        throw "Não foi possível consultar as atualizações (código $queryExitCode). $queryOutput"
    }

    $tableStarted = $false
    $packages = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ($queryOutput -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^-{3,}$') { $tableStarted = $true; continue }
        if (-not $tableStarted -or [string]::IsNullOrWhiteSpace($trimmed)) { continue }

        $columns = $trimmed -split '\s{2,}'
        if ($columns.Count -lt 4) { continue }

        $id = $columns[1]
        if ([string]::IsNullOrWhiteSpace($id) -or $id -eq 'Id') { continue }

        $packages.Add([PSCustomObject]@{
            PackageName       = $columns[0]
            PackageIdentifier = $id
            Source            = if ($columns.Count -ge 5) { $columns[$columns.Count - 1] } else { $null }
        })
    }
    return @($packages)
}

function Offer-PackageExclusion {
    param([object]$Failure)

    if ($Failure.Output -notmatch 'Nenhuma atualização aplicável foi encontrada') { return }

    Write-Host "`nA atualização de '$($Failure.Name)' não é aplicável a este computador." -ForegroundColor Yellow
    $answer = Read-Host "Deseja excluir '$($Failure.Name)' das próximas atualizações pelo winget? [S/N]"
    if ($answer -notmatch '^(s|sim)$') { return }

    $pinArguments = @('pin', 'add', '--id', $Failure.Id, '--exact', '--blocking', '--accept-source-agreements', '--disable-interactivity')
    if ($Failure.Source -and $Failure.Source -notmatch '^(Unknown|Disponível)$') {
        $pinArguments += @('--source', $Failure.Source)
    }

    $pinOutput = & winget.exe @pinArguments 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ '$($Failure.Name)' foi excluído das próximas atualizações." -ForegroundColor Green
    }
    else {
        Write-Host "Não foi possível excluir '$($Failure.Name)'. Veja os detalhes abaixo:" -ForegroundColor Red
        Write-Host $pinOutput
    }
}

try {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'O winget não foi encontrado. Instale ou atualize o App Installer pela Microsoft Store.'
    }

    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    Write-Host 'Verificando atualizações disponíveis...' -ForegroundColor Cyan
    $packages = @(Get-WingetUpgrades)

    if ($packages.Count -eq 0) {
        Write-Host 'Nenhuma atualização disponível.' -ForegroundColor Green
        exit 0
    }

    $total = $packages.Count
    Write-Host ("{0} atualização(ões) encontrada(s)." -f $total) -ForegroundColor Cyan

    for ($index = 0; $index -lt $total; $index++) {
        $package = $packages[$index]
        $current = $index + 1
        $id = $package.PackageIdentifier
        $name = $package.PackageName

        Write-Host ("`n[{0}/{1}] Atualizando: {2}" -f $current, $total, $name) -ForegroundColor White
        Write-Host '  [------------------------] Atualizando...' -ForegroundColor DarkCyan

        $arguments = @('upgrade', '--id', $id, '--exact', '--include-unknown', '--scope', 'user', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        if ($package.Source -and $package.Source -notmatch '^(Unknown|Disponível)$') {
            $arguments += @('--source', $package.Source)
        }

        $updateOutput = & winget.exe @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-ProgressBar -Current $current -Total $total -Name $name -Succeeded $true
        }
        else {
            Write-ProgressBar -Current $current -Total $total -Name $name -Succeeded $false
            $failures.Add([PSCustomObject]@{
                Name   = $name
                Id     = $id
                Source = $package.Source
                Code   = $exitCode
                Output = $updateOutput.Trim()
            })
        }
    }

    if ($failures.Count -gt 0) {
        $logLines = [System.Collections.Generic.List[string]]::new()
        $logLines.Add("Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $logLines.Add('Falhas durante a atualização pelo winget:')
        foreach ($failure in $failures) {
            $logLines.Add("===== $($failure.Name) ($($failure.Id)) - código $($failure.Code) =====")
            $logLines.Add($failure.Output)
        }
        [System.IO.File]::WriteAllLines($logFile, $logLines, [System.Text.UTF8Encoding]::new($true))

        Write-Host "`n===== LOG DE FALHAS: $logFile =====" -ForegroundColor Yellow
        Write-Host ([System.IO.File]::ReadAllText($logFile, [System.Text.UTF8Encoding]::new($true)))
        foreach ($failure in $failures) { Offer-PackageExclusion -Failure $failure }
        exit 1
    }

    Write-Host "`nAtualizações concluídas com sucesso." -ForegroundColor Green
}
catch {
    New-Item -ItemType Directory -Path $logDirectory -Force -ErrorAction SilentlyContinue | Out-Null
    $logLines = @(
        "Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Erro: $($_.Exception.Message)"
        'Detalhes:'
        $_ | Out-String
    )
    [System.IO.File]::WriteAllLines($logFile, [string[]]$logLines, [System.Text.UTF8Encoding]::new($true))

    Write-Host "`n===== LOG DE ERRO: $logFile =====" -ForegroundColor Red
    Write-Host ([System.IO.File]::ReadAllText($logFile, [System.Text.UTF8Encoding]::new($true)))
    exit 1
}
