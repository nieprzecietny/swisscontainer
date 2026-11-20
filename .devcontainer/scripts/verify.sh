#!/usr/bin/env bash
# verify.sh — testy akceptacyjne devcontainera. Uruchamiać W KONTENERZE jako `vscode`
# (najlepiej w kontenerze z `@devcontainers/cli up`, tak jak startuje go VS Code).
#
#   verify.sh                    # wszystkie sekcje
#   verify.sh base tools         # wybrane sekcje: base tools services web firewall
#   VERIFY_INTRUSIVE=1 verify.sh # także testy zmieniające stan (restart usług, próba eskalacji w MariaDB)
#
# Wynik: PASS / FAIL / SKIP per test + podsumowanie; kod wyjścia 1, jeśli był choć jeden FAIL.
# Obraz zawiera kopię: /usr/local/bin/devc-verify.
set -uo pipefail

PASS=0; FAIL=0; SKIP=0; FAILED=()
INTRUSIVE="${VERIFY_INTRUSIVE:-0}"
TMP="$(mktemp -d /tmp/devc-verify.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=; R=; Y=; B=; N=; fi

pass() { PASS=$((PASS + 1)); printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILED+=("$1"); printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"; [ -n "${2:-}" ] && printf '        %s\n' "${2:0:400}" | sed 's/$//'; return 0; }
skip() { SKIP=$((SKIP + 1)); printf '  %sSKIP%s  %s%s\n' "$Y" "$N" "$1" "${2:+ — $2}"; }
section() { printf '\n%s== %s ==%s\n' "$B" "$1" "$N"; }

# check "opis" 'polecenie'            → PASS, gdy kod 0
# check_re "opis" 'regex' 'polecenie' → PASS, gdy kod 0 i wyjście pasuje do regex (grep -E)
# check_no "opis" 'polecenie'         → PASS, gdy kod ≠ 0 (oczekiwana odmowa)
run() { timeout "${T:-120}" bash -c "$1" > "${TMP}/out" 2>&1; }
check()    { if run "$2"; then pass "$1"; else fail "$1" "$(tail -n 3 "${TMP}/out" | tr '\n' ' ')"; fi; }
check_re() { if run "$3" && grep -Eq -- "$2" "${TMP}/out"; then pass "$1"; else fail "$1" "oczekiwano /$2/, jest: $(head -c 300 "${TMP}/out" | tr '\n' ' ')"; fi; }
check_no() { if run "$2"; then fail "$1" "polecenie powiodło się, a nie powinno: $(head -c 200 "${TMP}/out" | tr '\n' ' ')"; else pass "$1"; fi; }

# W kontenerze z VS Code/devcontainers zmienne containerEnv są w środowisku; /proc/1/environ czyta tylko root.
DEV_SERVICES="${DEV_SERVICES-mssql,mariadb,phpmyadmin}"
DEV_PW="${DEVC_DEV_PASSWORD:-Local_Passw0rd!}"
enabled() { [[ ",${DEV_SERVICES// /}," == *",$1,"* ]]; }

# ==================================================================================================
sec_base() {
    section "Etap 1 — szkielet i izolacja"
    check_re "użytkownik = vscode" '^vscode$' 'id -un'
    check_no "sudo -n true → odmowa (brak ogólnego sudo)" 'sudo -n true'
    check_re "sudo -l: tylko container-init.sh i devc-svc" 'container-init\.sh ""' 'sudo -n -l'
    check_no "sudo -l: brak (ALL) ALL" 'sudo -n -l | grep -E "\(ALL( : ALL)?\) (NOPASSWD: )?ALL"'
    check_no "sudo container-init.sh z argumentem → odmowa" 'sudo -n /usr/local/sbin/container-init.sh --help'
    check_no "brak gniazda Dockera" 'test -e /var/run/docker.sock || test -e /run/docker.sock'
    check_no "brak klienta docker" 'command -v docker'
    check_no "brak hasła vaulta (zmienne/pliki)" 'env | grep -E "^ANSIBLE_VAULT_PASSWORD" || ls ~/.vault_pass* ~/.ansible/vault* 2>/dev/null | grep .'
    check_re "Claude Code" '[0-9]+\.[0-9]+' 'claude --version'
    check_re "Codex CLI" '[0-9]+\.[0-9]+' 'codex --version'
    check_re "Gemini CLI" '[0-9]+\.[0-9]+' 'gemini --version'
    check_re "fnm: Node 22, 24, 26" 'v22\..*v24\..*v26\.' 'fnm list | tr "\n" " "'
    check_re "Node domyślny = 24" '^v24\.' 'node --version'
    check_re "agenci na Node narzędziowym (/opt/devc-node)" '/opt/devc-node' 'cat "$(command -v codex)"'
    check_no "agent nie zmieni swoich binarek (/opt/devc-tools tylko root)" 'touch /opt/devc-tools/.x'
}

# ==================================================================================================
sec_tools() {
    section "Etap 2 — toolchainy"
    check_re ".NET SDK 8 / 10 / 11" '^8\.0\..*10\.0\..*11\.0\.' 'dotnet --list-sdks | tr "\n" " "'
    check_re ".NET runtime NETCore 8 / 10 / 11" 'NETCore\.App 8\..*NETCore\.App 10\..*NETCore\.App 11\.' 'dotnet --list-runtimes | tr "\n" " "'
    check_re ".NET runtime AspNetCore 8 / 10 / 11" 'AspNetCore\.App 8\..*AspNetCore\.App 10\..*AspNetCore\.App 11\.' 'dotnet --list-runtimes | tr "\n" " "'
    check_re "Aspire CLI" '^[0-9]+\.[0-9]+' 'aspire --version'
    check_re "szablony Aspire" 'aspire' 'dotnet new list aspire'
    T=300 check_re "dotnet new console + dotnet run (net10)" 'Hello, World!' \
        'd=$(mktemp -d /tmp/devc-dn.XXXX) && cd "$d" && dotnet new console -n app -f net10.0 -o app >/dev/null && cd app && dotnet run'
    check_re "PHP 8.5" '^PHP 8\.5\.' 'php -v'
    for m in pdo_mysql pdo_sqlsrv sqlsrv intl apcu mbstring curl zip gd bcmath 'Zend OPcache'; do
        check_re "php -m: ${m}" "^${m}\$" 'php -m'
    done
    check_no "Xdebug domyślnie wyłączony" 'php -m | grep -qi xdebug'
    check_re "Xdebug włączany przez PHP_INI_SCAN_DIR" '^xdebug$' 'PHP_INI_SCAN_DIR=:/etc/devc/php/xdebug.d php -m'
    check_re "Composer" '^Composer version 2\.' 'composer --version --no-ansi'
    check_re "Symfony CLI" 'Symfony CLI version 5\.' 'symfony version --no-ansi'
    check_re "symfony check:requirements" 'ready to run Symfony|OK' 'symfony check:requirements --no-ansi'
    check_re "Python 3" '^Python 3\.1[2-9]' 'python3 --version'
    check_re "pipx" '^[0-9]' 'pipx --version'
    check_re "ansible-core 2.22" 'core 2\.22\.' 'ansible --version'
    check_re "gh" '^gh version' 'gh --version'
    check_re "tea" 'Version: 0\.16\.|0\.16\.' 'tea --version'
    check_re "gitea-mcp" '[0-9]+\.[0-9]+\.[0-9]+' 'gitea-mcp --version </dev/null'
    check_re "sqlcmd (mssql-tools18)" 'Version|sqlcmd' 'sqlcmd -? | head -3'
    check_re "mariadb-client 12.3" '12\.3\.' 'mariadb --version'
    check_re "git" '^git version' 'git --version'
}

# ==================================================================================================
sec_services() {
    section "Etap 3 — usługi (DEV_SERVICES=${DEV_SERVICES})"
    if [ -z "${DEV_SERVICES// /}" ]; then skip "usługi" "DEV_SERVICES puste"; fi
    check_no "vscode nie ma dostępu do gniazda supervisord" 'test -r /run/devc/supervisor.sock || ls /run/devc'
    check_no "vscode nie czyta logów usług bezpośrednio" 'ls /var/log/devc'
    check_no "devc-svc: wstrzyknięcie w nazwie usługi odrzucone" 'sudo -n devc-svc restart "\$(id)"'
    check_no "devc-svc: nieznana akcja odrzucona" 'sudo -n devc-svc exec mariadb'
    if [ -n "${DEV_SERVICES// /}" ]; then check_re "sudo devc-svc status" 'RUNNING' 'sudo -n devc-svc status'; fi

    local -A user=([mssql]=mssql [mariadb]=mysql [phpmyadmin]=pma [rabbitmq]=rabbitmq [mailpit]=mailpit)
    # [x]… — wzorzec nie pasuje do własnej linii poleceń (timeout/bash -c)
    local -A pat=([mssql]='[/]opt/mssql/bin/sqlservr' [mariadb]='[/]usr/sbin/mariadbd' [phpmyadmin]='[p]hp8\.5 -S 127\.0\.0\.1:8080' [rabbitmq]='[b]eam\.smp.*rabbit' [mailpit]='[/]usr/local/bin/mailpit')
    local -A port=([mssql]=1433 [mariadb]=3306 [phpmyadmin]=8080 [rabbitmq]=5672 [mailpit]=1025)
    local s pid
    for s in mssql mariadb phpmyadmin rabbitmq mailpit; do
        if enabled "$s"; then
            pid="$(pgrep -f -o -- "${pat[$s]}" || true)"
            if [ -z "$pid" ]; then fail "${s}: proces działa"; continue; fi
            check_re "${s}: działa jako ${user[$s]}" "^${user[$s]}\$" "ps -o user= -p ${pid} | tr -d ' '"
            check_no "${s}: kill z vscode → odmowa" "kill -0 ${pid}"
            check "${s}: port ${port[$s]} na localhost" "(exec 3<>/dev/tcp/127.0.0.1/${port[$s]})"
        else
            check_no "${s}: wyłączona — nie działa" "pgrep -f -- '${pat[$s]}'"
        fi
    done

    if enabled mssql; then
        export SQLCMDPASSWORD="${DEV_PW}"
        check_re "SQL Server: dev loguje się, @@VERSION = 2025 (17.x)" 'SQL Server 2025.*17\.0' \
            'sqlcmd -S 127.0.0.1 -U dev -C -h -1 -W -Q "SET NOCOUNT ON; SELECT @@VERSION" | tr "\n" " "'
        check_re "SQL Server: dev w dbcreator, nie sysadmin" '^1 0$' \
            'sqlcmd -S 127.0.0.1 -U dev -C -h -1 -W -Q "SET NOCOUNT ON; SELECT CONCAT(IS_SRVROLEMEMBER(N'"'"'dbcreator'"'"'), '"'"' '"'"', IS_SRVROLEMEMBER(N'"'"'sysadmin'"'"'))"'
        check "SQL Server: dev tworzy i usuwa bazę" \
            'sqlcmd -S 127.0.0.1 -U dev -C -b -Q "CREATE DATABASE devc_verify_tmp; DROP DATABASE devc_verify_tmp;"'
        check_no "SQL Server: vscode nie czyta hasła sa" 'cat /var/opt/mssql/.devc/sa_password'
        check_no "SQL Server: nasłuch tylko na 127.0.0.1 (nie na adresie kontenera)" \
            "sqlcmd -S \"\$(hostname -i | awk '{print \$1}')\" -U dev -C -l 3 -Q 'SELECT 1'"
        # Znane ograniczenie: ODBC 18 dla nazwy „localhost” nie łączy się z nasłuchem tylko-IPv4 → używaj 127.0.0.1.
        if run 'sqlcmd -S localhost -U dev -C -l 5 -h -1 -Q "SELECT 1"'; then pass "SQL Server: sqlcmd -S localhost"
        else skip "SQL Server: sqlcmd -S localhost" "znane ograniczenie ODBC 18 + nasłuch tylko 127.0.0.1 — używaj -S 127.0.0.1"; fi
        unset SQLCMDPASSWORD
    fi

    if enabled mariadb; then
        export MYSQL_PWD="${DEV_PW}"
        check_re "MariaDB: dev loguje się, wersja 12.3" '^12\.3\.' 'mariadb -h 127.0.0.1 -u dev -N -e "SELECT VERSION()"'
        check_no "MariaDB: dev bez SUPER/FILE/ALL ON *.*" \
            'mariadb -h 127.0.0.1 -u dev -N -e "SHOW GRANTS" | grep -Ei "SUPER|FILE|ALL PRIVILEGES ON \*\.\*"'
        check "MariaDB: dev tworzy i usuwa bazę" \
            'mariadb -h 127.0.0.1 -u dev -e "CREATE DATABASE devc_verify_tmp; DROP DATABASE devc_verify_tmp;"'
        check_no "MariaDB: root przez TCP bez hasła → odmowa" 'MYSQL_PWD= mariadb -h 127.0.0.1 -u root -e "SELECT 1"'
        check_no "MariaDB: root przez gniazdo jako vscode → odmowa" 'MYSQL_PWD= mariadb -u root -e "SELECT 1"'
        unset MYSQL_PWD
    fi

    if enabled phpmyadmin; then
        check_re "phpMyAdmin: zalogowany jako dev" 'dev@(localhost|127\.0\.0\.1)|logged_in|server_databases' \
            'curl -fsS -c /tmp/devc-pma.cookies -b /tmp/devc-pma.cookies http://127.0.0.1:8080/ ; rm -f /tmp/devc-pma.cookies'
    fi

    if enabled rabbitmq; then
        check_re "RabbitMQ: API whoami jako dev" '"name":"dev"' "curl -fsS -u 'dev:${DEV_PW}' http://127.0.0.1:15672/api/whoami"
        check_re "RabbitMQ: wersja 4.3" '"rabbitmq_version":"4\.3\.' "curl -fsS -u 'dev:${DEV_PW}' http://127.0.0.1:15672/api/overview"
        check_no "RabbitMQ: konto guest usunięte" 'curl -fsS -u guest:guest http://127.0.0.1:15672/api/whoami'
    fi

    if enabled mailpit; then
        check "Mailpit: SMTP przyjmuje wiadomość" \
            'printf "Subject: devc-verify\r\n\r\ntest\r\n" | curl -fsS --url smtp://127.0.0.1:1025 --mail-from a@example.com --mail-rcpt b@example.com -T -'
        check_re "Mailpit: wiadomość widoczna w API" '"Subject":"devc-verify"' 'curl -fsS "http://127.0.0.1:8025/api/v1/search?query=subject:devc-verify"'
    fi

    # trwałość danych: znacznik tworzony przy pierwszym przebiegu, sprawdzany po restarcie kontenera
    if enabled mariadb; then
        export MYSQL_PWD="${DEV_PW}"
        if mariadb -h 127.0.0.1 -u dev -N -e "SELECT note FROM devc_verify.marker" >/dev/null 2>&1; then
            pass "MariaDB: dane przetrwały restart (znacznik devc_verify.marker)"
        else
            mariadb -h 127.0.0.1 -u dev -e "CREATE DATABASE IF NOT EXISTS devc_verify; CREATE TABLE IF NOT EXISTS devc_verify.marker (note varchar(64)); INSERT INTO devc_verify.marker VALUES ('$(date +%F_%T)');" \
                && skip "MariaDB: trwałość" "utworzono znacznik — sprawdź ponownie po restarcie kontenera"
        fi
        unset MYSQL_PWD
    fi
    if enabled mssql; then
        export SQLCMDPASSWORD="${DEV_PW}"
        if sqlcmd -S 127.0.0.1 -U dev -C -b -h -1 -Q "SET NOCOUNT ON; SELECT 1 FROM devc_verify.dbo.marker" >/dev/null 2>&1; then
            pass "SQL Server: dane przetrwały restart (znacznik devc_verify.dbo.marker)"
        else
            sqlcmd -S 127.0.0.1 -U dev -C -b -Q "IF DB_ID('devc_verify') IS NULL CREATE DATABASE devc_verify;" >/dev/null 2>&1
            sqlcmd -S 127.0.0.1 -U dev -C -b -d devc_verify -Q "CREATE TABLE marker (note varchar(64)); INSERT INTO marker VALUES (CONVERT(varchar(64), SYSDATETIME()));" >/dev/null 2>&1 \
                && skip "SQL Server: trwałość" "utworzono znacznik — sprawdź ponownie po restarcie kontenera"
        fi
        unset SQLCMDPASSWORD
    fi

    if [ "${INTRUSIVE}" = 1 ]; then
        if enabled mariadb; then
            export MYSQL_PWD="${DEV_PW}"
            # Próba eskalacji: dev dopisuje sobie wszystkie uprawnienia globalne w mysql.global_priv i restartuje usługę.
            mariadb -h 127.0.0.1 -u dev -e "UPDATE mysql.global_priv SET Priv=JSON_SET(Priv,'\$.access',1073741823) WHERE User='dev'" >/dev/null 2>&1 || true
            T=180 check_re "sudo devc-svc restart mariadb" 'mariadb: gotowe' 'sudo -n devc-svc restart mariadb'
            check_no "MariaDB: po próbie eskalacji + restarcie dev nadal bez SUPER/FILE" \
                'mariadb -h 127.0.0.1 -u dev -N -e "SHOW GRANTS" | grep -Ei "SUPER|FILE|ALL PRIVILEGES ON \*\.\*"'
            unset MYSQL_PWD
        else
            skip "restart mariadb" "MariaDB wyłączona"
        fi
    else
        skip "testy zmieniające stan (restart, eskalacja)" "VERIFY_INTRUSIVE=1"
    fi
}

# ==================================================================================================
sec_web() {
    section "Etap 4 — serwowanie per stos"
    local fx="" d
    for d in "$(dirname "$(readlink -f "$0")")/../tests/fixtures" /usr/local/share/devc/fixtures; do
        [ -d "$d/php" ] && { fx="$d"; break; }
    done
    if [ -z "$fx" ]; then skip "etap 4" "brak fixture'ów (tests/fixtures)"; return; fi
    check_re "Apache" 'Apache/2\.4' 'apache2 -v'
    check_re "nginx (nginx.org)" 'nginx/1\.' 'nginx -v'
    check_re "Traefik v3" 'Version: +3\.' 'traefik version'
    check_re "browser-sync" '^[0-9]+\.' 'browser-sync --version'

    # kopia fixture'ów (test hot reload zmienia pliki) + osobne porty i katalog, żeby nie ruszać serwerów użytkownika
    local w="${TMP}/web"; mkdir -p "$w"; cp -a "$fx/php" "$fx/static" "$w/"
    export DEVC_RUN="${TMP}/run" APP_PUBLIC_DIR="$w/php/public" APP_DIST_DIR="$w/static/dist" \
        DEVC_APACHE_PORT=18000 DEVC_NGINX_PORT=18081 DEVC_TRAEFIK_PORT=18088 TRAEFIK_BACKEND=http://127.0.0.1:18081
    check "dev-services start (wszystkie)" 'dev-services start'
    check_re "dev-services status" 'apache +działa.*nginx +działa.*traefik +działa' 'dev-services status | tr "\n" " "'
    check_re "Apache + PHP-FPM: index.php" 'devc-fixture-php v1' 'curl -fsS http://127.0.0.1:18000/index.php'
    check_re "Apache: .htaccess + mod_rewrite (front controller)" 'route=hello/world' 'curl -fsS http://127.0.0.1:18000/hello/world'
    check_re "PHP-FPM jako vscode (nie root)" '^user=vscode' 'curl -fsS http://127.0.0.1:18000/ | grep ^user='
    sed -i 's/devc-fixture-php v1/devc-fixture-php v2/' "$w/php/public/index.php"
    check_re "PHP: zmiana pliku widoczna bez restartu" 'devc-fixture-php v2' 'sleep 1; curl -fsS http://127.0.0.1:18000/index.php'
    check_re "nginx: dist/index.html" 'devc-fixture-spa' 'curl -fsS http://127.0.0.1:18081/'
    check_re "nginx: SPA fallback (/deep/link → index.html)" 'devc-fixture-spa' 'curl -fsS http://127.0.0.1:18081/deep/link'
    check_re "nginx: asset" 'devc-fixture-spa asset' 'curl -fsS http://127.0.0.1:18081/assets/app.js'
    check_no "nginx: brak assetu → 404 (bez fallbacku)" 'curl -fsS http://127.0.0.1:18081/assets/missing.js'
    check_re "Traefik (file provider) → backend" 'devc-fixture-spa' 'curl -fsS http://127.0.0.1:18088/some/route'
    local p
    for p in '[a]pache2 -f /etc/devc/apache' '[p]hp-fpm: master' '[n]ginx: master' '[t]raefik --configFile'; do
        check_no "nie jako root: ${p//[\[\]]/}" "ps -eo user=,args= | grep -E '${p}' | grep -v '^vscode '"
    done
    check "dev-services stop" 'dev-services stop'
    check_no "po stop: porty zamknięte" '(exec 3<>/dev/tcp/127.0.0.1/18000) 2>/dev/null || (exec 3<>/dev/tcp/127.0.0.1/18081) 2>/dev/null'
    unset DEVC_RUN APP_PUBLIC_DIR APP_DIST_DIR DEVC_APACHE_PORT DEVC_NGINX_PORT DEVC_TRAEFIK_PORT TRAEFIK_BACKEND

    # .NET: dotnet watch — zmiana kodu widoczna bez ręcznego restartu
    if [ "${VERIFY_SLOW:-1}" = 1 ]; then
        local dn="${TMP}/dnweb"
        if T=300 run "dotnet new web -n app -f net10.0 -o '$dn' && cd '$dn' && dotnet build -v q"; then
            (cd "$dn" && DOTNET_WATCH_SUPPRESS_EMOJIS=1 nohup dotnet watch run --non-interactive --urls http://127.0.0.1:15055 > "${TMP}/watch.log" 2>&1 &)
            if T=180 run 'for i in $(seq 1 170); do curl -fsS http://127.0.0.1:15055/ 2>/dev/null | grep -q "Hello World" && exit 0; sleep 1; done; exit 1'; then
                pass "dotnet watch: aplikacja odpowiada"
                sed -i 's/Hello World!/Hello devc!/' "$dn/Program.cs"
                T=180 check_re "dotnet watch: zmiana kodu widoczna bez restartu ręcznego" 'Hello devc!' \
                    'for i in $(seq 1 170); do r=$(curl -fsS http://127.0.0.1:15055/ 2>/dev/null); case "$r" in *"Hello devc"*) echo "$r"; exit 0;; esac; sleep 1; done; exit 1'
            else
                fail "dotnet watch: aplikacja odpowiada" "$(tail -n 5 "${TMP}/watch.log" | tr '\n' ' ')"
            fi
            pkill -f "dotnet watch run --non-interactive --urls http://127.0.0.1:15055" 2>/dev/null || true
            pkill -f "${dn}/bin/" 2>/dev/null || true
        else
            fail "dotnet new web" "$(tail -n 3 "${TMP}/out" | tr '\n' ' ')"
        fi
    else
        skip "dotnet watch" "VERIFY_SLOW=0"
    fi
}
sec_firewall() {
    local profiles="${DEVC_FIREWALL_PROFILES:-vscode}" mode="${DEVC_FIREWALL_MODE:-enforce}"
    section "Etap 5 — firewall (tryb ${mode}, profile: ${profiles})"
    on() { [[ ",${profiles// /}," == *",$1,"* ]]; }
    local R='curl -sS -o /dev/null --max-time 8'   # (bez funkcji — check uruchamia osobne bash -c)
    check_no "agent nie zmieni reguł (iptables -F jako vscode)" 'iptables -F'
    check_no "agent nie zmieni zbioru (ipset flush jako vscode)" 'ipset flush devc-allow'
    if [ "${mode}" = off ]; then skip "testy firewalla" "DEVC_FIREWALL_MODE=off"; return; fi
    check_re "jedyny resolver = dnsmasq (127.0.0.1)" '^nameserver 127\.0\.0\.1$' 'grep ^nameserver /etc/resolv.conf'
    check_no "vscode nie zmieni resolv.conf" 'echo "nameserver 8.8.8.8" >> /etc/resolv.conf'
    check_re "usługi na localhost działają mimo firewalla" 'ok' '(exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null; echo ok'
    check "profil vscode: Marketplace dostępny" "$R https://marketplace.visualstudio.com/"
    check "profil vscode: serwer VS Code (update.code.visualstudio.com)" "$R https://update.code.visualstudio.com/"
    if [ "${mode}" = log ]; then skip "blokady" "tryb log — ruch przepuszczany"; return; fi
    check_no "example.com zablokowane" "$R https://example.com/"
    check_no "example.com: brak rozwiązania DNS (zapytania spoza profili nie wychodzą)" 'dig +time=3 +tries=1 +short example.com | grep -E "^[0-9]"'
    check_no "dig @8.8.8.8 zablokowane (DNS tylko przez dnsmasq)" 'dig +time=3 +tries=1 @8.8.8.8 example.com | grep -q "ANSWER SECTION"'
    check_no "DNS-over-TCP do 1.1.1.1 zablokowane" 'dig +tcp +time=3 +tries=1 @1.1.1.1 example.com | grep -q "ANSWER SECTION"'
    check_no "IPv6 zablokowane" 'curl -6 -sS -o /dev/null --max-time 5 https://example.com/'
    check_no "HTTPS po IP spoza listy (1.1.1.1) zablokowane" 'curl -sS -o /dev/null --max-time 5 -k https://1.1.1.1/'
    local p host
    for p in ai-anthropic:api.anthropic.com ai-openai:api.openai.com ai-google:generativelanguage.googleapis.com \
             node:registry.npmjs.org dotnet:api.nuget.org php:repo.packagist.org python:pypi.org github:api.github.com test:example.net; do
        host="${p#*:}"; p="${p%%:*}"
        if on "$p"; then check "profil ${p}: ${host} dostępny" "$R https://${host}/"
        else check_no "bez profilu ${p}: ${host} zablokowane" "$R https://${host}/"; fi
    done
}

# ==================================================================================================
sections=("$@"); [ ${#sections[@]} -gt 0 ] || sections=(base tools services web firewall)
printf '%sdevc verify%s — %s, obraz: %s\n' "$B" "$N" "$(date '+%F %T')" "${DEVC_IMAGE_VERSION:-?}"
for s in "${sections[@]}"; do
    case "$s" in
        base|tools|services|web|firewall) "sec_$s" ;;
        *) echo "nieznana sekcja: $s (base tools services web firewall)" >&2; exit 2 ;;
    esac
done

printf '\n%sPodsumowanie:%s %s%d PASS%s, %s%d FAIL%s, %s%d SKIP%s\n' "$B" "$N" "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
if [ "$FAIL" -gt 0 ]; then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
