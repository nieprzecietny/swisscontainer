<#
.SYNOPSIS
  Ansible Vault w izolowanym kontenerze: bez sieci, read-only, haslo tylko interaktywnie.

.DESCRIPTION
  Uruchamiaj WYLACZNIE z terminala Windows - nie z devcontainera i nie z terminala VS Code
  podlaczonego do devcontainera (rozszerzenia agentow AI widza otwarte pliki i terminale).

  Zainstaluj kopie POZA repozytorium, np. %USERPROFILE%\bin\vault.ps1 - agenci AI moga
  modyfikowac pliki w repo, wiec skrypt uruchamiany na hoscie nie moze lezec tam, gdzie oni pisza.

  Dozwolone akcje: view, edit, create, encrypt, rekey.
  'decrypt' jest celowo zablokowane - zapisaloby jawna tresc do wspolnego repo.

.EXAMPLE
  vault.ps1 edit group_vars/prod/vault.yml -Path D:\repo\aplikacja

.EXAMPLE
  vault.ps1 view group_vars/prod/vault.yml -Volume aplikacja-vol -Repo aplikacja

.EXAMPLE
  vault.ps1 create group_vars/dev/vault.yml -Path . -Editor nano -DryRun
#>
[CmdletBinding(DefaultParameterSetName = 'Path')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('view', 'edit', 'create', 'encrypt', 'rekey')]
    [string]$Action,

    [Parameter(Mandatory, Position = 1)]
    [string]$File,

    # Katalog repo na dysku hosta (bind mount)
    [Parameter(Mandatory, ParameterSetName = 'Path')]
    [string]$Path,

    # ...albo wolumen Dockera z repo ("Clone Repository in Container Volume")
    [Parameter(Mandatory, ParameterSetName = 'Volume')]
    [string]$Volume,

    # Podkatalog repo wewnatrz wolumenu
    [Parameter(ParameterSetName = 'Volume')]
    [string]$Repo = '',

    [ValidateSet('micro', 'nano')]
    [string]$Editor = 'micro',

    # Tylko wypisz polecenie docker, nic nie uruchamiaj
    [switch]$DryRun
)

# Obraz budowany z host/ansible-vault/Dockerfile:
#   docker build -t ansible-vault-local:2.22.0 host/ansible-vault
# W SWOJEJ KOPII (%USERPROFILE%\bin\vault.ps1) wpisz ID zbudowanego obrazu:
#   docker image inspect ansible-vault-local:2.22.0 --format '{{.Id}}'
# Po kazdym przebudowaniu obrazu: najpierw przejrzyj zmiany w Dockerfile, potem zaktualizuj ID.
# Wersja w repozytorium ma puste ID i celowo odmawia dzialania.
$Image           = 'ansible-vault-local:2.22.0'
$ExpectedImageId = ''

function Fail([string]$msg) { $Host.UI.WriteErrorLine("vault.ps1: $msg"); exit 1 }

if (-not $ExpectedImageId) {
    Fail ("Brak ExpectedImageId. Skopiuj skrypt do %USERPROFILE%\bin i wpisz ID obrazu:`n" +
          "  docker image inspect $Image --format '{{.Id}}'")
}

if ($env:REMOTE_CONTAINERS -or $env:DEVCONTAINER -or $env:CODESPACES) {
    Fail 'vault.ps1 uruchamiaj tylko na hoscie Windows, nie w devcontainerze.'
}

function Test-RelativeSafe([string]$p) {
    $n = $p -replace '\\', '/'
    return -not ($n -match '^(/|[A-Za-z]:)' -or ($n -split '/') -contains '..')
}

if (-not (Test-RelativeSafe $File)) { Fail "Plik musi byc sciezka wzgledna w repo, bez '..': $File" }
if ($Repo -and -not (Test-RelativeSafe $Repo)) { Fail "Repo musi byc sciezka wzgledna w wolumenie, bez '..': $Repo" }
$rel = $File -replace '\\', '/'

$actualId = docker image inspect $Image --format '{{.Id}}' 2>$null
if ($LASTEXITCODE -ne 0 -or -not $actualId) {
    Fail "Brak obrazu $Image. Zbuduj: docker build -t $Image host/ansible-vault"
}
$actualId = "$actualId".Trim()
if ($actualId -ne $ExpectedImageId) {
    Fail ("Obraz $Image ma ID $actualId, oczekiwano $ExpectedImageId.`n" +
          "Przejrzyj zmiany w host/ansible-vault/Dockerfile i dopiero wtedy zaktualizuj ExpectedImageId.")
}

if ($PSCmdlet.ParameterSetName -eq 'Path') {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) { Fail "Brak katalogu: $Path" }
    $mount   = "type=bind,source=$($resolved.ProviderPath),target=/work"
    $workdir = '/work'
} else {
    $null = docker volume inspect $Volume --format '{{.Name}}' 2>$null
    if ($LASTEXITCODE -ne 0) { Fail "Brak wolumenu Dockera: $Volume" }
    $mount   = "type=volume,source=$Volume,target=/work"
    $workdir = if ($Repo) { '/work/' + ($Repo -replace '\\', '/').Trim('/') } else { '/work' }
}

$dockerArgs = @(
    'run', '--rm', '-it',
    '--network', 'none',                                  # zero sieci
    '--read-only', '--tmpfs', '/tmp:rw,nosuid,size=32m',  # pliki tymczasowe edit tylko w pamieci
    '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
    '-e', 'ANSIBLE_CONFIG=/etc/ansible/ansible.cfg',      # ansible.cfg z repo ignorowane
    '-e', "EDITOR=$Editor",
    '--mount', $mount,
    '-w', $workdir,
    $actualId,                                            # po ID, nie po tagu
    $Action, '--ask-vault-pass', $rel
)

if ($DryRun) {
    Write-Output ('docker ' + ($dockerArgs -join ' '))
    exit 0
}

& docker @dockerArgs
exit $LASTEXITCODE
