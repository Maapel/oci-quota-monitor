#!/bin/bash
# OCI Free Tier Network Monitor
# Tracks monthly outbound transfer on enp0s6 against 10TB limit
# 90% (~9TB) → ntfy warning | 99% (~9.9TB) → ntfy urgent + stop services + poweroff

NTFY_URL="http://localhost:8600"
TOPIC="alerts"
LOG="/var/log/oci-quota-monitor.log"
STATE_FILE="/var/lib/oci-quota-monitor/state.json"
IFACE="enp0s6"
LIMIT_BYTES=10995116277760  # 10TB in bytes

_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

_notify() {
  local msg="$1" title="$2" priority="$3" tags="$4"
  curl -s -d "$msg" \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -H "Tags: $tags" \
    "$NTFY_URL/$TOPIC" > /dev/null
}

_get_tx_bytes() {
  awk "/^[ \t]*${IFACE}:/ {print \$10}" /proc/net/dev
}

# State helpers — all values stored as JSON strings to avoid Python type confusion
_state_get() {
  python3 -c "
import json
try:
    s = json.load(open('$STATE_FILE'))
except:
    s = {}
print(s.get('$1', '$2'))
" 2>/dev/null
}

_state_set() {
  local key="$1" val="$2"
  python3 -c "
import json
try:
    s = json.load(open('$STATE_FILE'))
except:
    s = {}
s['$key'] = '$val'
json.dump(s, open('$STATE_FILE', 'w'))
" 2>/dev/null
}

_emergency_shutdown() {
  _log "EMERGENCY SHUTDOWN: network at 99%+ of 10TB free tier limit"

  _notify "🚨🚨 NETWORK QUOTA CRITICAL — 99% of 10TB used. Stopping all services and powering off in 2 minutes. CHECK ORACLE CONSOLE NOW." \
    "SERVER SHUTTING DOWN 🚨" "urgent" "rotating_light,sos,no_entry"

  systemctl list-units --type=service --state=running --no-pager --plain \
    | awk '{print $1}' \
    | grep '\.service$' \
    | grep -vE "(systemd|getty|dbus|network|ssh(d)?\.service|nginx|postgresql|adguard|unattended|monitoring|oracle|snapd|polkit|multipathd|udev|accounts|fwupd|iscsid|ModemManager|rsyslog|udisks|user@|rpcbind|containerd)" \
    | while read -r svc; do
        _log "Stopping $svc"
        systemctl stop "$svc" 2>/dev/null
      done

  shutdown -h +2 "OCI 10TB network limit critical - emergency poweroff" &
}

# Get current TX bytes
CURRENT_TX=$(_get_tx_bytes)
if [ -z "$CURRENT_TX" ]; then
  _log "ERROR: could not read TX bytes for $IFACE"
  exit 1
fi

CURRENT_MONTH=$(date '+%Y-%m')
SAVED_MONTH=$(_state_get "month" "none")
ACCUMULATED=$(_state_get "accumulated_bytes" "0")
LAST_TX=$(_state_get "last_tx_bytes" "0")

# New month — reset
if [ "$SAVED_MONTH" != "$CURRENT_MONTH" ]; then
  _log "New month ($CURRENT_MONTH), resetting counter"
  _state_set "month" "$CURRENT_MONTH"
  _state_set "accumulated_bytes" "0"
  _state_set "last_tx_bytes" "$CURRENT_TX"
  _state_set "alerted_90" "no"
  _state_set "alerted_99" "no"
  ACCUMULATED=0
  LAST_TX=$CURRENT_TX
fi

# Reboot detection — kernel counter reset
if [ "$CURRENT_TX" -lt "$LAST_TX" ] 2>/dev/null; then
  _log "Reboot detected (TX reset $LAST_TX → $CURRENT_TX), carrying forward"
  ACCUMULATED=$((ACCUMULATED + LAST_TX))
  _state_set "accumulated_bytes" "$ACCUMULATED"
fi

_state_set "last_tx_bytes" "$CURRENT_TX"

TOTAL_BYTES=$((ACCUMULATED + CURRENT_TX))
PCT=$(python3 -c "print(round($TOTAL_BYTES / $LIMIT_BYTES * 100, 2))")
TOTAL_GB=$(python3 -c "print(round($TOTAL_BYTES / 1073741824, 1))")
_log "Outbound: ${TOTAL_GB}GB / 10240GB (${PCT}%)"

ALERTED_99=$(_state_get "alerted_99" "no")
ALERTED_90=$(_state_get "alerted_90" "no")

if python3 -c "exit(0 if float('$PCT') >= 99 else 1)" 2>/dev/null; then
  if [ "$ALERTED_99" != "yes" ]; then
    _notify "🚨 CRITICAL: Outbound network at ${PCT}% of 10TB (${TOTAL_GB}GB used). Emergency shutdown starting!" \
      "OCI Network Quota CRITICAL 🚨" "urgent" "rotating_light,sos"
    _state_set "alerted_99" "yes"
    _log "CRITICAL alert sent"
  fi
  _emergency_shutdown

elif python3 -c "exit(0 if float('$PCT') >= 90 else 1)" 2>/dev/null; then
  if [ "$ALERTED_90" != "yes" ]; then
    _notify "⚠️ WARNING: Outbound network at ${PCT}% of 10TB (${TOTAL_GB}GB used this month). Review traffic." \
      "OCI Network Quota Warning" "high" "warning"
    _state_set "alerted_90" "yes"
    _log "WARNING alert sent at ${PCT}%"
  fi
else
  _state_set "alerted_90" "no"
  _state_set "alerted_99" "no"
fi

# --daily mode: send summary notification
if [ "$1" = "--daily" ]; then
  DAYS_LEFT=$(python3 -c "
from datetime import date
import calendar
today = date.today()
last_day = calendar.monthrange(today.year, today.month)[1]
print(last_day - today.day)
")
  _notify "📊 OCI Network: ${TOTAL_GB}GB / 10240GB (${PCT}%) used this month. ${DAYS_LEFT} days left in billing cycle." \
    "OCI Daily Usage Report" "low" "bar_chart"
  _log "Daily report sent: ${TOTAL_GB}GB (${PCT}%)"
fi

exit 0
