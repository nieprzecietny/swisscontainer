#!/bin/bash
# container-init.sh — start środowiska kontenera (root). Wywoływane przez postStartCommand:
#     sudo /usr/local/sbin/container-init.sh        (sudoers: tylko BEZ argumentów)
#
# Idempotentne: każde kolejne wywołanie tylko dogrywa brakujące elementy.
#   1. firewall (etap 5; jeśli zainstalowany)
#   2. DEV_SERVICES, DEVC_* ← /proc/1/environ (ustawione przy tworzeniu kontenera, nie z sesji sudo)
#   3. pierwszy start pustych wolumenów: dane, losowe hasła superużytkowników (tylko root), konta `dev`
#   4. supervisord (root, gniazdo 0700) → usługi pod własnymi użytkownikami
#   5. czekanie na gotowość usług
# D36: czyta tylko pliki z obrazu, /proc/1/environ i katalogi danych usług — nigdy workspace.
set -euo pipefail
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C.UTF-8
cd /

if [ "$(id -u)" -ne 0 ]; then echo "container-init: wymaga roota — sudo /usr/local/sbin/container-init.sh" >&2; exit 1; fi
if [ $# -ne 0 ]; then echo "container-init: nie przyjmuje argumentów" >&2; exit 2; fi

# shellcheck source=../lib/devc/services.sh
. /usr/local/lib/devc/services.sh

install -d -m 0700 "${DEVC_RUN}"
install -d -m 0750 "${DEVC_LOG}"
exec 9> "${DEVC_RUN}/init.lock"
flock -w 900 9 || die "inna instancja container-init.sh nadal działa"

devc_require_root_pid1
TZ="$(devc_env1 TZ || echo UTC)"; [[ "${TZ}" =~ ^[A-Za-z0-9_/+-]+$ ]] || TZ=UTC; export TZ

# --- 1. firewall (etap 5) --------------------------------------------------------------------------
if [ -f /usr/local/lib/devc/firewall.sh ]; then
    bash /usr/local/lib/devc/firewall.sh || die "firewall: konfiguracja nie powiodła się — usługi nie zostaną uruchomione"
fi

# --- 2. konfiguracja z /proc/1/environ ---------------------------------------------------------------
devc_load_env
if [ "${#DEVC_ENABLED[@]}" -eq 0 ]; then
    log "DEV_SERVICES: brak włączonych usług"
else
    log "usługi: ${DEVC_ENABLED[*]}"
fi

# --- 3. inicjalizacja danych (pierwszy start) --------------------------------------------------------
for s in "${DEVC_ENABLED[@]}"; do "${s}_init"; done

# --- 4. supervisord ------------------------------------------------------------------------------------
devc_supervisor_programs
if [ "${#DEVC_ENABLED[@]}" -gt 0 ] || devc_supervisor_running; then
    devc_supervisor_start
fi

# --- 5. gotowość ---------------------------------------------------------------------------------------
failed=()
for s in "${DEVC_ENABLED[@]}"; do
    if "${s}_ready"; then log "${s}: gotowe"; else failed+=("${s}"); warn "${s}: nie osiągnął gotowości (sudo devc-svc logs ${s})"; fi
done

if [ "${#failed[@]}" -gt 0 ]; then
    die "usługi bez gotowości: ${failed[*]}"
fi

if [ "${#DEVC_ENABLED[@]}" -gt 0 ]; then
    log "połączenia (konto dev, hasło = DEVC_DEV_PASSWORD):"
    devc_service_enabled mssql      && log "  SQL Server : Server=127.0.0.1,1433;User Id=dev;TrustServerCertificate=True   (sqlcmd -S 127.0.0.1 -U dev -C)"
    devc_service_enabled mariadb    && log "  MariaDB    : mysql://dev@127.0.0.1:3306/   (mariadb -h 127.0.0.1 -u dev -p)"
    devc_service_enabled phpmyadmin && log "  phpMyAdmin : http://localhost:8080/"
    devc_service_enabled rabbitmq   && log "  RabbitMQ   : amqp://dev@localhost:5672/  UI http://localhost:15672/"
    devc_service_enabled mailpit    && log "  Mailpit    : smtp://localhost:1025  UI http://localhost:8025/"
fi
log "container-init: gotowe"
