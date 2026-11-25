#!/usr/bin/env bash
# Automates the mechanical phases (1.5-5) of the hardening procedure in harden-vm.md: apt
# update/upgrade, root SSH key injection, ufw base rules, ufw-docker install + per-container allow,
# sshd hardening -- each gated by a fresh-connection root-login check before the next destructive
# step runs. Also runs setup-unattended-upgrades.sh (same directory) so a newly-hardened host comes
# up with daily apt upgrades + 04:00 auto-reboot already configured, instead of that being a separate
# manual pass -- idempotent, safe to re-run even on hosts that already have it. Read harden-vm.md first: this script
# does NOT do Phase 1 (investigation) or Phase 6 (old-account removal decision) -- those require
# judgment calls about what depends on the host's current listening ports and the account being
# phased out. Run from your workstation; requires the host already reachable via the given identity
# file as its current login user with (passwordless, for this run) sudo.
#
# Usage:
#   harden-vm.sh <ssh-alias> <local-identity-file> <host-ip> [extra-ufw-ports] [--remove-user=<name>] [--github-user=<name>]
#
#   <ssh-alias>            ~/.ssh/config alias already pointing at the host (current login user)
#   <local-identity-file>  private key file used for the post-injection root-login verification.
#                          Also the source of the pubkey installed for root, UNLESS --github-user is
#                          given -- so it must still match (or be among) whatever key material root
#                          ends up trusting.
#   <host-ip>              host's IP, used to bypass ~/.ssh/config for the root-login verification
#   [extra-ufw-ports]      quoted, space-separated list e.g. "80/tcp 443/tcp 53/udp" -- bare-metal
#                          ports found in Phase 1 that need an explicit ufw allow. Omit/empty if the
#                          host has none (Docker-only hosts commonly need none here at all).
#   [--remove-user=<name>] only pass this once Phase 1 + Phase 6 of harden-vm.md confirm it's safe.
#                          Without it, the script stops after verifying root login post-hardening and
#                          leaves the old account alone.
#   [--github-user=<name>] install every public key listed at https://github.com/<name>.keys instead
#                          of deriving one key from <local-identity-file>. Useful for covering
#                          multiple admin devices in one pass; <local-identity-file> must still be one
#                          of the keys GitHub is serving for the verification steps to pass.
#
# Example:
#   scripts/harden-vm.sh media ~/.ssh/community-mg 10.10.71 "" --remove-user=purgos
#   scripts/harden-vm.sh dns-1 ~/.ssh/infrastructure 10.10.2 "53/tcp 53/udp 80/tcp 443/tcp" --remove-user=purgos
#   scripts/harden-vm.sh crafty ~/.ssh/community-mg 10.10.112 "" --github-user=purgos-homelab
set -uo pipefail

ALIAS="${1:?Usage: harden-vm.sh <ssh-alias> <identity-file> <host-ip> [extra-ufw-ports] [--remove-user=<name>] [--github-user=<name>]}"
IDFILE="${2:?identity file required}"
IP="${3:?host IP required}"
EXTRA_PORTS="${4:-}"
REMOVE_USER=""
GITHUB_USER=""
for arg in "$@"; do
  case "$arg" in
    --remove-user=*) REMOVE_USER="${arg#--remove-user=}" ;;
    --github-user=*) GITHUB_USER="${arg#--github-user=}" ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "########## $ALIAS ##########"

if [ -n "$GITHUB_USER" ]; then
  PUBKEY=$(curl -fsSL "https://github.com/$GITHUB_USER.keys") || { echo "ABORT($ALIAS): couldn't fetch keys from github.com/$GITHUB_USER"; exit 1; }
  [ -n "$PUBKEY" ] || { echo "ABORT($ALIAS): https://github.com/$GITHUB_USER.keys returned no keys"; exit 1; }
else
  PUBKEY=$(ssh-keygen -y -f "$IDFILE" 2>&1) || { echo "ABORT($ALIAS): couldn't read pubkey from $IDFILE"; exit 1; }
fi

echo "[1/8] apt update && apt upgrade"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$ALIAS" "
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update && sudo apt-get -y upgrade
" || { echo "ABORT($ALIAS): apt update/upgrade failed"; exit 1; }

echo "[2/8] injecting root authorized_keys"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$ALIAS" "
  sudo install -d -m700 -o root -g root /root/.ssh &&
  echo '$PUBKEY' | sudo tee /root/.ssh/authorized_keys >/dev/null &&
  sudo chmod 600 /root/.ssh/authorized_keys &&
  sudo chown root:root /root/.ssh/authorized_keys
" || { echo "ABORT($ALIAS): key injection failed"; exit 1; }

echo "[3/8] verifying root login works"
ssh -o ConnectTimeout=8 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i "$IDFILE" "root@$IP" true \
  || { echo "ABORT($ALIAS): root login via key failed, not proceeding"; exit 1; }

echo "[4/8] ufw base rules (extra bare-metal ports: ${EXTRA_PORTS:-none})"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$ALIAS" "
  sudo ufw allow OpenSSH >/dev/null 2>&1 || sudo ufw allow 22/tcp
  if ip link show tailscale0 >/dev/null 2>&1; then sudo ufw allow in on tailscale0; fi
  for p in $EXTRA_PORTS; do sudo ufw allow \"\$p\"; done
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw --force enable
" || { echo "ABORT($ALIAS): ufw base setup failed"; exit 1; }

echo "[5/8] ufw-docker install + per-container allow (no-op if no Docker)"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$ALIAS" '
  if command -v docker >/dev/null 2>&1; then
    if [ ! -x /usr/local/bin/ufw-docker ]; then
      sudo curl -fsSL https://raw.githubusercontent.com/chaifeng/ufw-docker/master/ufw-docker -o /usr/local/bin/ufw-docker
      sudo chmod +x /usr/local/bin/ufw-docker
    fi
    sudo /usr/local/bin/ufw-docker install
    sudo systemctl restart ufw
    for c in $(sudo docker ps --format "{{.Names}}"); do
      ports=$(sudo docker port "$c" 2>/dev/null)
      if [ -n "$ports" ]; then
        echo "  allowing $c"
        sudo /usr/local/bin/ufw-docker allow "$c" || echo "  (warn: ufw-docker allow failed for $c)"
      fi
    done
  else
    echo "No docker on this host, nothing to do."
  fi
' || { echo "ABORT($ALIAS): ufw-docker phase failed"; exit 1; }
echo "  NOTE: if Phase 1 of harden-vm.md found docker-proxy-bound ports on this host, those need"
echo "  their own explicit ufw allow <port> too -- ufw-docker allow alone won't cover them."

echo "[6/8] unattended-upgrades (daily apt upgrade + autoremove, 04:00 auto-reboot)"
scp -o ConnectTimeout=8 -o BatchMode=yes "$REPO_DIR/Scripts/setup-unattended-upgrades.sh" "$ALIAS:/tmp/setup-unattended-upgrades.sh" \
  && ssh -o ConnectTimeout=8 -o BatchMode=yes "$ALIAS" "sudo bash /tmp/setup-unattended-upgrades.sh && rm -f /tmp/setup-unattended-upgrades.sh" \
  || { echo "ABORT($ALIAS): unattended-upgrades setup failed"; exit 1; }

echo "[7/8] sshd hardening"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$ALIAS" '
  set -e
  f=/etc/ssh/sshd_config
  for pair in "PermitRootLogin:prohibit-password" "PasswordAuthentication:no" "KbdInteractiveAuthentication:no"; do
    key="${pair%%:*}"; val="${pair##*:}"
    if grep -qE "^#?${key}\b" "$f"; then
      sudo sed -i "s/^#\?${key}\b.*/${key} ${val}/" "$f"
    else
      echo "${key} ${val}" | sudo tee -a "$f" >/dev/null
    fi
  done
  if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
    sudo sed -i "s/^PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config.d/50-cloud-init.conf
  fi
  sudo systemctl restart ssh || sudo systemctl restart sshd
' || { echo "ABORT($ALIAS): sshd hardening failed"; exit 1; }

echo "[8/8] verifying root login survives sshd restart"
sleep 1
ssh -o ConnectTimeout=8 -o BatchMode=yes -o IdentitiesOnly=yes -i "$IDFILE" "root@$IP" true \
  || { echo "ABORT($ALIAS): root login broken after sshd restart -- investigate manually, old account NOT touched"; exit 1; }

if [ -n "$REMOVE_USER" ]; then
  echo "[extra] removing $REMOVE_USER (Phase 6 of harden-vm.md was already confirmed safe for this, right?)"
  ssh -o ConnectTimeout=8 -o BatchMode=yes -o IdentitiesOnly=yes -i "$IDFILE" "root@$IP" "
    pkill -9 -u '$REMOVE_USER' 2>/dev/null || true
    sleep 1
    userdel -r '$REMOVE_USER' 2>&1 || true
    id '$REMOVE_USER' >/dev/null 2>&1 && echo 'WARN: $REMOVE_USER still exists' || echo '$REMOVE_USER removed OK'
  "
else
  echo "[extra] no --remove-user given -- old account left in place"
fi

echo "########## $ALIAS DONE ##########"
echo "Reminder: run Phase 7 (docs) and Phase 8 (post-hardening smoke tests) from harden-vm.md manually."
