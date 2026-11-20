#!/bin/bash
# firewall.sh — firewall devcontainera oparty o profile (D15, D37; plan 4.3). Root, wywoływany z container-init.sh.
#
#   DEVC_FIREWALL_PROFILES  lista profili po przecinku (brak/pusta = tylko „vscode”)
#   DEVC_FIREWALL_MODE      enforce (domyślnie) | log (wszystko przepuszcza, loguje) | off
#   — obie wyłącznie z /proc/1/environ.
#
# Profile: publiczne /etc/devc/firewall/profiles/<nazwa>.txt (obraz), prywatne /etc/devc/firewall/local/<nazwa>.txt
# (wolumen devc-firewall, tylko do odczytu). Kolizja nazw = błąd. Linia: domena (z subdomenami) | IPv4 | IPv4/CIDR.
#
# Egzekwowanie: dnsmasq jedynym resolverem (upstream = serwery DNS kontenera z /etc/resolv.conf), ipset=/domeny/
# dokłada rozwiązane adresy do zbioru devc-allow; iptables OUTPUT: lo, ESTABLISHED, TCP 80/443/22 do zbioru,
# DNS tylko przez dnsmasq, reszta LOG „DEVC-FW:” + REJECT; INPUT: tylko lo i ESTABLISHED; IPv6 — DROP.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# shellcheck source=services.sh
. /usr/local/lib/devc/services.sh

PUB=/etc/devc/firewall/profiles
LOC=/etc/devc/firewall/local
FW_RUN=/run/devc/firewall
SET=devc-allow
install -d -m 0700 "${FW_RUN}"

devc_require_root_pid1
profiles_raw="$(devc_env1 DEVC_FIREWALL_PROFILES || true)"
mode="$(devc_env1 DEVC_FIREWALL_MODE || true)"; mode="${mode:-enforce}"
case "${mode}" in enforce|log|off) ;; *) die "DEVC_FIREWALL_MODE: nieznany tryb '${mode}' (enforce|log|off)";; esac

fw_log() { log "firewall: $*"; }

# --- tryb off: wszystko otwarte ---------------------------------------------------------------------
if [ "${mode}" = off ]; then
    fw_log "tryb OFF — ruch bez ograniczeń"
    for t in iptables ip6tables; do
        command -v "$t" >/dev/null || continue
        "$t" -P INPUT ACCEPT 2>/dev/null || true; "$t" -P OUTPUT ACCEPT 2>/dev/null || true
        "$t" -F INPUT 2>/dev/null || true; "$t" -F OUTPUT 2>/dev/null || true
    done
    echo off > "${FW_RUN}/mode"
    exit 0
fi

iptables -S OUTPUT >/dev/null 2>&1 || die "firewall: brak uprawnień do iptables (runArgs: --cap-add=NET_ADMIN --cap-add=NET_RAW) — odmawiam startu bez firewalla"

# --- profile ---------------------------------------------------------------------------------------------
profiles_raw="${profiles_raw,,}"; profiles_raw="${profiles_raw// /}"
[ -n "${profiles_raw}" ] || profiles_raw=vscode
[[ "${profiles_raw}" =~ ^[a-z0-9,-]+$ ]] || die "DEVC_FIREWALL_PROFILES: niedozwolone znaki"

# kolizje: prywatny profil o nazwie publicznego = błąd (prywatny nie może podmienić publicznego)
if [ -d "${LOC}" ]; then
    for f in "${LOC}"/*.txt; do
        [ -e "$f" ] || continue
        n="$(basename "$f" .txt)"
        [ -e "${PUB}/${n}.txt" ] && die "firewall: prywatny profil '${n}' koliduje z publicznym o tej samej nazwie"
    done
fi

domains=(); nets=(); checks=(); used=()
IFS=',' read -r -a req <<< "${profiles_raw}"
for p in "${req[@]}"; do
    [ -n "$p" ] || continue
    [[ "$p" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || { warn "firewall: zła nazwa profilu '$p' — pomijam"; continue; }
    if [ -f "${PUB}/${p}.txt" ]; then f="${PUB}/${p}.txt"
    elif [ -f "${LOC}/${p}.txt" ] && [ ! -L "${LOC}/${p}.txt" ]; then f="${LOC}/${p}.txt"
    else warn "firewall: brak profilu '$p' (publiczne: $(ls "${PUB}" | sed 's/\.txt$//' | tr '\n' ' ')) — pomijam"; continue; fi
    used+=("$p"); first=''
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#$'\xef\xbb\xbf'}"   # BOM z edytorów Windows
        line="${line%%#*}"; line="${line//[[:space:]]/}"; line="${line,,}"; line="${line#\*.}"; line="${line#.}"
        [ -n "$line" ] || continue
        if [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; then
            nets+=("$line")
        elif [[ "$line" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]; then
            domains+=("$line"); [ -n "$first" ] || first="$line"
        else
            warn "firewall: profil '$p': niepoprawna pozycja '${line}' — pomijam"
        fi
    done < "$f"
    [ -n "$first" ] && checks+=("$p:$first")
done
fw_log "tryb ${mode}; profile: ${used[*]:-(brak)}; domeny: ${#domains[@]}, adresy/CIDR: ${#nets[@]}"

# --- upstream DNS (serwery kontenera), zapamiętany przy pierwszym uruchomieniu --------------------------
# Docker odtwarza /etc/resolv.conf przy każdym starcie kontenera → wtedy czytamy upstream od nowa.
if [ ! -s "${FW_RUN}/upstream" ] || ! grep -qx 'nameserver 127.0.0.1' /etc/resolv.conf; then
    awk '$1 == "nameserver" && $2 !~ /^127\./ && $2 ~ /^[0-9.]+$/ {print $2}' /etc/resolv.conf > "${FW_RUN}/upstream" || true
    if grep -q '^nameserver 127\.0\.0\.11' /etc/resolv.conf; then echo 127.0.0.11 >> "${FW_RUN}/upstream"; fi
    cp /etc/resolv.conf "${FW_RUN}/resolv.conf.orig"
fi
mapfile -t upstream < "${FW_RUN}/upstream"
[ "${#upstream[@]}" -gt 0 ] || die "firewall: nie znaleziono serwera DNS kontenera w /etc/resolv.conf"

# --- ipset ---------------------------------------------------------------------------------------------
ipset create "${SET}" hash:net family inet -exist
ipset flush "${SET}"
for n in "${nets[@]}"; do ipset add "${SET}" "$n" -exist; done

# GitHub: zakresy IPv4 z api.github.com/meta (przed zablokowaniem ruchu)
if [[ " ${used[*]} " == *" github "* ]]; then
    if meta="$(curl -fsS --max-time 15 https://api.github.com/meta 2>/dev/null)"; then
        cnt=0
        while IFS= read -r cidr; do ipset add "${SET}" "$cidr" -exist && cnt=$((cnt + 1)); done \
            < <(jq -r '[.web[]?, .api[]?, .git[]?] | .[] | select(test("^[0-9.]+/[0-9]+$"))' <<< "${meta}" 2>/dev/null | sort -u)
        fw_log "github: ${cnt} zakresów IPv4 z api.github.com/meta"
    else
        warn "firewall: nie udało się pobrać api.github.com/meta — GitHub tylko przez DNS (ipset z dnsmasq)"
    fi
fi

# --- dnsmasq: jedyny resolver ------------------------------------------------------------------------
{
    echo "# generowane przez firewall.sh"
    echo "no-resolv"
    echo "no-poll"
    echo "listen-address=127.0.0.1"
    echo "bind-interfaces"
    echo "port=53"
    echo "user=dnsmasq"
    echo "pid-file=${FW_RUN}/dnsmasq.pid"
    echo "cache-size=2000"
    echo "domain-needed"
    # enforce: dalej (upstream) idą TYLKO zapytania o domeny z profili — reszta nie wychodzi z kontenera
    # (blokuje tunelowanie/eksfiltrację przez DNS). log: wszystko, z logowaniem zapytań.
    if [ "${mode}" = log ]; then
        for u in "${upstream[@]}"; do echo "server=${u}"; done
    else
        for d in "${domains[@]}"; do for u in "${upstream[@]}"; do echo "server=/${d}/${u}"; done; done
    fi
    if [ "${#domains[@]}" -gt 0 ]; then
        printf 'ipset=/%s/%s\n' "$(IFS=/; echo "${domains[*]}")" "${SET}"
    fi
    if [ "${mode}" = log ]; then echo "log-queries"; echo "log-facility=/var/log/devc-dnsmasq/dnsmasq.log"; fi
} > "${FW_RUN}/dnsmasq.conf"
pkill -x dnsmasq 2>/dev/null && sleep 0.5 || true
install -d -o dnsmasq -g root -m 0750 /var/log/devc-dnsmasq
dnsmasq --test --conf-file="${FW_RUN}/dnsmasq.conf" >/dev/null 2>&1 || die "firewall: błędna konfiguracja dnsmasq: $(dnsmasq --test --conf-file="${FW_RUN}/dnsmasq.conf" 2>&1 | tail -1)"
dnsmasq --conf-file="${FW_RUN}/dnsmasq.conf"
# resolv.conf → dnsmasq (Docker montuje plik — nadpisujemy treść, nie podmieniamy pliku)
printf '# devcontainer: jedyny resolver = dnsmasq (firewall)\nnameserver 127.0.0.1\noptions ndots:0\n' > /etc/resolv.conf

# --- iptables (IPv4) ---------------------------------------------------------------------------------
final=REJECT; [ "${mode}" = log ] && final=ACCEPT
iptables -P OUTPUT ACCEPT; iptables -P INPUT ACCEPT
iptables -F OUTPUT; iptables -F INPUT
# OUTPUT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
for u in "${upstream[@]}"; do
    for proto in udp tcp; do
        iptables -A OUTPUT -p "$proto" -d "$u" --dport 53 -m owner --uid-owner dnsmasq -j ACCEPT
    done
done
iptables -A OUTPUT -p udp --dport 53 -j LOG --log-prefix "DEVC-FW: dns " -m limit --limit 10/min
iptables -A OUTPUT -p udp --dport 53 -j REJECT
iptables -A OUTPUT -p tcp --dport 53 -j REJECT
iptables -A OUTPUT -p tcp -m multiport --dports 80,443,22 -m set --match-set "${SET}" dst -j ACCEPT
iptables -A OUTPUT -j LOG --log-prefix "DEVC-FW: out " -m limit --limit 30/min
if [ "${final}" = REJECT ]; then
    iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
    iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
else
    iptables -A OUTPUT -j ACCEPT
fi
# INPUT: usługi tylko dla tego kontenera (inne kontenery na bridge'u nie dostaną się do portów)
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -j LOG --log-prefix "DEVC-FW: in " -m limit --limit 10/min
if [ "${final}" = REJECT ]; then iptables -A INPUT -j DROP; else iptables -A INPUT -j ACCEPT; fi

# --- IPv6: DROP (poza lo) ------------------------------------------------------------------------------
if ip6tables -S >/dev/null 2>&1; then
    ip6tables -P OUTPUT ACCEPT; ip6tables -P INPUT ACCEPT
    ip6tables -F OUTPUT; ip6tables -F INPUT
    ip6tables -A OUTPUT -o lo -j ACCEPT; ip6tables -A INPUT -i lo -j ACCEPT
    if [ "${final}" = REJECT ]; then
        ip6tables -A OUTPUT -j REJECT; ip6tables -A INPUT -j DROP
    fi
fi
echo "${mode}" > "${FW_RUN}/mode"
printf '%s\n' "${used[@]}" > "${FW_RUN}/profiles"

# --- weryfikacja ------------------------------------------------------------------------------------
if [ "${mode}" = enforce ]; then
    if curl -s -o /dev/null --max-time 5 https://example.com/ 2>/dev/null; then
        die "firewall: weryfikacja nieudana — example.com jest osiągalne"
    fi
    for c in "${checks[@]}"; do
        p="${c%%:*}"; host="${c#*:}"
        if curl -s -o /dev/null --max-time 8 "https://${host}/" 2>/dev/null; then fw_log "  ${p}: ${host} — OK"
        else warn "firewall: profil '${p}': ${host} nieosiągalne (sprawdź nazwę/sieć; DNS może nie mieć rekordu A dla domeny głównej)"; fi
    done
    fw_log "aktywny (enforce): example.com zablokowane"
else
    fw_log "tryb LOG — ruch przepuszczany, zapytania DNS w /var/log/devc-dnsmasq/dnsmasq.log (sudo devc-svc logs dnsmasq)"
fi
