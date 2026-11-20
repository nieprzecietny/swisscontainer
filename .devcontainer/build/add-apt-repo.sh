#!/bin/sh
# Uruchamiane przy budowaniu obrazu (root). Dodaje repozytorium apt z JAWNYM keyringiem:
#   - pobiera klucz(e) z podanych URL-i,
#   - sprawdza, że zawierają oczekiwane odciski (przypięte w Dockerfile),
#   - do /etc/apt/keyrings/<nazwa>.gpg eksportuje WYŁĄCZNIE te klucze (nic więcej z pobranego pliku),
#   - zapisuje /etc/apt/sources.list.d/<nazwa>.list z signed-by=.
#
# użycie: add-apt-repo.sh <nazwa> "<url-klucza> [url…]" "<odcisk> [odcisk…]" "<URI> <suite> <komponenty>"
set -euf   # -f: bez rozwijania globów (URL-e kluczy zawierają „?")

name="$1"; key_urls="$2"; fprs="$3"; repo="$4"
keyring="/etc/apt/keyrings/${name}.gpg"

GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT

for url in $key_urls; do
    curl -fsSL "$url" -o "$GNUPGHOME/key.raw"
    gpg --batch --quiet --import "$GNUPGHOME/key.raw"
done

for fpr in $fprs; do
    if ! gpg --batch --with-colons --list-keys "$fpr" 2>/dev/null | grep -q "^fpr:::::::::${fpr}:"; then
        echo "BŁĄD: ${name}: brak klucza o odcisku ${fpr} w pobranym materiale" >&2
        exit 1
    fi
done

install -d -m 0755 /etc/apt/keyrings
# shellcheck disable=SC2086
gpg --batch --export $fprs > "$keyring"
chmod 0644 "$keyring"

arch="$(dpkg --print-architecture)"
echo "deb [arch=${arch} signed-by=${keyring}] ${repo}" > "/etc/apt/sources.list.d/${name}.list"
echo "repo ${name}: ${repo} (klucze: ${fprs})"
