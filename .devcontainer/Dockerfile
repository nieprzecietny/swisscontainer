# syntax=docker/dockerfile:1
#
# Uniwersalny devcontainer — plan: docs/plan-devcontainer.md
# Etap 1: szkielet (Ubuntu 24.04, użytkownik bez sudo, Node, Claude Code / Codex / Gemini CLI, edytory).
# Etap 2: toolchainy (.NET 8/10/11 + Aspire, PHP 8.5 + Composer + Symfony CLI, Python + ansible-core,
#         gh / tea / gitea-mcp, klienci baz).
#
# Zasady: wersje przypięte w ARG; sumy SHA-256/512 tam, gdzie wydawca je publikuje (inaczej przypięte przez nas);
# repozytoria apt tylko z jawnym keyringiem (build/add-apt-repo.sh, przypięte odciski kluczy);
# bez uruchamiania obcych skryptów instalacyjnych jako root (wyjątek: instalator Composera po weryfikacji podpisu).
#
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG USERNAME=vscode
ARG TZ=Europe/Warsaw
# Node „narzędziowy" — tylko dla agentów AI (/opt/devc-node, poza PATH)
ARG TOOLS_NODE_VERSION=24.22.3
ARG CLAUDE_CODE_VERSION=2.1.329
ARG CODEX_VERSION=0.170.0
ARG GEMINI_CLI_VERSION=0.70.0
# Node projektów — przez fnm (przełączanie: `fnm use 22`, auto z .nvmrc / .node-version)
ARG FNM_VERSION=1.39.0
ARG FNM_SHA256_AMD64=7807664f39d39fc518da1c35ba0181e4b3267603c4b1dedeb4b5fc6ae440a224
ARG FNM_SHA256_ARM64=4eaff58b2c5bf30d0934027572dd0b5bbb60d2a1af309230b53662d4b1d45599
ARG NODE_VERSIONS="22 24 26"
ARG NODE_DEFAULT=24

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=${TZ} \
    DEVCONTAINER=true

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --- Architektura: od etapu 2 tylko amd64 -----------------------------------------------------
# SQL Server na Linuksie istnieje tylko dla amd64; binarki z etapu 2+ mają przypięte sumy dla amd64.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    if [ "${arch}" != amd64 ]; then echo "BŁĄD: obraz wspiera tylko amd64 (jest: ${arch})" >&2; exit 1; fi

# --- D17: użytkownik bez sudo -------------------------------------------------------------
# Obraz bazowy daje ${USERNAME} NOPASSWD:ALL — agent mógłby zostać rootem i wyłączyć firewall.
# Jedyne wyjątki (container-init.sh, devc-svc) dochodzą w etapie 3.
RUN set -eux; \
    rm -f "/etc/sudoers.d/${USERNAME}"; \
    if id -nG "${USERNAME}" | tr ' ' '\n' | grep -qx sudo; then gpasswd -d "${USERNAME}" sudo; fi; \
    if grep -rqsw -- "${USERNAME}" /etc/sudoers /etc/sudoers.d; then \
        echo "BŁĄD: sudo dla ${USERNAME} nadal skonfigurowane" >&2; exit 1; \
    fi

# Podczas budowania pakiety nie uruchamiają usług (php-fpm, mariadb, rabbitmq…) — usuwane na końcu części root.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 0755 /usr/sbin/policy-rc.d

# --- Narzędzia CLI i edytory (D18) ------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg jq unzip xz-utils tzdata \
        nano micro vim mc less; \
    rm -rf /var/lib/apt/lists/*

# --- Node narzędziowy dla agentów AI: /opt/devc-node (root, poza PATH; archiwum + SHA-256) ------
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) narch=x64 ;; arm64) narch=arm64 ;; *) echo "nieobsługiwana architektura" >&2; exit 1 ;; \
    esac; \
    tarball="node-v${TOOLS_NODE_VERSION}-linux-${narch}.tar.xz"; \
    cd /tmp; \
    curl -fsSLO "https://nodejs.org/dist/v${TOOLS_NODE_VERSION}/${tarball}"; \
    curl -fsSLO "https://nodejs.org/dist/v${TOOLS_NODE_VERSION}/SHASUMS256.txt"; \
    grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c -; \
    install -d /opt/devc-node; \
    tar -xJf "${tarball}" -C /opt/devc-node --strip-components=1 --no-same-owner \
        --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'; \
    rm -f "${tarball}" SHASUMS256.txt; \
    /opt/devc-node/bin/node --version

# --- Agenci AI w /opt/devc-tools (root-owe) + wrappery w /usr/local/bin ---------------------------
# Wrappery uruchamiają CLI zawsze na /opt/devc-node, więc `fnm use 22` w projekcie ich nie zepsuje.
# Aktualizacja = zmiana wersji w ARG + rebuild (autoupdatery wyłączone niżej).
COPY build/make-cli-wrappers.js /tmp/make-cli-wrappers.js
RUN set -eux; \
    export PATH="/opt/devc-node/bin:${PATH}"; \
    npm install -g --prefix /opt/devc-tools --no-fund --no-audit --loglevel=warn \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
        "@google/gemini-cli@${GEMINI_CLI_VERSION}"; \
    node /tmp/make-cli-wrappers.js @anthropic-ai/claude-code @openai/codex @google/gemini-cli; \
    rm -f /tmp/make-cli-wrappers.js; \
    npm cache clean --force; \
    rm -rf /root/.npm

# --- fnm (menedżer wersji Node dla projektów) ----------------------------------------------------
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) asset=fnm-linux.zip; sha="${FNM_SHA256_AMD64}" ;; \
        arm64) asset=fnm-arm64.zip; sha="${FNM_SHA256_ARM64}" ;; \
        *) echo "nieobsługiwana architektura" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/fnm.zip "https://github.com/Schniz/fnm/releases/download/v${FNM_VERSION}/${asset}"; \
    echo "${sha}  /tmp/fnm.zip" | sha256sum -c -; \
    unzip -o /tmp/fnm.zip -d /usr/local/bin; \
    chmod 0755 /usr/local/bin/fnm; \
    rm -f /tmp/fnm.zip; \
    fnm --version

# =================================================================================================
# Etap 2 — toolchainy
# =================================================================================================

# --- Repozytoria apt (jawne keyringi, przypięte odciski) ----------------------------------------
# ondrej/php podpisuje InRelease dwoma kluczami (stary rsa1024 + nowy) — bierzemy oba.
ARG KEY_ONDREJ="14AA40EC0831756756D7F66C4F4EA0AAE5267A6C B8DC7E53946656EFBCE4C1DD71DAEAAB4AD4CAB6"
ARG KEY_DEADSNAKES=F23C5A6CF475977595C89F51BA6932366A755776
ARG KEY_MICROSOFT=BC528686B50D79E339D3721CEB3E94ADBE1229CF
ARG KEY_GITHUB_CLI=7F38BBB59D064DBCB3D84D725612B36462313325
ARG KEY_MARIADB=177F4010FE56CA3336300305F1656F24C74CD1D8
ARG MARIADB_SERIES=12.3
COPY build/add-apt-repo.sh /usr/local/lib/devc/add-apt-repo.sh
RUN set -eux; \
    add=/usr/local/lib/devc/add-apt-repo.sh; chmod 0755 "${add}"; \
    ks='https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x'; \
    k1="${KEY_ONDREJ%% *}"; k2="${KEY_ONDREJ##* }"; \
    "${add}" ondrej-php "${ks}${k1} ${ks}${k2}" "${KEY_ONDREJ}" \
        "https://ppa.launchpadcontent.net/ondrej/php/ubuntu noble main"; \
    "${add}" deadsnakes "${ks}${KEY_DEADSNAKES}" "${KEY_DEADSNAKES}" \
        "https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu noble main"; \
    "${add}" microsoft-prod https://packages.microsoft.com/keys/microsoft.asc "${KEY_MICROSOFT}" \
        "https://packages.microsoft.com/ubuntu/24.04/prod noble main"; \
    "${add}" github-cli https://cli.github.com/packages/githubcli-archive-keyring.gpg "${KEY_GITHUB_CLI}" \
        "https://cli.github.com/packages stable main"; \
    "${add}" mariadb https://supplychain.mariadb.com/mariadb-keyring-2019.gpg "${KEY_MARIADB}" \
        "https://dlm.mariadb.com/repo/mariadb-server/${MARIADB_SERIES}/repo/ubuntu noble main"; \
    # deadsnakes: tylko python3.13* (żeby nie podmienił systemowego Pythona 3.12)
    printf 'Package: *\nPin: release o=LP-PPA-deadsnakes\nPin-Priority: 100\n' > /etc/apt/preferences.d/deadsnakes; \
    # MariaDB: pakiety mariadb*/mysql* tylko z repo MariaDB (Ubuntu ma 10.11)
    printf 'Package: mariadb-* libmariadb* mysql-common\nPin: origin dlm.mariadb.com\nPin-Priority: 1001\n' > /etc/apt/preferences.d/mariadb

# --- Pakiety bazowe toolchainów: build, Python, gh, klienci baz (MS ODBC + sqlcmd, mariadb) ----
ARG GH_VERSION=2.105.0
ARG MSODBCSQL_VERSION=18.7.1.1-1
ARG MSSQL_TOOLS_VERSION=18.7.1.1-1
RUN set -eux; \
    apt-get update; \
    ACCEPT_EULA=Y apt-get install -y --no-install-recommends \
        build-essential pkg-config autoconf \
        python3 python3-venv pipx python3.13 python3.13-venv \
        "gh=${GH_VERSION}" \
        "msodbcsql18=${MSODBCSQL_VERSION}" "mssql-tools18=${MSSQL_TOOLS_VERSION}" unixodbc unixodbc-dev \
        mariadb-client \
        libicu74 libssl3t64 zlib1g libgssapi-krb5-2; \
    rm -rf /var/lib/apt/lists/*; \
    test -x /opt/mssql-tools18/bin/sqlcmd; \
    mariadb --version; gh --version | head -1; python3.13 --version

# --- .NET SDK 8 / 10 / 11 → /usr/share/dotnet (archiwa + SHA-512 z oficjalnych releases.json) -----
# Instalacja bezpośrednio z archiwów zamiast dotnet-install.sh: wersje przypięte, sumy weryfikowane.
# Kolejność rosnąca → wspólny host `dotnet` pochodzi z najnowszego SDK. Każde SDK zawiera runtime'y
# Microsoft.NETCore.App i Microsoft.AspNetCore.App swojej wersji.
ARG DOTNET_SDKS="\
8.0.428:33212bb99a2bf003973d41106c7e8fe94208a12958ff601d4a476be379403c85a7dc9183a6ec64dfb44ded7102965be09f35add1758e68e9251bae7891d7b7bf \
10.0.404:577d0eb17fec33d029104c5c63a1ab0accc3e28776274abef2218dbac5af18d2109b5406d26b31d76f5c245215e3ba0926a94c20246c672c41847c9e1eb1dc50 \
11.0.100:1bec9cca2ec689b1e80245b84f2b53c9441d1aa6daccf2ceb27490768bffa95954fa585bd275def31069d874d543d9ba9e6591fe9ade2dbd9f34ec5c0fd0050c"
RUN set -eux; \
    install -d -m 0755 /usr/share/dotnet; \
    for spec in ${DOTNET_SDKS}; do \
        v="${spec%%:*}"; sha="${spec#*:}"; f="dotnet-sdk-${v}-linux-x64.tar.gz"; \
        curl -fsSLo "/tmp/${f}" "https://builds.dotnet.microsoft.com/dotnet/Sdk/${v}/${f}"; \
        echo "${sha}  /tmp/${f}" | sha512sum -c -; \
        tar -xzf "/tmp/${f}" -C /usr/share/dotnet --no-same-owner; \
        rm -f "/tmp/${f}"; \
    done; \
    ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet; \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet --list-sdks; \
    rm -rf /root/.dotnet /root/.nuget /tmp/NuGetScratch* /tmp/.dotnet

# --- PHP 8.5 (ondrej/php) + sqlsrv/pdo_sqlsrv + Xdebug (wyłączony) -----------------------------------
# OPcache jest w PHP 8.5 wbudowany (brak osobnego pakietu php8.5-opcache).
# Xdebug: zainstalowany, ale NIE ładowany. Włączenie: export PHP_INI_SCAN_DIR=:/etc/devc/php/xdebug.d
# (albo to samo w containerEnv); wyłączenie: unset PHP_INI_SCAN_DIR.
ARG PHP_VERSION=8.5
ARG MSPHPSQL_VERSION=5.13.3
ARG SQLSRV_SHA256=1c3092ca793bb67002ca022c412aacabb79a3297ee7005e3b7cc91b1e7166d22
ARG PDO_SQLSRV_SHA256=198a7b37da0658d36a93d158a0ec179b137b3a4d241c90a6650ae9ee8f91ec4a
RUN set -eux; \
    p="php${PHP_VERSION}"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "${p}-cli" "${p}-fpm" "${p}-mbstring" "${p}-xml" "${p}-curl" "${p}-intl" "${p}-zip" \
        "${p}-apcu" "${p}-mysql" "${p}-sqlite3" "${p}-gd" "${p}-bcmath" "${p}-readline" \
        "${p}-dev" "${p}-xdebug"; \
    rm -rf /var/lib/apt/lists/*; \
    # sterowniki Microsoft dla SQL Servera — źródła z wydania GitHub (przypięte SHA-256), budowane lokalnie
    for ext in sqlsrv pdo_sqlsrv; do \
        if [ "${ext}" = sqlsrv ]; then sha="${SQLSRV_SHA256}"; prio=20; else sha="${PDO_SQLSRV_SHA256}"; prio=30; fi; \
        f="${ext}-${MSPHPSQL_VERSION}.tgz"; \
        curl -fsSLo "/tmp/${f}" "https://github.com/microsoft/msphpsql/releases/download/v${MSPHPSQL_VERSION}/${f}"; \
        echo "${sha}  /tmp/${f}" | sha256sum -c -; \
        tmpd="$(mktemp -d)"; tar -xzf "/tmp/${f}" -C "${tmpd}"; \
        (cd "${tmpd}/${ext}-${MSPHPSQL_VERSION}" && "phpize${PHP_VERSION}" && \
            ./configure --with-php-config="/usr/bin/php-config${PHP_VERSION}" && make -j"$(nproc)" && make install); \
        rm -rf "${tmpd}" "/tmp/${f}"; \
        printf '; priority=%s\nextension=%s.so\n' "${prio}" "${ext}" > "/etc/php/${PHP_VERSION}/mods-available/${ext}.ini"; \
        phpenmod -v "${PHP_VERSION}" -s ALL "${ext}"; \
    done; \
    # Xdebug: poza domyślnym ładowaniem; konfiguracja do włączania w /etc/devc/php/xdebug.d
    phpdismod -v "${PHP_VERSION}" -s ALL xdebug; \
    install -d -m 0755 /etc/devc/php/xdebug.d; \
    printf '%s\n' \
        '; Włączenie: export PHP_INI_SCAN_DIR=:/etc/devc/php/xdebug.d   (wyłączenie: unset PHP_INI_SCAN_DIR)' \
        'zend_extension=xdebug.so' \
        'xdebug.mode=debug,develop' \
        'xdebug.start_with_request=trigger' \
        'xdebug.client_host=127.0.0.1' \
        'xdebug.client_port=9003' \
        > /etc/devc/php/xdebug.d/20-xdebug.ini; \
    # FPM z pakietu nie jest używany jako usługa systemowa (serwery WWW projektu — etap 4, jako vscode)
    php -v; php -m | grep -E '^(sqlsrv|pdo_sqlsrv|pdo_mysql|intl|apcu|Zend OPcache)$'; \
    if php -m | grep -qi xdebug; then echo "BŁĄD: Xdebug ładowany domyślnie" >&2; exit 1; fi

# --- Composer (instalator weryfikowany installer.sig) + Symfony CLI (wydanie GitHub + SHA-256) ------
ARG COMPOSER_VERSION=2.11.2
ARG SYMFONY_CLI_VERSION=5.22.2
ARG SYMFONY_CLI_SHA256=9e9cf056087f9e0320f592dce76d491fc21579e6d915b2bb3b32949c2d7a4ef5
RUN set -eux; \
    cd /tmp; \
    expected="$(curl -fsSL https://composer.github.io/installer.sig)"; \
    curl -fsSLo composer-setup.php https://getcomposer.org/installer; \
    actual="$(sha384sum composer-setup.php | cut -d' ' -f1)"; \
    if [ "${expected}" != "${actual}" ]; then echo "BŁĄD: suma instalatora Composera się nie zgadza" >&2; exit 1; fi; \
    php composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer --version="${COMPOSER_VERSION}"; \
    rm -f composer-setup.php; \
    curl -fsSLo symfony.tgz "https://github.com/symfony-cli/symfony-cli/releases/download/v${SYMFONY_CLI_VERSION}/symfony-cli_linux_amd64.tar.gz"; \
    echo "${SYMFONY_CLI_SHA256}  symfony.tgz" | sha256sum -c -; \
    tar -xzf symfony.tgz -C /usr/local/bin --no-same-owner symfony; \
    chmod 0755 /usr/local/bin/symfony /usr/local/bin/composer; \
    rm -f symfony.tgz; \
    COMPOSER_ALLOW_SUPERUSER=1 composer --version; symfony version --no-ansi

# --- tea (Gitea CLI) + gitea-mcp (binarki z gitea.com + SHA-256) ---------------------------------
ARG TEA_VERSION=0.16.0
ARG TEA_SHA256=9c142c8a0b31485eea2387031c1c404f12b7141075eb4ffbd7ced49441590636
ARG GITEA_MCP_VERSION=1.13.0
ARG GITEA_MCP_SHA256=23383ad6adbb7a8a6a848ac736c07de19417d26311c3581160b356db01b3366d
RUN set -eux; \
    cd /tmp; \
    curl -fsSLo tea "https://gitea.com/gitea/tea/releases/download/v${TEA_VERSION}/tea-${TEA_VERSION}-linux-amd64"; \
    echo "${TEA_SHA256}  tea" | sha256sum -c -; \
    install -m 0755 tea /usr/local/bin/tea; rm -f tea; \
    curl -fsSLo gitea-mcp.tgz "https://gitea.com/gitea/gitea-mcp/releases/download/v${GITEA_MCP_VERSION}/gitea-mcp_Linux_x86_64.tar.gz"; \
    echo "${GITEA_MCP_SHA256}  gitea-mcp.tgz" | sha256sum -c -; \
    d="$(mktemp -d)"; tar -xzf gitea-mcp.tgz -C "${d}"; \
    install -m 0755 "${d}/gitea-mcp" /usr/local/bin/gitea-mcp; rm -rf "${d}" gitea-mcp.tgz; \
    tea --version; timeout 10 gitea-mcp --version </dev/null || true

# =================================================================================================
# Etap 3 — usługi w kontenerze: supervisord, każda usługa pod własnym użytkownikiem (D32, D34)
# =================================================================================================

# Stałe UID/GID użytkowników usług → wolumeny danych pasują także po przebudowie obrazu.
RUN set -eux; \
    for spec in mssql:10001:/var/opt/mssql mysql:10002:/nonexistent rabbitmq:10003:/var/lib/rabbitmq \
                pma:10004:/var/lib/phpmyadmin mailpit:10005:/var/lib/mailpit; do \
        IFS=: read -r name id home <<< "${spec}"; \
        groupadd --system --gid "${id}" "${name}"; \
        useradd --system --uid "${id}" --gid "${id}" --home-dir "${home}" --no-create-home \
            --shell /usr/sbin/nologin "${name}"; \
    done

ARG KEY_RABBITMQ=0A9AF2115F4687BD29803A206B73A36E6026DFCA
RUN set -eux; \
    add=/usr/local/lib/devc/add-apt-repo.sh; \
    "${add}" mssql-server-2025 https://packages.microsoft.com/keys/microsoft.asc "${KEY_MICROSOFT}" \
        "https://packages.microsoft.com/ubuntu/24.04/mssql-server-2025 noble main"; \
    "${add}" rabbitmq-erlang "https://keys.openpgp.org/vks/v1/by-fingerprint/${KEY_RABBITMQ}" "${KEY_RABBITMQ}" \
        "https://deb1.rabbitmq.com/rabbitmq-erlang/ubuntu/noble noble main"; \
    "${add}" rabbitmq-server "https://keys.openpgp.org/vks/v1/by-fingerprint/${KEY_RABBITMQ}" "${KEY_RABBITMQ}" \
        "https://deb1.rabbitmq.com/rabbitmq-server/ubuntu/noble noble main"; \
    # Erlang tylko z repo Team RabbitMQ (Ubuntu 24.04 ma Erlang 25 — za stary dla RabbitMQ 4.3)
    printf 'Package: erlang*\nPin: origin deb1.rabbitmq.com\nPin-Priority: 1001\n' > /etc/apt/preferences.d/rabbitmq-erlang

# --- SQL Server 2025 (Developer) — uruchamiany bez systemd, jak w oficjalnym obrazie (sqlservr jako mssql) ---
ARG MSSQL_SERVER_VERSION=17.0.5065.9-3
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends "mssql-server=${MSSQL_SERVER_VERSION}"; \
    rm -rf /var/lib/apt/lists/*; \
    rm -rf /var/opt/mssql; install -d -o mssql -g mssql -m 0770 /var/opt/mssql; \
    test -x /opt/mssql/bin/sqlservr

# --- supervisord + MariaDB 12.3 (serwer) ------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends supervisor procps mariadb-server; \
    rm -rf /var/lib/apt/lists/*; \
    # dane inicjalizuje container-init.sh na wolumenie (root tylko przez gniazdo)
    rm -rf /var/lib/mysql; install -d -o mysql -g mysql -m 0750 /var/lib/mysql /var/lib/mysql-files; \
    install -d -o mysql -g mysql -m 0755 /run/mysqld; \
    mariadbd --version

# --- RabbitMQ 4.3 + Erlang (repo Team RabbitMQ) --------------------------------------------------
ARG RABBITMQ_VERSION=4.3.8-1
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends "rabbitmq-server=${RABBITMQ_VERSION}"; \
    rm -rf /var/lib/apt/lists/*; \
    rm -rf /var/lib/rabbitmq; install -d -o rabbitmq -g rabbitmq -m 0750 /var/lib/rabbitmq; \
    dpkg -l rabbitmq-server erlang-base | tail -n 2

# --- phpMyAdmin 5.2 (archiwum + SHA-256 z phpmyadmin.net) + Mailpit (GitHub; sumy nie publikowane → przypięte) ---
ARG PHPMYADMIN_VERSION=5.2.3
ARG PHPMYADMIN_SHA256=57881348297c4412f86c410547cf76b4d8a236574dd2c6b7d6a2beebe7fc44e3
ARG MAILPIT_VERSION=1.32.0
ARG MAILPIT_SHA256=4b5993c978e8604c70d43927e2ad103b311bba3b1822fa0cf1d4ee4ec890a93c
RUN set -eux; \
    cd /tmp; \
    f="phpMyAdmin-${PHPMYADMIN_VERSION}-all-languages.tar.xz"; \
    curl -fsSLo "${f}" "https://files.phpmyadmin.net/phpMyAdmin/${PHPMYADMIN_VERSION}/${f}"; \
    echo "${PHPMYADMIN_SHA256}  ${f}" | sha256sum -c -; \
    install -d -m 0755 /usr/share/phpmyadmin; \
    tar -xJf "${f}" -C /usr/share/phpmyadmin --strip-components=1 --no-same-owner; \
    rm -rf "${f}" /usr/share/phpmyadmin/setup /usr/share/phpmyadmin/examples; \
    chmod -R u=rwX,go=rX /usr/share/phpmyadmin; \
    install -d -o pma -g pma -m 0750 /var/lib/phpmyadmin; \
    curl -fsSLo mailpit.tgz "https://github.com/axllent/mailpit/releases/download/v${MAILPIT_VERSION}/mailpit-linux-amd64.tar.gz"; \
    echo "${MAILPIT_SHA256}  mailpit.tgz" | sha256sum -c -; \
    d="$(mktemp -d)"; tar -xzf mailpit.tgz -C "${d}"; install -m 0755 "${d}/mailpit" /usr/local/bin/mailpit; \
    rm -rf "${d}" mailpit.tgz; \
    install -d -o mailpit -g mailpit -m 0750 /var/lib/mailpit; \
    mailpit version --no-release-check || mailpit version || true

# --- Katalogi pod wolumeny (logowania i historia przetrwają rebuild) ----------------------------
# Pusty nazwany wolumen przejmuje przy pierwszym montowaniu właściciela katalogu z obrazu.
RUN set -eux; \
    home="/home/${USERNAME}"; \
    install -d -o "${USERNAME}" -g "${USERNAME}" -m 0700 \
        "${home}/.claude" "${home}/.codex" "${home}/.gemini" \
        "${home}/.config" "${home}/.config/gh" "${home}/.config/tea"; \
    install -d -o "${USERNAME}" -g "${USERNAME}" -m 0755 "${home}/.local" "${home}/.local/share" /commandhistory; \
    for rc in "${home}/.bashrc" "${home}/.zshrc"; do \
        sh_name="$(basename "${rc}" | sed 's/^\.//; s/rc$//')"; \
        printf '\n# devcontainer: historia na wolumenie\nexport HISTFILE=/commandhistory/.%s_history\n' "${sh_name}" >> "${rc}"; \
        printf '# devcontainer: fnm — przełączanie wersji Node, auto z .nvmrc / .node-version przy cd\n' >> "${rc}"; \
        printf 'eval "$(fnm env --use-on-cd --version-file-strategy=recursive --shell %s)"\n' "${sh_name}" >> "${rc}"; \
    done; \
    printf 'export PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"\n' >> "${home}/.bashrc"; \
    printf 'setopt INC_APPEND_HISTORY\n' >> "${home}/.zshrc"; \
    chown "${USERNAME}:${USERNAME}" "${home}/.bashrc" "${home}/.zshrc"

RUN rm -f /usr/sbin/policy-rc.d

# FNM_DIR w katalogu użytkownika → `fnm install 20` itp. działa bez roota.
# aliases/default/bin w PATH → powłoki nieinteraktywne (zadania VS Code, polecenia agentów) też mają Node.
# ~/.dotnet/tools (Aspire CLI, narzędzia dotnet użytkownika), ~/.local/bin (pipx: ansible), sqlcmd.
ENV FNM_DIR=/home/${USERNAME}/.local/share/fnm \
    PATH=/home/${USERNAME}/.local/share/fnm/aliases/default/bin:/home/${USERNAME}/.dotnet/tools:/home/${USERNAME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/mssql-tools18/bin \
    CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude \
    DISABLE_AUTOUPDATER=1 \
    CODEX_HOME=/home/${USERNAME}/.codex \
    EDITOR=micro \
    VISUAL=micro \
    DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    ASPIRE_CLI_TELEMETRY_OPTOUT=1 \
    PIPX_DEFAULT_PYTHON=python3.13

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Wersje Node projektów: najnowsze 22.x, 24.x, 26.x; domyślna = NODE_DEFAULT
RUN set -eux; \
    for v in ${NODE_VERSIONS}; do fnm install "${v}"; done; \
    fnm default "${NODE_DEFAULT}"; \
    fnm list; \
    node --version

# Narzędzia użytkownika: Aspire CLI (dotnet tool, ~/.dotnet/tools) + szablony Aspire; ansible-core (pipx, Python 3.13 —
# ansible-core 2.22 wymaga Pythona ≥ 3.13, systemowy Python Ubuntu 24.04 to 3.12).
ARG ASPIRE_VERSION=17.0.0
ARG ANSIBLE_CORE_VERSION=2.22.0
RUN set -eux; \
    dotnet tool install --global Aspire.Cli --version "${ASPIRE_VERSION}"; \
    dotnet new install "Aspire.ProjectTemplates::${ASPIRE_VERSION}"; \
    aspire --version; \
    pipx install "ansible-core==${ANSIBLE_CORE_VERSION}"; \
    ansible --version | head -1; \
    rm -rf ~/.nuget/packages ~/.cache/pip /tmp/NuGetScratch*

# =================================================================================================
# rootfs/ — skrypty i konfiguracja (własność root, D36). Na końcu, bo zmienia się najczęściej.
# =================================================================================================
USER root
COPY rootfs/ /tmp/devc-rootfs/
COPY scripts/verify.sh /tmp/devc-rootfs/usr/local/bin/devc-verify
RUN set -eux; \
    cd /tmp/devc-rootfs; \
    if grep -rlI $'\r' .; then echo "BŁĄD: końce linii CRLF w rootfs/ (wymagane LF)" >&2; exit 1; fi; \
    find . -type f | sort | while read -r f; do \
        dst="/${f#./}"; \
        case "${dst}" in \
            /usr/local/sbin/*|/usr/local/bin/*) mode=0755 ;; \
            /etc/sudoers.d/*) mode=0440 ;; \
            *) mode=0644 ;; \
        esac; \
        install -D -o root -g root -m "${mode}" "${f}" "${dst}"; \
    done; \
    cd /; rm -rf /tmp/devc-rootfs; \
    for s in /usr/local/sbin/container-init.sh /usr/local/sbin/devc-svc /usr/local/lib/devc/services.sh /usr/local/bin/devc-verify; do \
        bash -n "${s}"; \
    done; \
    visudo -cf /etc/sudoers.d/devc; \
    install -d -m 0750 /var/log/devc; \
    install -d -m 0700 /run/devc

USER ${USERNAME}
