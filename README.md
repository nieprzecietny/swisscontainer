# swisscontainer

Uniwersalny devcontainer (VS Code Dev Containers) do pracy z agentami AI — **Claude Code, Codex, Gemini CLI** —
w izolowanym środowisku. Jeden kontener, wszystko w środku:

- **.NET** 8 / 10 / 11 + Aspire · **PHP 8.5** + Symfony CLI · **Node** 22 / 24 / 26 (fnm) · **Python** + Ansible
- usługi: **SQL Server 2025**, **MariaDB**, phpMyAdmin, RabbitMQ, Mailpit
- serwowanie per stos z hot reload: `dotnet watch` / Aspire / Traefik, Symfony CLI / Apache + PHP-FPM, Vite / nginx

> **Status: w budowie.** Gotowy etap 1 z 6 (szkielet: agenci AI, Node, użytkownik bez sudo).
> Plan i decyzje: [`docs/plan-devcontainer.md`](docs/plan-devcontainer.md).

## Bezpieczeństwo w skrócie

- Użytkownik kontenera **nie ma sudo** ani dostępu do Dockera; agenci AI zainstalowani jako root (nie podmienią się).
- **Firewall oparty o profile** (etap 5): w obrazie tylko publiczne profile, własne domeny w wolumenie tylko do odczytu;
  projekt wybiera profile, a bez wyboru dostępny jest wyłącznie edytor.
- Usługi działają pod własnymi użytkownikami, poza kontrolą agentów.
- **Ansible Vault poza kontenerem** (`host/`): agenci nie widzą ani hasła, ani odszyfrowanej treści.

Inspiracja: [referencyjny devcontainer Claude Code](https://code.claude.com/docs/en/devcontainer).

## Użycie

1. Docker Desktop + VS Code z rozszerzeniem Dev Containers.
2. Otwórz repozytorium i wybierz **Reopen in Container** (dla repozytoriów aplikacji zalecane
   **Clone Repository in Container Volume** — szybszy system plików i działający hot reload).
3. Zaloguj agentów w terminalu kontenera: `claude`, `codex login --device-auth`, `gemini`.
   Logowania są zapisywane w wolumenach i przetrwają przebudowę kontenera.

Przełączanie Node: `fnm use 22`, automatycznie z `.nvmrc` / `.node-version`; domyślna wersja: `fnm default 26`.

## Struktura

```
.devcontainer/      obraz i konfiguracja devcontainera
host/               narzędzia uruchamiane na hoście (izolowany Ansible Vault)
docs/               plan i decyzje
```

## Licencja

[Apache License 2.0](LICENSE).
