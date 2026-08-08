#!/usr/bin/env bash
#
# server-setup.sh
# Базовая настройка нового сервера (Ubuntu/Debian):
#   1. Обновление системы
#   2. Установка и настройка nftables (единственный файрвол, открыты только SSH/80/443)
#   3. Установка Docker CE + Docker Compose plugin (последние версии из офиц. репозитория)
#   4. Ранний forward-чейн (priority -200), который не даёт Docker пробрасывать
#      наружу порты контейнеров в обход общей политики — снаружи по-прежнему
#      доступны только 80/443 (для контейнеров, не только для хоста)
#
# Использование:
#   sudo ./server-setup.sh [SSH_PORT]
#
# Если SSH_PORT не передан — скрипт попытается определить текущий порт sshd,
# иначе возьмёт 22.

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Оформление
# ----------------------------------------------------------------------------

C_RESET='\033[0m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_CYAN='\033[1;36m'

log_info()  { echo -e "${C_CYAN}[*]${C_RESET} $*"; }
log_ok()    { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
log_warn()  { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
log_err()   { echo -e "${C_RED}[-]${C_RESET} $*" >&2; }

print_banner() {
  echo ""
  echo "======================================================="
  echo " ____  _____ ______     _______ ____  "
  echo "/ ___|| ____|  _ \\ \\   / / ____|  _ \\ "
  echo "\\___ \\|  _| | |_) \\ \\ / /|  _| | |_) |"
  echo " ___) | |___|  _ < \\ V / | |___|  _ < "
  echo "|____/|_____|_| \\_\\ \\_/  |_____|_| \\_\\"
  echo ""
  echo "            SERVER SETUP — by qellyka           "
  echo "======================================================="
  echo ""
}

# ----------------------------------------------------------------------------
# Проверки
# ----------------------------------------------------------------------------

require_root() {
  if [[ $EUID -ne 0 ]]; then
    log_err "Скрипт нужно запускать от root (используй sudo)."
    exit 1
  fi
}

detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    log_err "Не удалось определить дистрибутив (/etc/os-release не найден)."
    exit 1
  fi
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"

  case "$OS_ID" in
    ubuntu|debian) ;;
    *)
      log_err "Скрипт поддерживает только Ubuntu/Debian (обнаружено: ${OS_ID:-unknown})."
      exit 1
      ;;
  esac
}

detect_ssh_port() {
  if [[ -n "${1:-}" ]]; then
    echo "$1"
    return
  fi

  local detected
  detected=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -n1 || true)

  if [[ -n "$detected" ]]; then
    echo "$detected"
  else
    echo "22"
  fi
}

detect_ext_iface() {
  local iface
  iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)

  if [[ -z "$iface" ]]; then
    log_err "Не удалось определить внешний сетевой интерфейс. Укажи его вручную (переменная EXT_IFACE)."
    exit 1
  fi

  echo "$iface"
}

# ----------------------------------------------------------------------------
# Обновление системы
# ----------------------------------------------------------------------------

update_system() {
  log_info "Обновляю списки пакетов и систему..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get -y -qq upgrade
  apt-get -y -qq autoremove
  log_ok "Система обновлена."
}

# ----------------------------------------------------------------------------
# nftables
# ----------------------------------------------------------------------------

disable_other_firewalls() {
  if command -v ufw >/dev/null 2>&1; then
    log_warn "Обнаружен ufw — отключаю, чтобы не конфликтовал с nftables."
    ufw disable >/dev/null 2>&1 || true
    systemctl disable --now ufw >/dev/null 2>&1 || true
  fi

  if systemctl list-unit-files | grep -q '^firewalld.service'; then
    log_warn "Обнаружен firewalld — отключаю."
    systemctl disable --now firewalld >/dev/null 2>&1 || true
  fi

  if systemctl list-unit-files | grep -q '^netfilter-persistent.service'; then
    systemctl disable --now netfilter-persistent >/dev/null 2>&1 || true
  fi
}

install_nftables() {
  log_info "Устанавливаю nftables..."
  apt-get install -y -qq nftables
  log_ok "nftables установлен."
}

configure_nftables() {
  local ssh_port="$1"
  local ext_iface="$2"
  log_info "Настраиваю правила nftables (SSH: ${ssh_port}, HTTP: 80, HTTPS: 443, внешний интерфейс: ${ext_iface})..."

  cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f

flush ruleset

# Ранний чейн на forward-хуке (priority -200). Docker (28+/29+, нативный nftables-режим)
# создаёт свою таблицу "inet docker" с chain forward на priority -100 и policy accept —
# то есть по умолчанию разрешает наружу ЛЮБОЙ опубликованный порт контейнера (-p ...),
# в обход политики ниже. Чтобы это правило сработало раньше докеровского, приоритет
# должен быть меньше -100. Здесь -200.
table inet docker_guard {
    chain forward_early {
        type filter hook forward priority -200; policy accept;

        ct state invalid drop
        ct state established,related accept

        # Трафик не с внешнего интерфейса (между контейнерами, docker <-> docker) не трогаем
        iifname != "${ext_iface}" accept

        # С внешнего интерфейса в контейнеры пропускаем только 80/443 —
        # так же, как для сервисов на самом хосте
        iifname "${ext_iface}" tcp dport { 80, 443 } accept

        # Всё остальное, что Docker пытается пробросить наружу — режем
        iifname "${ext_iface}" drop
    }
}

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept
        ct state invalid drop
        ct state established,related accept

        icmp type echo-request limit rate 5/second accept
        icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept

        tcp dport ${ssh_port} accept
        tcp dport { 80, 443 } accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF

  nft -c -f /etc/nftables.conf
  systemctl enable nftables >/dev/null 2>&1
  systemctl restart nftables

  log_ok "nftables настроен и запущен как единственный файрвол."
  log_warn "Снаружи доступны только: SSH(${ssh_port}), 80, 443 — это верно и для хоста, и для Docker-контейнеров."
}

# ----------------------------------------------------------------------------
# Docker
# ----------------------------------------------------------------------------

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log_warn "Docker уже установлен ($(docker --version)), пропускаю установку."
    return
  fi

  log_info "Устанавливаю Docker CE и Docker Compose plugin из официального репозитория..."

  apt-get install -y -qq ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker >/dev/null 2>&1

  log_ok "Docker установлен: $(docker --version)"
  log_ok "Docker Compose установлен: $(docker compose version)"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
  print_banner
  require_root
  detect_os

  local ssh_port ext_iface
  ssh_port=$(detect_ssh_port "${1:-}")
  ext_iface=$(detect_ext_iface)

  update_system
  disable_other_firewalls
  install_nftables
  configure_nftables "$ssh_port" "$ext_iface"
  install_docker

  echo ""
  log_ok "Готово! Сервер настроен."
  echo -e "  ${C_CYAN}Открытые порты:${C_RESET} SSH(${ssh_port}), 80, 443 (для хоста и для Docker-контейнеров)"
  echo -e "  ${C_CYAN}Файрвол:${C_RESET}        nftables (systemctl status nftables)"
  echo -e "  ${C_CYAN}Внешний интерфейс:${C_RESET} ${ext_iface}"
  echo -e "  ${C_CYAN}Docker:${C_RESET}         $(docker --version)"
  echo -e "  ${C_CYAN}Compose:${C_RESET}        $(docker compose version --short 2>/dev/null || echo 'см. docker compose version')"
  echo ""
  log_warn "Если позже опубликуешь у контейнера ещё один порт (docker run -p 8080:8080),"
  log_warn "снаружи он всё равно останется закрыт — chain docker_guard/forward_early"
  log_warn "пропускает с ${ext_iface} только 80/443. Расширяй список портов в /etc/nftables.conf."
  echo ""
}

main "$@"
