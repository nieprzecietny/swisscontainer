# syntax=docker/dockerfile:1
#
# Izolowany Ansible Vault — uruchamiany WYŁĄCZNIE z hosta (Windows) przez host/vault.ps1,
# nigdy z devcontainera. ansible-core 2.22.0, Python 3.14, user 1000 + edytory: micro (domyślny) i nano.
#
# Build (z katalogu repo, na hoście):
#   docker build -t ansible-vault-local:2.22.0 host/ansible-vault
#
FROM python:3.14-slim

ARG ANSIBLE_CORE_VERSION=2.22.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends micro nano \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir "ansible-core==${ANSIBLE_CORE_VERSION}" \
 && useradd --uid 1000 --no-create-home --home-dir /tmp --shell /usr/sbin/nologin vault \
 && mkdir -p /etc/ansible \
 && printf '[defaults]\nlocal_tmp = /tmp/.ansible/tmp\n' > /etc/ansible/ansible.cfg \
 && chmod 0444 /etc/ansible/ansible.cfg

# ANSIBLE_CONFIG -> zaufany plik z obrazu (root, 0444); ansible.cfg z repo jest ignorowane,
#                   więc nie przekieruje plików tymczasowych ani nie podepnie skryptu hasła
# ANSIBLE_HOME / HOME / MICRO_CONFIG_HOME w /tmp -> pliki tymczasowe `edit` i backupy edytora tylko w tmpfs kontenera
ENV LANG=C.UTF-8 \
    PAGER=cat \
    PYTHONDONTWRITEBYTECODE=1 \
    ANSIBLE_CONFIG=/etc/ansible/ansible.cfg \
    ANSIBLE_HOME=/tmp/.ansible \
    HOME=/tmp \
    MICRO_CONFIG_HOME=/tmp/.micro \
    EDITOR=micro

USER 1000:1000
WORKDIR /work
ENTRYPOINT ["ansible-vault"]
CMD ["--help"]
