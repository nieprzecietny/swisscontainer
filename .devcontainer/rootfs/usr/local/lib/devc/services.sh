# shellcheck shell=bash
# Biblioteka usług devcontainera — wczytywana (source) przez container-init.sh i devc-svc, wyłącznie jako root.
# D36: czyta tylko pliki z obrazu, /proc/1/environ i własne katalogi danych usług; nigdy workspace.
# Sekrety (hasło sa) nigdy nie trafiają do argv (widoczne w `ps` dla każdego użytkownika) — tylko env/pliki 0600.

DEVC_KNOWN=(mssql mariadb phpmyadmin rabbitmq mailpit)
DEVC_DEFAULT_SERVICES="mssql,mariadb,phpmyadmin"
DEVC_DEFAULT_DEV_PASSWORD='Local_Passw0rd!'

DEVC_SUPERVISOR_CONF=/etc/devc/supervisor/supervisord.conf
DEVC_PROGRAMS=/etc/devc/supervisor/programs
DEVC_RUN=/run/devc
DEVC_CONFD=/run/devc/supervisor/conf.d
DEVC_LOG=/var/log/devc

MSSQL_DATA=/var/opt/mssql
MSSQL_SECRETS=/var/opt/mssql/.devc
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
MARIADB_DATA=/var/lib/mysql
MARIADB_RUN=/run/devc-mariadb
PMA_HOME=/var/lib/phpmyadmin
RABBITMQ_DATA=/var/lib/rabbitmq
MAILPIT_DATA=/var/lib/mailpit

log()  { printf '[devc] %s\n' "$*"; printf '%s [devc] %s\n' "$(date '+%F %T')" "$*" >> "${DEVC_LOG}/init.log" 2>/dev/null || true; }
warn() { log "UWAGA: $*"; }
die()  { log "BŁĄD: $*"; exit 1; }

# Wartość zmiennej z /proc/1/environ (środowisko ustawione przy tworzeniu kontenera — nie z sudo/powłoki agenta).
# Kod 1, gdy zmiennej nie ma.
# PID 1 musi należeć do roota: wtedy agent (vscode) nie zmieni ani nie podejrzy tego środowiska,
# a root bez CAP_SYS_PTRACE w ogóle może je odczytać. Fail-closed — wywoływać bezpośrednio (nie w $(…)).
devc_require_root_pid1() {
    if [ "$(stat -c %u /proc/1)" != 0 ] || [ ! -r /proc/1/environ ]; then
        die "PID 1 nie działa jako root — kontener musi startować jako root (devcontainer.json: \"containerUser\": \"root\"; docker run -u root)"
    fi
}

devc_env1() {
    local key="$1" line
    while IFS= read -r -d '' line; do
        if [[ "${line}" == "${key}="* ]]; then printf '%s' "${line#*=}"; return 0; fi
    done < /proc/1/environ
    return 1
}

devc_is_known() { local s; for s in "${DEVC_KNOWN[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

# Ustawia: DEVC_ENABLED (tablica), DEVC_DEV_PASSWORD, DEVC_MSSQL_PID, DEVC_MSSQL_MEMORY_LIMIT_MB
devc_load_env() {
    local raw v s
    devc_require_root_pid1
    if raw="$(devc_env1 DEV_SERVICES)"; then :; else raw="${DEVC_DEFAULT_SERVICES}"; fi
    raw="${raw,,}"; raw="${raw// /}"
    [[ "${raw}" =~ ^[a-z,]*$ ]] || die "DEV_SERVICES: niedozwolone znaki (${raw})"
    DEVC_ENABLED=()
    local -A want=()
    IFS=',' read -r -a _list <<< "${raw}"
    for s in "${_list[@]}"; do
        [ -n "$s" ] || continue
        if devc_is_known "$s"; then want[$s]=1; else warn "DEV_SERVICES: nieznana usługa '${s}' — pomijam (znane: ${DEVC_KNOWN[*]})"; fi
    done
    for s in "${DEVC_KNOWN[@]}"; do [ -n "${want[$s]:-}" ] && DEVC_ENABLED+=("$s"); done
    if [ -n "${want[phpmyadmin]:-}" ] && [ -z "${want[mariadb]:-}" ]; then
        warn "phpMyAdmin bez MariaDB — nie będzie się z czym połączyć"
    fi

    if v="$(devc_env1 DEVC_DEV_PASSWORD)" && [ -n "$v" ]; then DEVC_DEV_PASSWORD="$v"
    else DEVC_DEV_PASSWORD="${DEVC_DEFAULT_DEV_PASSWORD}"; warn "brak DEVC_DEV_PASSWORD — używam domyślnego hasła deweloperskiego"; fi
    case "${DEVC_DEV_PASSWORD}" in *$'\n'*|*$'\r'*) die "DEVC_DEV_PASSWORD nie może zawierać znaków nowej linii";; esac
    [ "${#DEVC_DEV_PASSWORD}" -ge 8 ] || die "DEVC_DEV_PASSWORD: min. 8 znaków (polityka haseł SQL Servera)"
    # polityka SQL Servera: hasło nie może zawierać nazwy loginu („dev”) — sprawdzone na 2025 CU11
    if [[ "${DEVC_DEV_PASSWORD,,}" == *dev* ]]; then
        die "DEVC_DEV_PASSWORD nie może zawierać słowa „dev” (polityka haseł SQL Servera: hasło ≠ nazwa loginu)"
    fi

    v="$(devc_env1 MSSQL_PID || true)"; DEVC_MSSQL_PID="${v:-Developer}"
    [[ "${DEVC_MSSQL_PID}" =~ ^[A-Za-z0-9-]+$ ]] || die "MSSQL_PID: niedozwolona wartość"
    v="$(devc_env1 MSSQL_MEMORY_LIMIT_MB || true)"; DEVC_MSSQL_MEMORY_LIMIT_MB="${v:-2048}"
    [[ "${DEVC_MSSQL_MEMORY_LIMIT_MB}" =~ ^[0-9]+$ ]] || die "MSSQL_MEMORY_LIMIT_MB: oczekiwana liczba"
    if [ "${DEVC_MSSQL_MEMORY_LIMIT_MB}" -lt 2048 ]; then
        warn "MSSQL_MEMORY_LIMIT_MB=${DEVC_MSSQL_MEMORY_LIMIT_MB} < 2048 (minimum SQL Servera) — ustawiam 2048"
        DEVC_MSSQL_MEMORY_LIMIT_MB=2048
    fi
}

devc_service_enabled() { [ -f "${DEVC_CONFD}/$1.conf" ]; }

# Właściciel katalogu danych — tylko sam katalog (bez -R: chown -R podąża za dowiązaniami).
devc_own_dir() {
    local dir="$1" user="$2" mode="$3"
    [ -L "${dir}" ] && die "${dir} jest dowiązaniem symbolicznym — odmawiam"
    install -d -m "${mode}" "${dir}"
    if [ "$(stat -c %U "${dir}")" != "${user}" ]; then chown "${user}:${user}" "${dir}"; fi
    chmod "${mode}" "${dir}"
}

devc_wait_port() {   # port timeout [pid-do-obserwacji]
    local port="$1" timeout="$2" pid="${3:-}" i
    for ((i = 0; i < timeout; i++)); do
        if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then return 0; fi
        if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then return 1; fi
        sleep 1
    done
    return 1
}

devc_random_alnum() { local n="$1" out=''; while [ "${#out}" -lt "$n" ]; do out+="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"; done; printf '%s' "${out:0:$n}"; }

# ------------------------------------------------------------------------------------------------
# SQL Server 2025
# ------------------------------------------------------------------------------------------------
mssql_sa_password() { cat "${MSSQL_SECRETS}/sa_password"; }

mssql_sql() {   # plik.sql — wykonuje jako sa (hasło przez SQLCMDPASSWORD, -x: bez podstawiania $(…) sqlcmd)
    SQLCMDPASSWORD="$(mssql_sa_password)" "${SQLCMD}" -S 127.0.0.1,1433 -U sa -C -b -x -l 5 -h -1 -W -i "$1"
}

mssql_wait_ready() {   # timeout [pid]
    local timeout="$1" pid="${2:-}" i
    for ((i = 0; i < timeout; i += 2)); do
        if SQLCMDPASSWORD="$(mssql_sa_password)" "${SQLCMD}" -S 127.0.0.1,1433 -U sa -C -b -l 2 -h -1 \
            -Q "SET NOCOUNT ON; SELECT 1" >/dev/null 2>&1; then return 0; fi
        if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then return 1; fi
        sleep 2
    done
    return 1
}

mssql_env() {   # środowisko sqlservr (bez hasła sa — to tylko przy pierwszym starcie)
    export HOME="${MSSQL_DATA}" ACCEPT_EULA=Y MSSQL_PID="${DEVC_MSSQL_PID}" \
        MSSQL_MEMORY_LIMIT_MB="${DEVC_MSSQL_MEMORY_LIMIT_MB}" MSSQL_IP_ADDRESS=127.0.0.1 MSSQL_TCP_PORT=1433
}

mssql_init() {
    devc_own_dir "${MSSQL_DATA}" mssql 0770
    [ -L "${MSSQL_SECRETS}" ] && die "${MSSQL_SECRETS} jest dowiązaniem — odmawiam"
    install -d -o root -g root -m 0700 "${MSSQL_SECRETS}"
    if [ ! -s "${MSSQL_SECRETS}/sa_password" ]; then
        (umask 077; printf 'Sa%s9!x' "$(devc_random_alnum 28)" > "${MSSQL_SECRETS}/sa_password")
    fi
    if [ -e "${MSSQL_DATA}/data/master.mdf" ]; then return 0; fi

    log "SQL Server: pierwsze uruchomienie — inicjalizacja (losowe hasło sa, tylko root: ${MSSQL_SECRETS}/sa_password)"
    local pid
    (
        cd "${MSSQL_DATA}"
        mssql_env
        MSSQL_SA_PASSWORD="$(mssql_sa_password)"; export MSSQL_SA_PASSWORD
        exec setpriv --reuid=mssql --regid=mssql --init-groups /opt/mssql/bin/sqlservr
    ) >> "${DEVC_LOG}/mssql-init.log" 2>&1 &
    pid=$!
    if ! mssql_wait_ready 300 "${pid}"; then
        kill "${pid}" 2>/dev/null || true
        die "SQL Server nie wystartował przy inicjalizacji (log: sudo devc-svc logs mssql-init)"
    fi
    mssql_accounts
    local f; f="$(mktemp "${DEVC_RUN}/mssql-XXXXXX.sql")"
    echo 'SHUTDOWN;' > "$f"; mssql_sql "$f" >/dev/null 2>&1 || true; rm -f "$f"
    wait "${pid}" 2>/dev/null || true
    log "SQL Server: inicjalizacja zakończona"
}

mssql_accounts() {   # konto dev (dbcreator); hasło z DEVC_DEV_PASSWORD
    local pw="${DEVC_DEV_PASSWORD//\'/\'\'}" f
    f="$(mktemp "${DEVC_RUN}/mssql-XXXXXX.sql")"
    cat > "$f" <<SQL
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'dev')
    CREATE LOGIN [dev] WITH PASSWORD = N'${pw}', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
ELSE
    ALTER LOGIN [dev] WITH PASSWORD = N'${pw}';
IF IS_SRVROLEMEMBER(N'dbcreator', N'dev') = 0
    ALTER SERVER ROLE [dbcreator] ADD MEMBER [dev];
SQL
    if ! mssql_sql "$f" > /dev/null; then rm -f "$f"; die "SQL Server: nie udało się ustawić konta dev (hasło spełnia politykę? min. 8 znaków, 3 z 4 grup)"; fi
    rm -f "$f"
}

mssql_ready() { mssql_wait_ready 300 && mssql_accounts; }

# ------------------------------------------------------------------------------------------------
# MariaDB 12.3 — superużytkownik root tylko przez gniazdo (unix_socket); konto dev bez uprawnień globalnych.
# Stan uprawnień odtwarzany przy KAŻDYM starcie serwera (--init-file), zanim przyjmie połączenia:
# dev ma dostęp do schematu mysql (wildcard `%`), więc mógłby dopisać sobie SUPER/FILE i zrestartować usługę.
# ------------------------------------------------------------------------------------------------
mariadb_sql_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\'/\\\'}"; printf '%s' "$s"; }

mariadb_write_init_sql() {
    local pw; pw="$(mariadb_sql_str "${DEVC_DEV_PASSWORD}")"
    install -d -o root -g mysql -m 0750 "${MARIADB_RUN}"
    local f="${MARIADB_RUN}/init.sql" tmp
    tmp="$(mktemp "${MARIADB_RUN}/.init-XXXXXX")"
    {
        echo "-- generowane przez container-init.sh przy każdym starcie kontenera; wykonywane przy każdym starcie mariadbd"
        echo "DELETE FROM mysql.global_priv WHERE User IN ('root','mysql','mariadb.sys') AND Host <> 'localhost';"
        echo "UPDATE mysql.global_priv SET Priv = JSON_SET(Priv, '\$.access', 0) WHERE User NOT IN ('root','mysql','mariadb.sys');"
        echo "DELETE FROM mysql.proxies_priv WHERE NOT (User = 'root' AND Host = 'localhost');"
        echo "FLUSH PRIVILEGES;"
        echo "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;"
        echo "ALTER USER 'mysql'@'localhost' IDENTIFIED VIA unix_socket;"
        for h in localhost 127.0.0.1; do
            echo "CREATE USER IF NOT EXISTS 'dev'@'${h}' IDENTIFIED BY '${pw}';"
            echo "ALTER USER 'dev'@'${h}' IDENTIFIED BY '${pw}';"
            echo "GRANT ALL PRIVILEGES ON \`%\`.* TO 'dev'@'${h}';"
        done
        echo "FLUSH PRIVILEGES;"
    } > "${tmp}"
    chown root:mysql "${tmp}"; chmod 0640 "${tmp}"; mv -f "${tmp}" "${f}"
}

mariadb_init() {
    devc_own_dir "${MARIADB_DATA}" mysql 0750
    install -d -o mysql -g mysql -m 0755 /run/mysqld
    if [ ! -d "${MARIADB_DATA}/mysql" ]; then
        log "MariaDB: pierwsze uruchomienie — mariadb-install-db (root tylko przez gniazdo)"
        mariadb-install-db --user=mysql --datadir="${MARIADB_DATA}" --auth-root-authentication-method=socket \
            --skip-test-db >> "${DEVC_LOG}/mariadb-init.log" 2>&1 || die "mariadb-install-db nie powiodło się (sudo devc-svc logs mariadb-init)"
    fi
    mariadb_write_init_sql
}

mariadb_ready() {
    local i
    devc_wait_port 3306 120 || return 1
    for ((i = 0; i < 30; i++)); do
        mariadb --protocol=socket -S /run/mysqld/mysqld.sock -uroot -N -e 'SELECT 1' >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# ------------------------------------------------------------------------------------------------
# phpMyAdmin 5.2 — wbudowany serwer PHP jako `pma`, logowanie automatyczne kontem dev (Q13)
# ------------------------------------------------------------------------------------------------
phpmyadmin_init() {
    install -d -o pma -g pma -m 0750 "${PMA_HOME}" "${PMA_HOME}/tmp" "${PMA_HOME}/sessions"
    local f="${PMA_HOME}/devc-secrets.php" bf=''
    if [ -s "${PMA_HOME}/blowfish" ]; then bf="$(cat "${PMA_HOME}/blowfish")"; fi
    if ! [[ "${bf}" =~ ^[0-9a-f]{64}$ ]]; then
        bf="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        (umask 077; printf '%s' "${bf}" > "${PMA_HOME}/blowfish")
    fi
    local tmp; tmp="$(mktemp "${PMA_HOME}/.secrets-XXXXXX")"
    DEVC_PW="${DEVC_DEV_PASSWORD}" DEVC_BF="${bf}" php -n -r \
        'echo "<?php\n// generowane przez container-init.sh\nreturn ", var_export(["dev_password" => getenv("DEVC_PW"), "blowfish" => getenv("DEVC_BF")], true), ";\n";' \
        > "${tmp}"
    chown root:pma "${tmp}"; chmod 0640 "${tmp}"; mv -f "${tmp}" "${f}"
}
phpmyadmin_ready() { devc_wait_port 8080 60; }

# ------------------------------------------------------------------------------------------------
# RabbitMQ 4.3 — konto dev (tag management, pełne uprawnienia na vhost /), guest usunięty
# ------------------------------------------------------------------------------------------------
rabbitmq_init() {
    devc_own_dir "${RABBITMQ_DATA}" rabbitmq 0750
}
rabbitmq_ctl() { timeout 90 rabbitmqctl -q "$@" < /dev/null; }
rabbitmq_ready() {
    devc_wait_port 5672 180 || return 1
    rabbitmq_ctl await_startup --timeout 120 >/dev/null 2>&1 || return 1
    local users; users="$(rabbitmq_ctl list_users --no-table-headers 2>/dev/null | awk '{print $1}')"
    if grep -qx guest <<< "${users}"; then rabbitmq_ctl delete_user guest >/dev/null; fi
    # Hasło dev w argv (rabbitmqctl bez TTY nie czyta go ze stdin — wisi). Dopuszczalne: hasło dev nie jest
    # tajemnicą przed agentem (containerEnv). Hasła superużytkowników nigdy nie idą przez argv.
    if grep -qx dev <<< "${users}"; then
        rabbitmq_ctl change_password dev "${DEVC_DEV_PASSWORD}" >/dev/null || return 1
    else
        rabbitmq_ctl add_user dev "${DEVC_DEV_PASSWORD}" >/dev/null || return 1
    fi
    rabbitmq_ctl set_user_tags dev management >/dev/null || return 1
    rabbitmq_ctl set_permissions -p / dev '.*' '.*' '.*' >/dev/null || return 1
    devc_wait_port 15672 60
}

# ------------------------------------------------------------------------------------------------
# Mailpit — SMTP 1025, UI 8025
# ------------------------------------------------------------------------------------------------
mailpit_init() { devc_own_dir "${MAILPIT_DATA}" mailpit 0750; }
mailpit_ready() { devc_wait_port 1025 60 && devc_wait_port 8025 60; }

# ------------------------------------------------------------------------------------------------
# supervisord (root, gniazdo 0700) — programy tylko dla włączonych usług
# ------------------------------------------------------------------------------------------------
devc_supervisorctl() { supervisorctl -c "${DEVC_SUPERVISOR_CONF}" "$@"; }
devc_supervisor_running() { devc_supervisorctl pid >/dev/null 2>&1; }

devc_supervisor_programs() {
    install -d -m 0700 "${DEVC_RUN}/supervisor" "${DEVC_CONFD}"
    rm -f "${DEVC_CONFD}"/*.conf
    local s
    for s in "${DEVC_ENABLED[@]}"; do install -m 0600 "${DEVC_PROGRAMS}/${s}.conf" "${DEVC_CONFD}/${s}.conf"; done
}

devc_supervisor_start() {
    if devc_supervisor_running; then
        devc_supervisorctl update >/dev/null
        return 0
    fi
    # Czyste środowisko: do usług nie przechodzi nic z sesji sudo (ani hasło dev, ani sa).
    env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 TZ="${TZ:-UTC}" \
        DEVC_MSSQL_PID="${DEVC_MSSQL_PID}" DEVC_MSSQL_MEMORY_LIMIT_MB="${DEVC_MSSQL_MEMORY_LIMIT_MB}" \
        supervisord -c "${DEVC_SUPERVISOR_CONF}"
    local i
    for ((i = 0; i < 30; i++)); do devc_supervisor_running && return 0; sleep 1; done
    die "supervisord nie wystartował (sudo devc-svc logs supervisord)"
}
