#!/usr/bin/env bash
# Turns a fresh, desktop-less Debian 13 install into a 24/7 signage kiosk.
#
#   sudo bash install.sh [screen-id]
#
# The screen shows whatever URL kiosk/screens.json assigns to its screen id.
# Env overrides: REPO_RAW (where screens.json lives), TS_AUTHKEY (unattended
# Tailscale login), SKIP_TAILSCALE=1.
set -euo pipefail

SCREEN_ID="${1:-rw-hallway}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/camoandsky/camoandsky/claude/code-connections-tokens-p5evlu/kiosk}"
KIOSK_USER=kiosk

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash $0 $SCREEN_ID" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

step "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  cage chromium curl jq iw ca-certificates unattended-upgrades \
  fonts-noto-core fonts-noto-color-emoji
# GPU/Wi-Fi firmware for the HP 14-dk1 (AMD Radeon, usually Realtek Wi-Fi).
# Needs the non-free-firmware component; the installer normally enables it.
apt-get install -y firmware-amd-graphics firmware-realtek || echo "(firmware packages skipped)"

step "Configuring screen id '$SCREEN_ID'"
hostnamectl set-hostname "$SCREEN_ID"
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$SCREEN_ID/" /etc/hosts
mkdir -p /etc/kiosk /var/lib/kiosk
cat > /etc/kiosk/kiosk.conf <<CONF
SCREEN_ID=$SCREEN_ID
REPO_RAW=$REPO_RAW
CONF

step "Creating kiosk user with autologin on tty1"
id "$KIOSK_USER" &>/dev/null || useradd -m -s /bin/bash -G video,render,input "$KIOSK_USER"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<CONF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
CONF
cat > "/home/$KIOSK_USER/.bash_profile" <<'CONF'
if [[ -z ${WAYLAND_DISPLAY:-} && $(tty) == /dev/tty1 ]]; then
  exec /usr/local/bin/kiosk-session
fi
CONF
chown "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER/.bash_profile"

cat > /usr/local/bin/kiosk-session <<'CONF'
#!/usr/bin/env bash
# Runs as the kiosk user on tty1. Relaunches the browser whenever it exits;
# kiosk-sync kills it to switch URLs, kiosk-restart.timer kills it nightly.
LOG="$HOME/kiosk.log"
PROFILE="$HOME/.config/chromium-kiosk"
while true; do
  [[ -f $LOG && $(stat -c %s "$LOG") -gt 5000000 ]] && : > "$LOG"
  # Give the network up to a minute so the first page load doesn't fail.
  for _ in $(seq 30); do curl -fsI --max-time 3 https://www.google.com >/dev/null 2>&1 && break; sleep 2; done
  URL=$(cat /var/lib/kiosk/url 2>/dev/null || echo about:blank)
  # Suppress the "Chromium didn't shut down correctly" bar after a kill.
  sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]*"/"exit_type":"Normal"/' \
    "$PROFILE/Default/Preferences" 2>/dev/null
  echo "$(date '+%F %T') launching $URL" >> "$LOG"
  cage -d -s -m last -- chromium \
    --ozone-platform=wayland --kiosk --user-data-dir="$PROFILE" \
    --noerrdialogs --disable-infobars --no-first-run --disable-session-crashed-bubble \
    --disable-features=Translate,TranslateUI --disable-pinch --overscroll-history-navigation=0 \
    --check-for-update-interval=31536000 --password-store=basic \
    --autoplay-policy=no-user-gesture-required \
    "$URL" >> "$LOG" 2>&1
  sleep 2
done
CONF
chmod 755 /usr/local/bin/kiosk-session

step "Installing content sync (checks screens.json every minute)"
cat > /usr/local/bin/kiosk-sync <<'CONF'
#!/usr/bin/env bash
# Pulls this screen's URL from screens.json; restarts the browser if it changed.
set -u
source /etc/kiosk/kiosk.conf
for dev in /sys/class/net/wl*; do [[ -e $dev ]] && iw dev "${dev##*/}" set power_save off 2>/dev/null; done
json=$(curl -fsSL --max-time 20 "$REPO_RAW/screens.json") || exit 0
url=$(jq -r --arg id "$SCREEN_ID" '.screens[$id].url // empty' <<<"$json") || exit 0
[[ -n $url ]] || { echo "no entry for '$SCREEN_ID' in screens.json"; exit 0; }
if [[ $url != "$(cat /var/lib/kiosk/url 2>/dev/null)" ]]; then
  echo "$url" > /var/lib/kiosk/url
  echo "URL -> $url"
  pkill -u kiosk -x chromium || true
fi
CONF
chmod 755 /usr/local/bin/kiosk-sync

cat > /etc/systemd/system/kiosk-sync.service <<'CONF'
[Unit]
Description=Sync kiosk URL from screens.json
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/kiosk-sync
CONF
cat > /etc/systemd/system/kiosk-sync.timer <<'CONF'
[Unit]
Description=Sync kiosk URL every minute
[Timer]
OnBootSec=20s
OnUnitActiveSec=60s
[Install]
WantedBy=timers.target
CONF
cat > /etc/systemd/system/kiosk-restart.service <<'CONF'
[Unit]
Description=Restart kiosk browser (clears memory leaks)
[Service]
Type=oneshot
ExecStart=-/usr/bin/pkill -u kiosk -x chromium
CONF
cat > /etc/systemd/system/kiosk-restart.timer <<'CONF'
[Unit]
Description=Nightly kiosk browser restart
[Timer]
OnCalendar=*-*-* 04:00
[Install]
WantedBy=timers.target
CONF

step "Disabling sleep, lid-close suspend and console blanking"
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/kiosk.conf <<'CONF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
CONF
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
if ! grep -q consoleblank=0 /etc/default/grub; then
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&consoleblank=0 /' /etc/default/grub
  update-grub
fi

step "Realtek Wi-Fi stability tweaks (no-op on other chips)"
cat > /etc/modprobe.d/kiosk-rtw88.conf <<'CONF'
options rtw88_core disable_lps_deep=y
options rtw88_pci disable_aspm=y
CONF

step "Enabling automatic security updates (reboot at 04:30 if needed)"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
cat > /etc/apt/apt.conf.d/52kiosk-upgrades <<'CONF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
CONF

systemctl daemon-reload
systemctl enable kiosk-sync.timer kiosk-restart.timer
step "Fetching initial URL"
/usr/local/bin/kiosk-sync
[[ -s /var/lib/kiosk/url ]] || echo "WARNING: could not fetch a URL for '$SCREEN_ID' yet; the screen will pick it up once online."

if [[ ${SKIP_TAILSCALE:-0} != 1 ]]; then
  step "Installing Tailscale for remote access"
  if curl -fsSL https://tailscale.com/install.sh | sh; then
    if [[ -n ${TS_AUTHKEY:-} ]]; then
      tailscale up --ssh --hostname "$SCREEN_ID" --authkey "$TS_AUTHKEY"
    else
      echo "Scan the QR code with your phone (or type the link) and log in to Tailscale:"
      tailscale up --ssh --hostname "$SCREEN_ID" --qr || echo "(Tailscale login skipped; run: sudo tailscale up --ssh --qr)"
    fi
  else
    echo "(Tailscale install failed; retry later with: curl -fsSL https://tailscale.com/install.sh | sh)"
  fi
fi

step "Done. Rebooting into kiosk mode in 10 seconds (Ctrl+C to cancel)"
sleep 10
reboot
