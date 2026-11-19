# syntax=docker/dockerfile:1
#
# Uniwersalny devcontainer — plan: docs/plan-devcontainer.md
# Etap 1: szkielet (Ubuntu 24.04, użytkownik bez sudo, Node 24, Claude Code / Codex / Gemini CLI, edytory).
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

# --- D17: użytkownik bez sudo -------------------------------------------------------------
# Obraz bazowy daje ${USERNAME} NOPASSWD:ALL — agent mógłby zostać rootem i wyłączyć firewall.
# Jedyne wyjątki (container-init.sh, devc-svc) dochodzą w etapach 3 i 5.
RUN set -eux; \
    rm -f "/etc/sudoers.d/${USERNAME}"; \
    if id -nG "${USERNAME}" | tr ' ' '\n' | grep -qx sudo; then gpasswd -d "${USERNAME}" sudo; fi; \
    if grep -rqsw -- "${USERNAME}" /etc/sudoers /etc/sudoers.d; then \
        echo "BŁĄD: sudo dla ${USERNAME} nadal skonfigurowane" >&2; exit 1; \
    fi

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

# FNM_DIR w katalogu użytkownika → `fnm install 20` itp. działa bez roota.
# aliases/default/bin w PATH → powłoki nieinteraktywne (zadania VS Code, polecenia agentów) też mają Node.
ENV FNM_DIR=/home/${USERNAME}/.local/share/fnm \
    PATH=/home/${USERNAME}/.local/share/fnm/aliases/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude \
    DISABLE_AUTOUPDATER=1 \
    CODEX_HOME=/home/${USERNAME}/.codex \
    EDITOR=micro \
    VISUAL=micro

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Wersje Node projektów: najnowsze 22.x, 24.x, 26.x; domyślna = NODE_DEFAULT
RUN set -eux; \
    for v in ${NODE_VERSIONS}; do fnm install "${v}"; done; \
    fnm default "${NODE_DEFAULT}"; \
    fnm list; \
    node --version
