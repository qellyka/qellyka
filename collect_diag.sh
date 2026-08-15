#!/usr/bin/env bash
# Diagnostic collector — read-only, nothing is modified on the system.
OUT="/root/diag_$(date +%Y%m%d_%H%M%S).txt"

section() {
  echo ""
  echo "======================================================================"
  echo "=== $1"
  echo "======================================================================"
}

{
  section "1. FIREWALL RULES (nftables/iptables)"
  nft list ruleset 2>/dev/null || iptables-save

  section "2. LISTENING PORTS / PROCESSES"
  ss -tulnp

  section "3. RUNNING SERVICES"
  systemctl list-units --type=service --state=running --no-pager

  section "4. CRONTAB (root)"
  crontab -l -u root 2>/dev/null
  echo "--- /etc/cron.d/ ---"
  ls -la /etc/cron.d/ 2>/dev/null
  cat /etc/cron.d/* 2>/dev/null

  section "5. NGINX FULL CONFIG"
  nginx -T 2>/dev/null

  section "6. CERTBOT — ALL ISSUED CERTIFICATES (reveals every domain in use)"
  certbot certificates 2>/dev/null

  section "7. 3X-UI DATABASE — INBOUNDS (actual Xray settings, not just process list)"
  DB=$(find / -iname "x-ui.db" 2>/dev/null | head -1)
  if [[ -n "$DB" ]]; then
    echo "DB found at: $DB"
    sqlite3 "$DB" "SELECT id, remark, port, protocol, settings, stream_settings FROM inbounds;" 2>/dev/null \
      || echo "(sqlite3 not installed — run: apt install -y sqlite3, then re-run this script)"
  else
    echo "x-ui.db not found — panel may store config elsewhere, or this isn't 3x-ui"
  fi

  section "8. DOMAIN CHECK — resolving all domains found in nginx/certbot output above"
  for d in $(grep -oE '[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' /etc/nginx/sites-enabled/* 2>/dev/null | sort -u); do
    echo "--- $d ---"
    dig +short "$d" A
  done

  section "9. INSTALLED PACKAGES (last 60, most recently installed first)"
  ls -lt /var/lib/dpkg/info/*.list 2>/dev/null | head -60 | awk -F/ '{print $NF}' | sed 's/.list$//'

  section "10. FILES CHANGED SINCE OS BASE INSTALL (heuristic, may include false positives)"
  find / -newer /etc/hostname -type f 2>/dev/null \
    | grep -vE '^/(proc|sys|tmp|run|var/log|var/lib/apt|var/cache)' \
    | head -150

  section "11. NETWORK INTERFACES (for wireguard/awg adapters — WARP, AmneziaWG, etc.)"
  ip -brief link show
  echo "--- wg/awg specific ---"
  wg show 2>/dev/null
  awg show 2>/dev/null

} > "$OUT" 2>&1

echo ""
echo "Done. Saved to: $OUT"
echo "Download it, e.g. from your machine:"
echo "  scp root@$(hostname -I | awk '{print $1}'):$OUT ."
