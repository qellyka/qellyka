#!/usr/bin/env bash
set -euo pipefail

#################################
# BRIDGE RELAY SETUP SCRIPT
# Author: qellyka
#################################

#################################
# TRAP
#################################
trap 'echo -e "\033[1;31m[ERROR]\033[0m Error at line $LINENO"; exit 1' ERR

#################################
# HELPERS
#################################
log()  { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

#################################
# DEFAULTS
#################################
ORIGIN_IP=""
ORIGIN_DOMAIN=""
DOMAIN=""
TCP_PORTS="443,8443"
PORT_RANGE="10000-60000"
SSH_PORT="22"

#################################
# USAGE
#################################
usage() {
  cat <<EOF
Bridge Relay Setup — by qellyka

Usage:
  $0 --origin-ip <IP> [options]
  $0 --origin-domain <domain> [options]

You must provide exactly one of --origin-ip or --origin-domain.

Required (choose one):
  --origin-ip <IP>        IP address of the main server this bridge forwards traffic to
  --origin-domain <name>  Domain name of the main server (will be resolved to an IP at setup time)

Optional:
  --domain <name>         Domain that should point to this bridge server (will be checked via DNS)
  --tcp-ports <list>      Comma-separated list of ports (default: 443,8443)
  --port-range <a-b>      Port range (default: 10000-60000)
  --ssh-port <port>       SSH port to protect from forwarding (default: 22)
  -h, --help              Show this help

Examples:
  $0 --origin-ip 77.110.110.34 --domain bridge.example.com
  $0 --origin-domain main.example.com --tcp-ports "443,8443,2053" --port-range "20000-50000" --ssh-port 2222
EOF
  exit 1
}

#################################
# PARSE ARGS
#################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --origin-ip)      ORIGIN_IP="${2:-}"; shift 2 ;;
    --origin-domain)  ORIGIN_DOMAIN="${2:-}"; shift 2 ;;
    --domain)         DOMAIN="${2:-}"; shift 2 ;;
    --tcp-ports)      TCP_PORTS="${2:-}"; shift 2 ;;
    --port-range)     PORT_RANGE="${2:-}"; shift 2 ;;
    --ssh-port)       SSH_PORT="${2:-}"; shift 2 ;;
    -h|--help)        usage ;;
    *) die "Unknown parameter: $1 (see --help)" ;;
  esac
done

if [[ -z "$ORIGIN_IP" && -z "$ORIGIN_DOMAIN" ]]; then
    warn "You must provide either --origin-ip or --origin-domain"
    usage
fi
if [[ -n "$ORIGIN_IP" && -n "$ORIGIN_DOMAIN" ]]; then
    die "Provide only one of --origin-ip or --origin-domain, not both"
fi

[[ $EUID -eq 0 ]] || die "This script must be run as root"

#################################
# OS CHECK
#################################
. /etc/os-release
if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    die "Only Ubuntu or Debian are supported (detected: $ID)"
fi

echo "==================================================="
echo "    ____  ____  ________  ____________"
echo "   / __ )/ __ \\/  _/ __ \\/ ____/ ____/"
echo "  / __  / /_/ // // / / / / __/ __/   "
echo " / /_/ / _, _// // /_/ / /_/ / /___   "
echo "/_____/_/ |_/___/_____/\\____/_____/   "
echo ""
echo "        RELAY SETUP — by qellyka        "
echo "==================================================="
echo ""

IP_REGEX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

#################################
# INSTALL DEPENDENCIES EARLY (needed for dig, if origin-domain is used)
#################################
log "Updating system (apt update && upgrade)..."
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt upgrade -y -qq
apt install -y -qq nftables dnsutils curl

#################################
# RESOLVE --origin-domain, IF USED
#################################
if [[ -n "$ORIGIN_DOMAIN" ]]; then
    log "Resolving origin domain $ORIGIN_DOMAIN..."
    RESOLVED_ORIGIN=$(dig +short "$ORIGIN_DOMAIN" A | tail -n1 || true)
    [[ "$RESOLVED_ORIGIN" =~ $IP_REGEX ]] || die "Could not resolve $ORIGIN_DOMAIN to a valid IPv4 address"
    ORIGIN_IP="$RESOLVED_ORIGIN"
    log "Origin domain $ORIGIN_DOMAIN resolved to $ORIGIN_IP"
fi

#################################
# VALIDATE ORIGIN IP
#################################
[[ "$ORIGIN_IP" =~ $IP_REGEX ]] || die "Origin IP looks invalid: $ORIGIN_IP"

#################################
# PROTECT SSH FROM ACCIDENTAL FORWARDING
#################################
PORT_RANGE_START="${PORT_RANGE%-*}"
PORT_RANGE_END="${PORT_RANGE#*-}"

if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [[ "$PORT_RANGE_START" =~ ^[0-9]+$ ]] && [[ "$PORT_RANGE_END" =~ ^[0-9]+$ ]]; then
    if (( SSH_PORT >= PORT_RANGE_START && SSH_PORT <= PORT_RANGE_END )); then
        die "SSH port ($SSH_PORT) falls inside the forwarding range ($PORT_RANGE) — this would lock you out via SSH! Change --ssh-port or --port-range."
    fi
fi
if [[ ",$TCP_PORTS," == *",$SSH_PORT,"* ]]; then
    die "SSH port ($SSH_PORT) is listed in --tcp-ports — this would lock you out via SSH!"
fi

#################################
# DETECT BRIDGE'S OWN PUBLIC IP
#################################
log "Detecting this server's public IP..."
PUBLIC_IP=""
for svc in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
    CANDIDATE=$(curl -s -4 --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$CANDIDATE" =~ $IP_REGEX ]]; then
        PUBLIC_IP="$CANDIDATE"
        break
    fi
done
[[ "$PUBLIC_IP" =~ $IP_REGEX ]] || die "Could not detect this server's public IP — check network connectivity"
log "Bridge public IP: $PUBLIC_IP"

LOCAL_IP=$(hostname -I | awk '{print $1}')

#################################
# CHECK --domain (the bridge's own public-facing name), IF PROVIDED
#################################
if [[ -n "$DOMAIN" ]]; then
    log "Checking DNS for $DOMAIN..."
    RESOLVED_IP=$(dig +short "$DOMAIN" A | tail -n1 || true)
    if [[ -z "$RESOLVED_IP" ]]; then
        warn "$DOMAIN does not resolve at all (missing A record, or DNS hasn't propagated yet)."
        warn "Create an A record: $DOMAIN -> $PUBLIC_IP, then wait for DNS propagation."
    elif [[ "$RESOLVED_IP" != "$PUBLIC_IP" ]]; then
        warn "$DOMAIN resolves to $RESOLVED_IP, not this server's IP ($PUBLIC_IP)."
        warn "Check the A record with your registrar — it currently points elsewhere."
    else
        log "$DOMAIN correctly resolves to $PUBLIC_IP."
    fi
fi

#################################
# DISABLE UFW (avoid conflicting with nftables)
#################################
if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "UFW is active — disabling it to avoid conflicts with nftables"
    ufw --force disable >/dev/null 2>&1 || true
fi

#################################
# KERNEL NETWORK STACK TUNING
#################################
log "Tuning kernel network stack..."
cat <<'SYSCTL_EOF' > /etc/sysctl.d/99-relay-optimization.conf
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.netfilter.nf_conntrack_max = 2000000
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.ipv4.conf.all.accept_local = 1
net.ipv4.conf.all.route_localnet = 1
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
SYSCTL_EOF
sysctl --system >/dev/null

#################################
# NFTABLES RULESET
#################################
log "Configuring forwarding rules (nftables)..."
[[ -f /etc/nftables.conf ]] && cp /etc/nftables.conf /etc/nftables.conf.bak

TCP_PORTS_SET="{ ${TCP_PORTS} }"

cat <<EOF > /etc/nftables.conf
#!/usr/sbin/nft -f
# Generated by bridge_setup.sh — by qellyka

flush ruleset

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport $TCP_PORTS_SET dnat to $ORIGIN_IP
        udp dport $TCP_PORTS_SET dnat to $ORIGIN_IP
        tcp dport $PORT_RANGE dnat to $ORIGIN_IP
        udp dport $PORT_RANGE dnat to $ORIGIN_IP
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr $ORIGIN_IP snat to $LOCAL_IP
    }
}

table inet mangle {
    chain forward {
        type filter hook forward priority mangle; policy accept;
        tcp flags syn tcp option maxseg size set rt mtu
    }
}

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state invalid drop
        ct state established,related accept
        iif lo accept
        tcp dport $SSH_PORT accept
        tcp dport $TCP_PORTS_SET accept
        udp dport $TCP_PORTS_SET accept
        tcp dport $PORT_RANGE accept
        udp dport $PORT_RANGE accept
        icmp type echo-request accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state invalid drop
        ct state established,related accept
        ip daddr $ORIGIN_IP accept
        ip saddr $ORIGIN_IP accept
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

nft -c -f /etc/nftables.conf || die "Syntax error in the generated ruleset — check /etc/nftables.conf"
nft -f /etc/nftables.conf
systemctl enable nftables >/dev/null 2>&1 || true
systemctl restart nftables

#################################
# SUMMARY
#################################
echo ""
echo "==================================================="
log "Done!"
echo "==================================================="
echo "Bridge public IP:      $PUBLIC_IP"
echo "Bridge local IP:       $LOCAL_IP"
if [[ -n "$ORIGIN_DOMAIN" ]]; then
    echo "Origin domain:          $ORIGIN_DOMAIN"
fi
echo "Origin IP:              $ORIGIN_IP"
echo "TCP/UDP ports:          $TCP_PORTS"
echo "Port range:             $PORT_RANGE"
echo "SSH port (protected):   $SSH_PORT"
if [[ -n "$DOMAIN" ]]; then
    echo "Bridge domain:          $DOMAIN"
fi
echo ""
echo "Clients connect to this server (by IP or domain),"
echo "all traffic on the configured ports is transparently forwarded to $ORIGIN_IP"
echo ""
echo "Script by qellyka"
echo "==================================================="
