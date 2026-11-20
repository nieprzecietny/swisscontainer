# swisscontainer

Uniwersalny devcontainer (VS Code Dev Containers) do pracy z agentami AI — **Claude Code, Codex, Gemini CLI** —
w izolowanym środowisku. Jeden kontener, wszystko w środku:

- **.NET** 8 / 10 / 11 + Aspire · **PHP 8.5** + Symfony CLI · **Node** 22 / 24 / 26 (fnm) · **Python** + Ansible
- usługi: **SQL Server 2025**, **MariaDB**, phpMyAdmin, RabbitMQ, Mailpit
- serwowanie per stos z hot reload: `dotnet watch` / Aspire / Traefik, Symfony CLI / Apache + PHP-FPM, Vite / nginx

> **Status: w budowie.** Gotowe etapy 1–6 (szkielet, toolchainy, usługi, serwowanie per stos, firewall, testy `verify.sh`).
> Plan i decyzje: [`docs/plan-devcontainer.md`](docs/plan-devcontainer.md).

## Bezpieczeństwo w skrócie

- Użytkownik kontenera **nie ma sudo** (poza dwoma skryptami startu i zarządzania usługami) ani dostępu do Dockera; agenci AI zainstalowani jako root (nie podmienią się).
- **Firewall oparty o profile**: w obrazie tylko publiczne profile, własne domeny w wolumenie tylko do odczytu;
  projekt wybiera profile, a bez wyboru dostępny jest wyłącznie edytor.
- Usługi działają pod własnymi użytkownikami, poza kontrolą agentów.
- **Ansible Vault poza kontenerem** (`host/`): agenci nie widzą ani hasła, ani odszyfrowanej treści.

Inspiracja: [referencyjny devcontainer Claude Code](https://code.claude.com/docs/en/devcontainer).

## Użycie

1. Docker Desktop + VS Code z rozszerzeniem Dev Containers.
2. Otwórz repozytorium i wybierz **Reopen in Container** (dla repozytoriów aplikacji zalecane
   **Clone Repository in Container Volume** — szybszy system plików i działający hot reload).
3. **Ustawienia VS Code na hoście (wymagane).** Domyślnie rozszerzenie Dev Containers kopiuje do kontenera
   `.gitconfig` z hosta i przekazuje helper poświadczeń gita — agent w kontenerze mógłby wtedy pobrać tokeny
   z hosta (`git credential fill`). W ustawieniach użytkownika VS Code (`Preferences: Open User Settings (JSON)`):

   ```jsonc
   "dev.containers.copyGitConfig": false,
   "dev.containers.gitCredentialHelperConfigLocation": "none",
   "dev.containers.dockerCredentialHelper": false,
   "git.terminalAuthentication": false
   ```

   Po zmianie: **Dev Containers: Rebuild Container**. `devc-verify` sprawdza, że nic z hosta nie zostało przekazane.
4. Zaloguj agentów w terminalu kontenera: `claude`, `codex login --device-auth`, `gemini`.
   Logowania są zapisywane w wolumenach i przetrwają przebudowę kontenera.

Przełączanie Node: `fnm use 22`, automatycznie z `.nvmrc` / `.node-version`; domyślna wersja: `fnm default 26`.

### Usługi

Wybór w `devcontainer.json` → `containerEnv.DEV_SERVICES` (domyślnie `mssql,mariadb,phpmyadmin`; dostępne też
`rabbitmq`, `mailpit`). Konto `dev` we wszystkich usługach, hasło z `DEVC_DEV_PASSWORD` (nie może zawierać „dev”).

| Usługa | Połączenie |
|---|---|
| SQL Server 2025 | `Server=127.0.0.1,1433;User Id=dev;Password=…;TrustServerCertificate=True` · `sqlcmd -S 127.0.0.1 -U dev -C` |
| MariaDB 12.3 | `mysql://dev:…@127.0.0.1:3306/app` · `mariadb -h 127.0.0.1 -u dev -p` |
| phpMyAdmin | http://localhost:8080 (zalogowany jako `dev`) |
| RabbitMQ 4.3 | `amqp://dev:…@localhost:5672/` · UI http://localhost:15672 |
| Mailpit | `smtp://localhost:1025` · UI http://localhost:8025 |

```bash
sudo devc-svc status                # stan usług
sudo devc-svc restart mariadb       # restart jednej usługi
sudo devc-svc logs mssql 100        # ostatnie linie logu
devc-verify                         # testy akceptacyjne obrazu (VERIFY_INTRUSIVE=1 — także restarty)
```

### Firewall (profile)

Domyślnie przepuszczany jest **tylko** ruch potrzebny VS Code (profil `vscode`). Agenci AI, rejestry pakietów
i własne usługi — po jawnym włączeniu profilu w `devcontainer.json`:

```jsonc
"DEVC_FIREWALL_PROFILES": "vscode,ai-anthropic,node,php,github,firma",
"DEVC_FIREWALL_MODE": "enforce"     // log = nauka (przepuszcza, loguje DNS: sudo devc-svc logs dnsmasq), off
```

Publiczne profile: `vscode`, `ai-anthropic`, `ai-openai`, `ai-google`, `node`, `dotnet`, `php`, `python`, `ansible`,
`github` (`.devcontainer/rootfs/etc/devc/firewall/profiles/`). Własne domeny/hosty — prywatne profile w wolumenie
`devc-firewall` (w kontenerze tylko do odczytu, czytelne tylko dla roota), zarządzane z hosta:

```powershell
host\devc-firewall.ps1 import moje-domeny.txt firma    # list | show <p> | import <plik> [p] | edit <p> | remove <p>
```

### Serwery projektu (bez roota)

```bash
dev-services start            # Apache+PHP-FPM :8000 (public/), nginx :8081 (dist/), Traefik :8088
dev-services start apache     # tylko jeden (apache | php-fpm | nginx | traefik)
dev-services status | stop | reload | logs apache
APP_PUBLIC_DIR=web dev-services start apache    # inny DocumentRoot; APP_DIST_DIR — katalog buildu dla nginx
```

Apache działa jak hosting współdzielony (`.htaccess`, mod_rewrite, PHP-FPM); zmiany w PHP widać od razu.
Traefik bierze konfigurację dynamiczną z `traefik/` w projekcie (albo kieruje `/` na `TRAEFIK_BACKEND`, domyślnie :5000).

Xdebug jest zainstalowany, ale wyłączony: `export PHP_INI_SCAN_DIR=:/etc/devc/php/xdebug.d` (wyłączenie: `unset PHP_INI_SCAN_DIR`).

## Struktura

```
.devcontainer/      obraz i konfiguracja devcontainera
host/               narzędzia uruchamiane na hoście (izolowany Ansible Vault)
docs/               plan i decyzje
```

## Licencja

[Apache License 2.0](LICENSE).
