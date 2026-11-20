# swisscontainer — plan

Uniwersalny devcontainer do pracy z agentami AI (Claude Code, Codex, Gemini CLI) w izolowanym środowisku:
.NET, PHP/Symfony, Node, Python/Ansible oraz usługi (SQL Server 2025, MariaDB, phpMyAdmin, RabbitMQ, Mailpit) —
**wszystko w jednym kontenerze**, z firewallem opartym o profile.

Punkt wyjścia: referencyjny devcontainer Claude Code (`Dockerfile` + `init-firewall.sh` + `devcontainer.json`),
który dokumentacja sama nazywa „przykładem, a nie utrzymywanym obrazem bazowym" — ten projekt rozwija go dalej.

Dokument żywy — aktualizowany przy każdej decyzji. Konfiguracja konkretnego użytkownika (własne domeny, hosty,
konta) **nie trafia do repo ani do obrazu** — patrz 4.3 i 4.4.

## 1. Zasady

1. **Jeden kontener, wszystko w środku** — bez docker-compose i kontenerów pobocznych.
2. **Agent AI to niezaufany użytkownik** — bez sudo, bez Dockera, bez dostępu do sekretów produkcyjnych; firewall,
   usługi i ich dane poza jego kontrolą.
3. **Obraz jest publiczny** — zawiera mechanizmy i publiczne ustawienia; wszystko prywatne przychodzi z zewnątrz
   (wolumeny, konfiguracja na hoście), tylko do odczytu tam, gdzie decyduje o bezpieczeństwie.
4. **Domyślnie minimum** — firewall bez wybranych profili przepuszcza tylko to, czego potrzebuje sam edytor.

## 2. Decyzje

### Architektura

| # | Temat | Decyzja |
|---|---|---|
| D32 | Usługi | wszystkie wewnątrz kontenera (supervisord), bez kontenerów pobocznych |
| D33 | Docker Compose | niepotrzebny — `devcontainer.json` z `build`, `runArgs`, `mounts` |
| D2 | SQL Server | 2025 (pakiet `mssql-server`; 2022 nie wspiera Ubuntu 24.04), edycja Developer |
| D4 | Obraz bazowy | `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` |
| D5 | Node | **fnm** z Node 22, 24 (domyślny), 26 + osobny Node narzędziowy w `/opt/devc-node` tylko dla agentów AI |
| D6 | Repo aplikacji | „Clone Repository in Container Volume" (bind mount z dysku Windows jest wolny i bez inotify) |
| D13 | Sieć | domyślny bridge Dockera; usługi na `localhost` |
| D27 | Serwowanie | per stos, zgodnie z produkcją (4.6) |
| D28 | Aspire | AppHost bez kontenerów — zależności z usług w środku (`AddConnectionString`) |
| D31 | PHP | 8.5; Symfony: AssetMapper i Webpack Encore |

### Bezpieczeństwo

| # | Temat | Decyzja |
|---|---|---|
| D14 | Docker w kontenerze | **nie** (gniazdo Dockera = root na hoście) |
| D15 | Firewall | od początku; tryby `enforce` (domyślny) / `log` (nauka) / `off` |
| D16 | Ansible Vault | agenci nie widzą ani hasła, ani treści → vault poza devcontainerem (4.5) |
| D17 | sudo | `vscode` **bez** `NOPASSWD:ALL` (obraz bazowy go ma) — sudo tylko na `container-init.sh` i `devc-svc` |
| D22 | Model pracy agentów | agenci pushują tylko do forków konta-bota, PR, merge robi człowiek; git w kontenerze = token bota |
| D34 | Usługi a agenci | każda usługa pod własnym użytkownikiem, supervisord jako root (socket 0700) |
| D35 | Konta w bazach | aplikacje/agenci: konto `dev`; superużytkownicy — losowe hasła/socket, tylko root; administracja przez `docker exec -u root` z hosta |
| D36 | Pliki czytane przez roota | tylko z obrazu lub z wolumenów tylko do odczytu — nigdy z workspace |
| D37 | Firewall — listy | mechanizm w obrazie, listy jako **profile**: publiczne w obrazie, prywatne w wolumenie `devc-firewall` (ro); projekt wybiera profile; domyślnie minimum (4.3) |

### Git, CI, narzędzia

| # | Temat | Decyzja |
|---|---|---|
| D7–D9 | Gitea | zwykły git przez HTTPS; `tea` (następca `gt` wymaga Gitei ≥ 28); `gitea-mcp` dla Claude, Codex i Gemini |
| D10 | GitHub | `gh` |
| D12, D20 | Ansible | głównie `ansible-vault` na całych plikach; playbooki z vaultem tylko z CI |
| D18 | Narzędzia CLI | `nano`, `micro`, `vim`, `mc` |
| D19 | Obraz vaulta | `host/ansible-vault` (micro + nano) + wrapper `host/vault.ps1` |
| D21, D23 | CI/CD | GitHub Actions + Gitea Actions; na planie GitHub Free prywatne repo nie mają środowisk z polityką gałęzi → ochrona sekretów przez model fork bota (6) |

## 3. Składniki

### Narzędzia

| Składnik | Wersja | Instalacja | Uwagi |
|---|---|---|---|
| Claude Code | przypięta (ARG) | npm → `/opt/devc-tools` (root) | natywna binarka; `DISABLE_AUTOUPDATER=1` — aktualizacja = rebuild |
| Codex | przypięta (ARG) | npm → `/opt/devc-tools` | wrapper na Node narzędziowym; login `codex login --device-auth` lub `OPENAI_API_KEY` |
| Gemini CLI | przypięta (ARG) | npm → `/opt/devc-tools` | wrapper na Node narzędziowym; login kontem Google lub `GEMINI_API_KEY` |
| Node projektów | 22.x, 24.x (domyślny), 26.x | fnm (SHA-256 przypięte), `FNM_DIR=~/.local/share/fnm` | `fnm use 22`, `fnm default 26`, `fnm install 20`; auto z `.nvmrc` / `.node-version` przy `cd` |
| Node narzędziowy | 24.x | archiwum nodejs.org + SHA-256 → `/opt/devc-node` | poza PATH; tylko dla wrapperów agentów |
| .NET SDK | 8.0, 10.0, 11.0 + Aspire CLI | `dotnet-install.sh` / feature `dotnet:2` | runtime'y 8/10/11 z SDK; .NET 8 bez wsparcia od 10.11.2026 |
| PHP | 8.5 (CLI + FPM) | PPA `ondrej/php` | mbstring, xml, curl, intl, zip, opcache, apcu, `pdo_mysql`, `sqlsrv`/`pdo_sqlsrv` 5.13.x; Xdebug wyłączony domyślnie |
| Composer, Symfony CLI | 2.11.x; 5.22.x | instalator Composera (`installer.sig`) / wydanie GitHub + SHA-256 | |
| Python, Ansible | 3.12 (system) + 3.13; ansible-core 2.22.x | apt + `pipx` na Pythonie 3.13 (deadsnakes) | ansible-core 2.22 wymaga Pythona ≥ 3.13; bez hasła vaulta |
| Klienci baz | `mssql-tools18` + `msodbcsql18`, `mariadb-client` | repo Microsoft / MariaDB | `sqlcmd -C` |
| git, gh, tea, gitea-mcp | | apt / binarki | host i tokeny — w wolumenach, nie w obrazie |
| Serwery WWW | Apache, nginx, Traefik | apt / binarka | jako `vscode`, bez roota (4.6) |
| Edytory | nano, micro, vim, mc | apt | |

### Usługi (w kontenerze, pod supervisord)

| Usługa | Wersja | Użytkownik | Port | Dane (wolumen per projekt) |
|---|---|---|---|---|
| SQL Server | 2025, Developer | `mssql` | 1433 | `/var/opt/mssql` |
| MariaDB | 12.3 LTS | `mysql` | 3306 | `/var/lib/mysql` |
| phpMyAdmin | 5.2.x | `pma` (wbudowany serwer PHP) | 8080 | — |
| RabbitMQ | 4.3 + management | `rabbitmq` | 5672, UI 15672 | `/var/lib/rabbitmq` |
| Mailpit | 1.32.x | `mailpit` | SMTP 1025, UI 8025 | `/var/lib/mailpit` |

Wybór usług per projekt: `containerEnv.DEV_SERVICES` (np. `"mariadb,phpmyadmin,mailpit"`).
Połączenia: `Server=localhost,1433;...;TrustServerCertificate=True`, `mysql://dev:...@127.0.0.1:3306/app`,
`amqp://dev:...@localhost:5672/`, `smtp://localhost:1025`.

## 4. Architektura

### 4.1 Pliki

```
.devcontainer/
  devcontainer.json          # build, runArgs, mounts, containerEnv, forwardPorts
  Dockerfile
  build/make-cli-wrappers.js # wrappery agentów AI → zawsze Node z /opt/devc-node           [zrobione]
  build/add-apt-repo.sh      # repozytoria apt z jawnym keyringiem i przypiętymi odciskami   [zrobione]
  rootfs/                    # kopiowane do obrazu, własność root (D36)
    usr/local/sbin/container-init.sh   # sudo, bez argumentów: firewall → init usług → supervisord  [zrobione]
    usr/local/sbin/devc-svc            # sudo: status / restart <usługa> / logs <usługa>   [zrobione]
    usr/local/lib/devc/services.sh     # wspólna logika usług (init, konta dev, gotowość)   [zrobione]
    usr/local/bin/dev-services         # bez sudo: serwery WWW projektu                    [zrobione]
    etc/devc/firewall/profiles/*.txt   # publiczne profile firewalla
    etc/devc/supervisor/, etc/devc/{apache,nginx,php,pma}/
  scripts/verify.sh          # testy akceptacyjne (w obrazie jako devc-verify)             [etapy 1–4]
  tests/fixtures/            # PHP + .htaccess, statyczny dist/ (SPA) — dla verify.sh       [zrobione]
host/                        # uruchamiane NA HOŚCIE (Windows)
  ansible-vault/Dockerfile   # izolowany vault                                              [zrobione]
  vault.ps1                  # wrapper → kopia do %USERPROFILE%\bin                          [zrobione]
  devc-firewall.ps1          # zarządzanie prywatnymi profilami w wolumenie devc-firewall
docs/plan-devcontainer.md    # ten plan
docs/local/                  # PRYWATNE notatki i profile użytkownika — w .gitignore
```

### 4.2 Uruchamianie

```
docker run (VS Code) ── containerUser: root (PID 1), remoteUser: vscode; init: true;
                        runArgs: --label swisscontainer=1 --hostname devc (+ --cap-add NET_ADMIN/NET_RAW w etapie 5)
  ├─ postStartCommand: sudo /usr/local/sbin/container-init.sh   (waitFor: postStartCommand)
  │    1. firewall (profile → dnsmasq + ipset + iptables)
  │    2. DEV_SERVICES, DEVC_* ← /proc/1/environ (ustawione przy tworzeniu kontenera; PID 1 musi być rootem — fail-closed)
  │    3. pierwszy start pustych wolumenów: inicjalizacja danych, losowe hasła superużytkowników, konta `dev`
  │    4. supervisord (root, socket 0700) → usługi pod własnymi użytkownikami
  │    5. czekanie na gotowość
```

### 4.3 Firewall — mechanizm w obrazie, listy jako profile

Referencyjny skrypt rozwiązuje stałą listę nazw jednorazowo (`dig`) — nie obsługuje wildcardów, psuje się na CDN-ach
i wymaga wpisania wszystkich domen do obrazu. Tutaj:

**Profile** — pliki tekstowe, jedna pozycja na linię; domena = domena + wszystkie subdomeny; IP/CIDR wprost.

| Źródło | Ścieżka w kontenerze | Zawartość | Kto może zmienić |
|---|---|---|---|
| obraz (publiczne) | `/etc/devc/firewall/profiles/` | `vscode`, `ai-anthropic`, `ai-openai`, `ai-google`, `node`, `dotnet`, `php`, `python`, `ansible`, `github` | tylko build obrazu |
| wolumen `devc-firewall` (prywatne) | `/etc/devc/firewall/local/` — **tylko do odczytu** | własne domeny i hosty użytkownika | tylko użytkownik z hosta (`host/devc-firewall.ps1`) |

**Wybór per projekt** (`devcontainer.json` → `containerEnv`):

```jsonc
"DEVC_FIREWALL_PROFILES": "vscode,ai-anthropic,node,php,github,firma",
"DEVC_FIREWALL_MODE": "enforce"
```

- **Bez `DEVC_FIREWALL_PROFILES` → tylko `vscode`** (minimum). Agenci AI, rejestry pakietów i własne usługi są
  dostępne dopiero po jawnym włączeniu profilu.
- Nazwy profili prywatnych nie mogą przesłaniać publicznych (kolizja = błąd startu).
- Brak wolumenu `devc-firewall` nie psuje startu — dostępne są tylko profile publiczne.
- Agent nie poszerzy listy: wolumen jest tylko do odczytu, agent nie ma Dockera, a zmiana wyboru profili w
  `devcontainer.json` działa dopiero po rebuildzie (przegląd zmian — 4.7). Może wybierać tylko istniejące profile.
- Pozycje są walidowane (domena / IPv4 / CIDR); błędne linie odrzucane z ostrzeżeniem.

**Egzekwowanie:**
1. **dnsmasq jako jedyny resolver** (`127.0.0.1`, upstream = Docker DNS `127.0.0.11`); `ipset=/<domeny z profili>/allowed`
   — każda rozwiązana (sub)domena trafia od razu do ipsetu (działają wildcardy i CDN-y).
2. **ipset `allowed`**: z dnsmasq + IP/CIDR z profili + zakresy GitHuba z `api.github.com/meta` (profil `github`).
3. **iptables** (domyślnie DROP): loopback (usługi) i ESTABLISHED/RELATED — dozwolone; TCP 80/443/22 tylko do `allowed`;
   DNS tylko do dnsmasq (blokuje tunelowanie DNS); **bez** reguły „cała sieć hosta /24" (odcina inne kontenery na
   bridge'u); IPv6 DROP; reszta LOG + REJECT.
4. Usługi działają w tej samej przestrzeni sieciowej → firewall obejmuje je automatycznie.
5. Weryfikacja na końcu: `example.com` zablokowane; po jednym celu z każdego włączonego profilu — osiągalny.

**Ograniczenie:** filtr działa na adresach IP. Usługi na wspólnych frontach (Google APIs, Cloudflare, Azure Front Door)
dzielą adresy — włączenie np. `ai-google` otwiera w praktyce także inne usługi Google (w tym Cloud Storage).
Pełną separację dałby dopiero proxy z filtrowaniem po SNI (rozważone i odłożone: nie da się nim wymusić profili per projekt).

### 4.4 Sekrety i konfiguracja użytkownika — poza obrazem i repo

| Co | Gdzie |
|---|---|
| Logowania Claude / Codex / Gemini | wolumeny `devc-claude`, `devc-codex`, `devc-gemini` (wspólne dla projektów) |
| gh, tea, gitea-mcp (host + token konta-bota) | wolumeny `devc-gh`, `devc-tea` |
| Prywatne profile firewalla | wolumen `devc-firewall` (ro w kontenerze) |
| Historia powłoki | wolumen `devc-history-${devcontainerId}` |
| Dane usług | wolumeny per projekt |
| Konta `dev` w bazach | hasło deweloperskie w `devcontainer.json` (tylko dane deweloperskie, tylko `localhost`) |
| Superużytkownicy baz | losowe / socket, tylko root (D35) |
| Hasło vaulta | **nigdzie w devcontainerze** (4.5) |
| Notatki i profile prywatne | `docs/local/` — w `.gitignore` |

Wszystkie trzy agenty widzą te same pliki i zmienne → wąskie tokeny, tylko zaufane repo, bez montowania `~/.ssh`
i plików poświadczeń z hosta. Wszystko, co agent przeczyta, trafia do dostawcy modelu.

### 4.5 Ansible Vault poza zasięgiem agentów — zrobione i przetestowane

Interaktywne `--ask-vault-pass` wewnątrz devcontainera nie gwarantuje poufności (`edit` trzyma jawny plik tymczasowy
z uprawnieniami tego samego użytkownika, `decrypt` zapisuje treść na dysk, `ansible.cfg` z repo może przekierować
katalog tymczasowy lub podpiąć skrypt hasła). Dlatego vault działa w osobnym, jednorazowym kontenerze z hosta:

- `host/ansible-vault/Dockerfile` → `ansible-vault-local:2.22.0` (ansible-core 2.22.0, Python 3.14, user 1000, micro + nano;
  zaufany `/etc/ansible/ansible.cfg` przez `ANSIBLE_CONFIG`; pliki tymczasowe w tmpfs).
- `host/vault.ps1` → wrapper; skopiować do `%USERPROFILE%\bin\` i wpisać ID zbudowanego obrazu w `ExpectedImageId`
  (wersja w repo celowo odmawia działania bez tego).

```powershell
docker build -t ansible-vault-local:2.22.0 host/ansible-vault
docker image inspect ansible-vault-local:2.22.0 --format '{{.Id}}'    # → ExpectedImageId w kopii wrappera
vault.ps1 edit group_vars/prod/vault.yml -Path D:\repo\aplikacja
vault.ps1 view group_vars/prod/vault.yml -Volume aplikacja-vol -Repo aplikacja
```

Zasady: akcje `view/edit/create/encrypt/rekey` (**`decrypt` zablokowane**); `ansible.cfg` z repo ignorowane;
`--network none --read-only --cap-drop ALL no-new-privileges`; uruchamianie po ID obrazu; ścieżki względne bez `..`;
odmowa w devcontainerze; edycja w osobnym terminalu, nie w VS Code podłączonym do kontenera.
Ryzyko resztkowe: agenci widzą zaszyfrowane pliki (PBKDF2, 10 000 iteracji) → hasło vaulta długie i losowe.

### 4.6 Serwowanie kodu na żywo — per stos

| Stos | Produkcja | Dev: hot reload | Dev: podgląd „jak na produkcji" |
|---|---|---|---|
| .NET | kontenery; Aspire / Traefik | `dotnet watch` / Aspire AppHost | Traefik (*file provider*); obrazy: `dotnet publish -t:PublishContainer` bez Dockera |
| PHP / Symfony | hosting współdzielony (Apache/LiteSpeed + `.htaccess`) | Symfony CLI + `browser-sync`; Encore `dev-server --hot` | Apache + PHP-FPM z `mod_rewrite` i `.htaccess` |
| JS → statyczny build | nginx | Vite (HMR) | `npm run build` → nginx z konfiguracją produkcyjną |

Porty (forwarding VS Code, tylko `localhost`): 8000 PHP · 8081 nginx · 5173 Vite · 8088 Traefik · 8080 phpMyAdmin ·
1433 SQL Server · 3306 MariaDB · 15672 RabbitMQ · 8025 Mailpit · .NET/Aspire z `launchSettings.json`.

Serwery projektu działają jako `vscode` (bez roota — inaczej edycja ich konfiguracji = root). Deploy na hostingi tylko z CI.
inotify działa przy kodzie w wolumenie Dockera (D6); na bind mouncie z Windows — polling.

### 4.7 Pozostałe drogi do sekretów

1. **CI/CD** — model fork bota, joby z sekretami tylko na chronionych gałęziach po merge'u przez człowieka,
   CODEOWNERS na workflowy (6).
2. **Poświadczenia gita** — w kontenerze token bota; forwardowanie poświadczeń z hosta wyłączone
   (`dev.containers.gitCredentialHelperConfigLocation: none`).
3. **Pliki wykonywane na hoście lub przy buildzie** (`initializeCommand`, `Dockerfile`, `rootfs/`, `host/*`) są w repo →
   agent może je zmienić; przed rebuildem przejrzyj `git diff -- .devcontainer host`.

## 5. Etapy i kryteria odbioru

1. **Szkielet** — ✅ zrobione: Ubuntu 24.04, `vscode` bez sudo, fnm + Node 22/24/26, Node narzędziowy + wrappery,
   Claude Code / Codex / Gemini CLI (przypięte), nano/micro/vim/mc, wolumeny logowań. Przetestowane obrazem
   i `@devcontainers/cli up`.
2. **Toolchainy** — ✅ zrobione: .NET 8/10/11 + Aspire, PHP 8.5 + Composer + Symfony CLI, Python + ansible-core,
   git/gh/tea/gitea-mcp, klienci baz. Wersje przypięte w `ARG`, sumy SHA weryfikowane, repozytoria apt z keyringami.
3. **Usługi w środku** — ✅ zrobione: supervisord, `container-init.sh`, `devc-svc`; SQL Server 2025, MariaDB 12.3,
   phpMyAdmin, RabbitMQ 4.3, Mailpit; `DEV_SERVICES`; konta `dev`. Usługi słuchają tylko na 127.0.0.1.
   Uprawnienia MariaDB odtwarzane przy każdym starcie serwera (`--init-file`) — `dev` nie podniesie sobie uprawnień.
4. **Serwowanie per stos** — ✅ zrobione: `dev-services start|stop|reload|restart|status|logs` (jako `vscode`):
   Apache 8000 (`.htaccess`, mod_rewrite, PHP-FPM przez gniazdo, hot reload PHP), nginx 8081 (`dist/`, SPA fallback),
   Traefik 8088 (file provider), browser-sync; `dotnet watch` przetestowany. Fixture'y: `.devcontainer/tests/fixtures/`.
5. **Firewall** — profile (obraz + wolumen), dnsmasq + ipset + iptables, tryby `log` → `enforce`, `host/devc-firewall.ps1`.
6. **`verify.sh`** — 🟡 sekcje etapów 1–4 gotowe; m.in.: wersje SDK/runtime'ów; `sudo -n true` → odmowa; brak `docker.sock`; brak hasła vaulta;
   `sqlcmd`/`mariadb` jako `dev`; usługi pod własnymi użytkownikami (`kill` z `vscode` → odmowa); serwery WWW nie jako
   root; hot reload per stos; `example.com` zablokowane, profile przepuszczają swoje cele; bez profili — tylko `vscode`.

## 6. Tor B: standard akceptacji w repozytoriach (później)

Zasada: **sekrety CI (np. hasło vaulta) dostępne tylko w przebiegach, których definicji agent nie mógł zmienić.**

| Element | GitHub Actions | Gitea Actions |
|---|---|---|
| Sekrety | środowisko z polityką gałęzi = `main` (w prywatnych repo wymaga płatnego planu) | brak środowisk z polityką gałęzi |
| Praca agentów | fork bota → PR (przebiegi z forków nie dostają sekretów) | jw. (do weryfikacji na danej instancji) |
| `pull_request_target` | zakazane w jobach z sekretami | jw. |
| Ochrona `main` | PR, ≥ 1 zatwierdzenie człowieka, unieważnianie po nowych commitach, wymagane checki, bez wyjątków dla adminów | jw. |
| CODEOWNERS | workflowy, `.devcontainer/`, `host/`, pliki vaulta, `ansible.cfg` → ludzie | jw. |
| Logi | `no_log: true` na taskach z sekretami, bez `-vvv` w CI | jw. |

Własny runner: efemeryczny (świeży kontener/VM na job) i osobny dla jobów z sekretami (tylko `main`/tagi).

## 7. Otwarte pytania

| # | Pytanie | Domyślnie |
|---|---|---|
| Q1 | Zakładanie bazy: migracje EF / dacpac / `.bak` / skrypty SQL? Standard czy Enterprise Developer? | migracje EF + `*.sql`; Developer |
| Q3 | Logowanie agentów: subskrypcje czy klucze API? | oba |
| Q4 | Dodatkowe rozszerzenia PHP? Xdebug? | lista z 3; Xdebug wyłączony |
| Q5 | Edytor: VS Code czy Rider? | VS Code |
| Q12 | Wersja MariaDB | 12.3 LTS |
| Q13 | phpMyAdmin: automatyczne logowanie kontem `dev`? | tak |

## 8. Fakty (stan na 2026-11-20)

- .NET 11 GA 2026-11-10 (SDK 11.0.100, STS); .NET 8 i 9 bez wsparcia od 2026-11-10; .NET 10 = LTS.
- SQL Server na Linuksie: 2022 — Ubuntu do 22.04; 2025 — Ubuntu 24.04 (od CU1); tylko amd64.
- Node: 26.x = aktywne LTS; 24.x i 22.x = LTS utrzymaniowe.
- MariaDB 12.3 = najnowsze LTS (wsparcie do 2029); phpMyAdmin stabilne 5.2.x.
- `tea` zarchiwizowane 2026-10-29 (ostatnie 0.16.0); następca `gt` wymaga Gitei ≥ 28.
- `devcontainers/base:ubuntu-24.04` ma `/etc/sudoers.d/vscode` z `NOPASSWD:ALL` — usuwane w Dockerfile.
- `@anthropic-ai/claude-code` 2.x instaluje natywną binarkę.
- Microsoft Drivers for PHP for SQL Server 5.13.x wspierają PHP 8.5.
- ansible-core 2.22 wymaga Pythona ≥ 3.13 (Ubuntu 24.04: 3.12).
- SQL Server: hasło loginu nie może zawierać jego nazwy (`dev` + hasło z „dev” → odrzucone przez politykę).
- ODBC Driver 18 (sqlcmd) nie łączy się z `localhost`, gdy SQL Server słucha tylko na 127.0.0.1 → `-S 127.0.0.1`.
- `rabbitmqctl add_user` bez TTY nie czyta hasła ze stdin (zawiesza się).

## 9. Źródła

- https://code.claude.com/docs/en/devcontainer
- https://github.com/anthropics/claude-code/tree/main/.devcontainer
- https://learn.microsoft.com/en-us/dotnet/core/whats-new/dotnet-11/overview
- https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-release-notes-2025
- https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-release-notes-2022
- https://github.com/microsoft/msphpsql/releases
- https://developers.openai.com/codex/auth
- https://gitea.com/gitea/tea · https://gitea.com/gitea/cli · https://gitea.com/gitea/gitea-mcp
- https://aspire.dev/get-started/dev-containers/
- https://mariadb.org/mariadb-server-12-3-lts-released/
- https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments
- https://forgejo.org/docs/v11.0/user/actions/reference/
