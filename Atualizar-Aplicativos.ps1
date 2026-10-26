# Atualiza aplicativos no escopo do usuário pelo winget, sem solicitar UAC.
# Em caso de falha, salva os detalhes em C:\TEMP\Atualizar aplicativos.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

$logDirectory = 'C:\TEMP\Atualizar aplicativos'
$logFile = Join-Path $logDirectory ("winget-erros-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$failures = [System.Collections.Generic.List[string]]::new()

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
    # O winget desta máquina não oferece saída JSON para "upgrade".
    # Lê a tabela padrão: Nome | Id | Versão | Disponível | Fonte.
    $queryOutput = & winget.exe upgrade --include-unknown --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    $queryExitCode = $LASTEXITCODE

    if ($queryExitCode -ne 0) {
        throw "Não foi possível consultar as atualizações (código $queryExitCode). $queryOutput"
    }

    $lines = $queryOutput -split "`r?`n"
    $tableStarted = $false
    $packages = [System.Collections.Generic.List[object]]::new()

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed -match '^-{3,}$') {
            $tableStarted = $true
            continue
        }
        if (-not $tableStarted -or [string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        # As colunas de winget são separadas por pelo menos dois espaços.
        $columns = $trimmed -split '\s{2,}'
        if ($columns.Count -lt 4) {
            continue
        }

        $id = $columns[1]
        if ([string]::IsNullOrWhiteSpace($id) -or $id -eq 'Id') {
            continue
        }

        $source = if ($columns.Count -ge 5) { $columns[$columns.Count - 1] } else { $null }
        $packages.Add([PSCustomObject]@{
            PackageName = $columns[0]
            PackageIdentifier = $id
            Source = $source
        })
    }

    return @($packages)
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
            $failures.Add(("===== {0} ({1}) - código {2} =====`r`n{3}" -f $name, $id, $exitCode, $updateOutput))
        }
    }

    if ($failures.Count -gt 0) {
        $logLines = @(
            "Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            'Falhas durante a atualização pelo winget:'
            $failures
        )
        [System.IO.File]::WriteAllLines($logFile, [string[]]$logLines, [System.Text.UTF8Encoding]::new($true))
        Write-Host "`nHouve falhas. Detalhes salvos em: $logFile" -ForegroundColor Yellow
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

    Write-Host "`nOcorreu um erro. Registro salvo em: $logFile" -ForegroundColor Red
    exit 1
}
