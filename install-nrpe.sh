#!/bin/bash
# NRPE (daemon + check_nrpe plugin) on Ubuntu 26.04
# Works on a monitored host (agent) and on the Nagios server.
# Run as a normal user with sudo:  bash install-nrpe.sh
# Optional env vars:
#   ALLOWED_HOSTS=192.168.1.10,192.168.1.11   Nagios server IP(s) allowed to connect
#   NRPE_TAG=nrpe-4.2.0                       pin a version
set -u

PREFIX=/usr/local/nagios
CFG=$PREFIX/etc/nrpe.cfg
LOG=~/nrpe-log.txt
FALLBACK_TAG=nrpe-4.2.0
ALLOWED_HOSTS=${ALLOWED_HOSTS:-}

log() { echo "$*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

# ---------- packages ----------
log "== apt =="
sudo apt-get update
sudo apt-get install -y build-essential autoconf wget git openssl libssl-dev ca-certificates

# ---------- download ----------
TAG=${NRPE_TAG:-$(git ls-remote --tags --refs https://github.com/NagiosEnterprises/nrpe.git 2>/dev/null \
      | sed 's#.*refs/tags/##' | grep '^nrpe-' | sort -V | tail -n1)}
TAG=${TAG:-$FALLBACK_TAG}
log "NRPE version: $TAG"
W=$(mktemp -d); cd "$W" || exit 1
wget -q -O nrpe.tar.gz "https://github.com/NagiosEnterprises/nrpe/archive/refs/tags/${TAG}.tar.gz" \
  || die "download failed (tag $TAG)"
tar xzf nrpe.tar.gz
cd nrpe-* || die "cd nrpe"
[ -x ./configure ] || autoconf

# ---------- build ----------
MA=$(gcc -dumpmachine)
INIT=""
[ -d /run/systemd/system ] && INIT="--with-init-type=systemd"
./configure --with-ssl=/usr --with-ssl-lib=/usr/lib/$MA $INIT || die "configure"
make all || die "make"
sudo make install-groups-users
sudo make install          # daemon -> /usr/local/nagios/bin, check_nrpe -> /usr/local/nagios/libexec
sudo make install-config   # /usr/local/nagios/etc/nrpe.cfg
sudo make install-init

# systemd fallback if install-init did not provide a unit
if ! systemctl cat nrpe >/dev/null 2>&1; then
  log "no nrpe unit installed, writing one"
  sudo tee /etc/systemd/system/nrpe.service >/dev/null <<EOF
[Unit]
Description=Nagios Remote Plugin Executor
After=network.target

[Service]
User=nagios
Group=nagios
ExecStart=$PREFIX/bin/nrpe -c $CFG -f
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
fi

# ---------- config ----------
sudo sed -i "s/^allowed_hosts=.*/allowed_hosts=127.0.0.1,::1${ALLOWED_HOSTS:+,$ALLOWED_HOSTS}/" "$CFG"

# nrpe.cfg commands point at /usr/local/nagios/libexec. If the Nagios plugins are not
# there (plain agent box), install the distro plugins and repoint the commands.
if [ ! -x $PREFIX/libexec/check_load ]; then
  log "nagios plugins not found in libexec, installing monitoring-plugins"
  sudo apt-get install -y monitoring-plugins-basic monitoring-plugins-standard
  sudo sed -i 's#/usr/local/nagios/libexec/check_#/usr/lib/nagios/plugins/check_#' "$CFG"
fi

# firewall (only if ufw is active)
if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "Status: active"; then
  if [ -n "$ALLOWED_HOSTS" ]; then
    for h in ${ALLOWED_HOSTS//,/ }; do sudo ufw allow from "$h" to any port 5666 proto tcp; done
  else
    log "ufw is active: run  sudo ufw allow from <nagios-ip> to any port 5666 proto tcp"
  fi
fi

# check_nrpe command for Nagios (only on a Nagios server)
CMDS=$PREFIX/etc/objects/commands.cfg
if [ -f "$CMDS" ] && ! grep -q 'command_name *check_nrpe' "$CMDS"; then
  sudo tee -a "$CMDS" >/dev/null <<'EOF'

define command {
    command_name    check_nrpe
    command_line    $USER1$/check_nrpe -H $HOSTADDRESS$ -c $ARG1$
}
EOF
  if sudo $PREFIX/bin/nagios -v $PREFIX/etc/nagios.cfg >/dev/null 2>&1; then
    sudo systemctl restart nagios
    log "added check_nrpe command to commands.cfg"
  else
    log "WARN: nagios config check failed after adding check_nrpe, review $CMDS"
  fi
fi

# ---------- start ----------
sudo systemctl daemon-reload
sudo systemctl enable --now nrpe
sleep 2

log ""
log "NRPE status : $(systemctl is-active nrpe)"
log "Self test   : $($PREFIX/libexec/check_nrpe -H 127.0.0.1 2>&1)"
log "Config      : $CFG   (allowed_hosts: $(grep '^allowed_hosts=' "$CFG" | cut -d= -f2))"
[ -z "$ALLOWED_HOSTS" ] && log "Add your Nagios server:  sudo sed -i 's/^allowed_hosts=.*/&,<nagios-ip>/' $CFG && sudo systemctl restart nrpe"
log "From Nagios : $PREFIX/libexec/check_nrpe -H <this-host> -c check_load"
log "log file    : $LOG"
rm -rf "$W"
