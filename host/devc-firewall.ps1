<#
.SYNOPSIS
  Prywatne profile firewalla devcontainera w wolumenie Dockera `devc-firewall` (plan 4.3, D37).

.DESCRIPTION
  Wolumen jest montowany w devcontainerze TYLKO DO ODCZYTU (/etc/devc/firewall/local), pliki są czytelne
  wyłącznie dla roota (0600) — agent w kontenerze ich nie zmieni ani nie przeczyta.
  Uruchamiaj NA HOŚCIE (Windows, PowerShell 5.1+). Operacje wykonuje jednorazowy kontener bez sieci.

  devc-firewall.ps1 list
  devc-firewall.ps1 show   <profil>
  devc-firewall.ps1 import <plik> [profil]      # profil = nazwa pliku bez rozszerzenia, jeśli nie podano
  devc-firewall.ps1 edit   <profil>             # Notatnik; po zamknięciu zapis do wolumenu
  devc-firewall.ps1 remove <profil>

  Format profilu: jedna pozycja na linię — domena (obejmuje subdomeny) | IPv4 | IPv4/CIDR; `#` = komentarz.
  Po zmianie: przebuduj/zrestartuj devcontainer i dopisz profil do DEVC_FIREWALL_PROFILES w devcontainer.json.

.PARAMETER Volume
  Nazwa wolumenu (domyślnie devc-firewall; do testów np. devc-firewall-test).
.PARAMETER Image
  Obraz do jednorazowych operacji (domyślnie devc-universal:dev — zawiera listę profili publicznych).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('list', 'show', 'import', 'edit', 'remove')]
    [string]$Action,
    [Parameter(Position = 1)] [string]$Arg1,
    [Parameter(Position = 2)] [string]$Arg2,
    [string]$Volume = 'devc-firewall',
    [string]$Image = 'devc-universal:dev'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Test-ProfileName([string]$Name) {
    if ($Name -notmatch '^[a-z0-9][a-z0-9-]{0,40}$') { throw "Niepoprawna nazwa profilu '$Name' (małe litery, cyfry, '-')." }
}
if ($Volume -notmatch '^devc-firewall[a-z0-9-]*$') { throw "Wolumen musi się nazywać devc-firewall… (jest: $Volume)." }

# Jednorazowy kontener: bez sieci, bez capabilities, root (pliki w wolumenie należą do roota).
function Invoke-Vol([string]$Script, [string]$InputText = $null, [switch]$ReadOnly) {
    $mode = if ($ReadOnly) { 'ro' } else { 'rw' }
    $dockerArgs = @('run', '--rm', '-i', '--network', 'none', '--cap-drop', 'ALL', '--cap-add', 'CHOWN', '--cap-add', 'FOWNER',
              '--security-opt', 'no-new-privileges', '-u', '0:0', '--entrypoint', '/bin/sh',
              '-v', "${Volume}:/data:$mode", $Image, '-c', $Script)
    if ($null -ne $InputText) {
        $prev = $OutputEncoding
        $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        try { $out = $InputText | & docker @dockerArgs } finally { $OutputEncoding = $prev }
    } else {
        $out = & docker @dockerArgs
    }
    if ($LASTEXITCODE -ne 0) { throw "docker zakończył się kodem $LASTEXITCODE" }
    return $out
}

function Get-PublicProfiles {
    $names = & docker run --rm --network none --entrypoint /bin/sh $Image -c 'ls /etc/devc/firewall/profiles' 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Nie udało się odczytać profili publicznych z obrazu $Image (zbudowany?)." }
    return @($names | ForEach-Object { $_ -replace '\.txt$', '' })
}

function ConvertTo-ProfileText([string]$Raw) {
    # Normalizacja: LF, walidacja pozycji (błędne linie odrzucone z ostrzeżeniem — jak w kontenerze)
    $ok = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Raw -split "`r?`n")) {
        $entry = ($line -replace '#.*$', '').Trim().ToLowerInvariant() -replace '^\*\.', ''
        if ($entry -eq '') { if ($line.Trim().StartsWith('#')) { $ok.Add($line.Trim()) }; continue }
        if ($entry -match '^(\d{1,3}\.){3}\d{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$' -or
            $entry -match '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$') {
            $ok.Add($entry)
        } else {
            Write-Warning "Pomijam niepoprawną pozycję: '$line'"
        }
    }
    return (($ok -join "`n") + "`n")
}

function Save-Profile([string]$Name, [string]$Raw) {
    Test-ProfileName $Name
    if ((Get-PublicProfiles) -contains $Name) { throw "Profil '$Name' koliduje z publicznym profilem o tej nazwie — wybierz inną." }
    $text = ConvertTo-ProfileText $Raw
    Invoke-Vol -InputText $text -Script "set -e; chown 0:0 /data; chmod 0700 /data; tr -d '\r' | sed '1s/^\xEF\xBB\xBF//' > /data/.tmp-$Name; chmod 0600 /data/.tmp-$Name; mv -f /data/.tmp-$Name /data/$Name.txt" | Out-Null
    Write-Host "Zapisano profil '$Name' w wolumenie $Volume ($((($text -split "`n") | Where-Object { $_ -and -not $_.StartsWith('#') }).Count) pozycji)."
}

switch ($Action) {
    'list' {
        & docker volume inspect $Volume *> $null
        if ($LASTEXITCODE -ne 0) { Write-Host "Wolumen $Volume nie istnieje (brak prywatnych profili)."; break }
        Invoke-Vol -ReadOnly -Script 'for f in /data/*.txt; do [ -e "$f" ] && basename "$f" .txt; done; true'
    }
    'show' {
        Test-ProfileName $Arg1
        Invoke-Vol -ReadOnly -Script "cat /data/$Arg1.txt"
    }
    'import' {
        if (-not $Arg1) { throw 'Podaj plik: devc-firewall.ps1 import <plik> [profil]' }
        $path = (Resolve-Path -LiteralPath $Arg1).Path
        $name = if ($Arg2) { $Arg2 } else { [IO.Path]::GetFileNameWithoutExtension($path).ToLowerInvariant() }
        Save-Profile $name ([IO.File]::ReadAllText($path))
    }
    'edit' {
        Test-ProfileName $Arg1
        $tmp = Join-Path $env:TEMP "devc-firewall-$Arg1.txt"
        $current = ''
        try { $current = (Invoke-Vol -ReadOnly -Script "cat /data/$Arg1.txt 2>/dev/null || true") -join "`r`n" } catch { }
        [IO.File]::WriteAllText($tmp, $current)
        Start-Process -FilePath notepad.exe -ArgumentList "`"$tmp`"" -Wait
        Save-Profile $Arg1 ([IO.File]::ReadAllText($tmp))
        Remove-Item -LiteralPath $tmp -Force
    }
    'remove' {
        Test-ProfileName $Arg1
        Invoke-Vol -Script "rm -f /data/$Arg1.txt" | Out-Null
        Write-Host "Usunięto profil '$Arg1' z wolumenu $Volume."
    }
}
