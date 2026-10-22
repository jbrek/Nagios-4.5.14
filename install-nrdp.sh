#!/bin/bash
# NRDP (Nagios Remote Data Processor) on Ubuntu 26.04 - run on the Nagios server
# Run as a normal user with sudo:  bash install-nrdp.sh
# Optional env vars:  TOKEN=<your token>  NRDP_TAG=2.0.6
set -u

NRDP_DIR=/usr/local/nrdp
CFG=$NRDP_DIR/server/config.inc.php
LOG=~/nrdp-log.txt
FALLBACK_TAG=2.0.6

log() { echo "$*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }

id nagios >/dev/null 2>&1 || die "nagios user not found - install Nagios Core first"
export DEBIAN_FRONTEND=noninteractive

# ---------- packages ----------
log "== apt =="
sudo apt-get update
sudo apt-get install -y apache2 git wget curl openssl
PHPV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
if [ -z "$PHPV" ]; then
  PHPV=8.5
  sudo apt-get install -y php${PHPV} libapache2-mod-php${PHPV}
  sudo a2dismod -f mpm_event mpm_worker >/dev/null 2>&1
  sudo a2enmod mpm_prefork php${PHPV}
fi
sudo apt-get install -y php${PHPV}-xml

# apache (www-data) must be in the nagios group to write the command file / check results
sudo usermod -a -G nagios www-data

# ---------- download ----------
TAG=${NRDP_TAG:-$(git ls-remote --tags --refs https://github.com/NagiosEnterprises/nrdp.git 2>/dev/null \
      | sed 's#.*refs/tags/##' | sort -V | tail -n1)}
TAG=${TAG:-$FALLBACK_TAG}
log "NRDP version: $TAG"
W=$(mktemp -d); cd "$W" || exit 1
wget -q -O nrdp.tar.gz "https://github.com/NagiosEnterprises/nrdp/archive/refs/tags/${TAG}.tar.gz" \
  || die "download failed (tag $TAG)"
tar xzf nrdp.tar.gz
cd nrdp-* || die "cd nrdp"

# ---------- install ----------
KEEP=""
if [ -f "$CFG" ]; then
  sudo cp "$CFG" /tmp/nrdp-config.keep && KEEP=1
  log "existing config found, keeping it"
fi
sudo mkdir -p "$NRDP_DIR"
sudo cp -r clients server LICENSE* CHANGES* "$NRDP_DIR"
if [ -n "$KEEP" ]; then
  sudo cp /tmp/nrdp-config.keep "$CFG"
  TOKEN="(unchanged - see $CFG)"
else
  TOKEN=${TOKEN:-$(openssl rand -hex 16)}
  # later assignment overrides the empty default array
  echo "\$cfg[\"authorized_tokens\"] = array(\"$TOKEN\");" | sudo tee -a "$CFG" >/dev/null
  sudo sed -i 's/^\(\$cfg\["nagios_command_group"\] *= *\)"[^"]*";/\1"nagios";/' "$CFG"
fi
sudo chown -R nagios:nagios "$NRDP_DIR"

# ---------- apache ----------
sudo cp nrdp.conf /etc/apache2/conf-available/nrdp.conf
sudo a2enconf nrdp
sudo apache2ctl configtest || die "apache config error"
sudo systemctl restart apache2
sudo systemctl restart nagios 2>/dev/null

# ---------- test ----------
sleep 2
IP=$(hostname -I | awk '{print $1}')
CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/nrdp/)
log "http://localhost/nrdp/ -> HTTP $CODE"
if [ -z "$KEEP" ]; then
  R=$(curl -s --data-urlencode "token=$TOKEN" -d "cmd=submitcheck" \
      --data-urlencode "xml=<?xml version='1.0'?><checkresults><checkresult type='host'><hostname>localhost</hostname><state>0</state><output>NRDP install test</output></checkresult></checkresults>" \
      http://localhost/nrdp/)
  echo "$R" | grep -q '<status>0</status>' && log "test submit: OK" || log "test submit FAILED: $R"
fi

log ""
log "NRDP installed."
log "URL     : http://${IP}/nrdp/"
log "Token   : $TOKEN"
log "Config  : $CFG"
log "Client  : ./send_nrdp.sh -u http://${IP}/nrdp/ -t <token> -H <host> -s <service> -S 0 -o \"OK\""
log "log file: $LOG"
rm -rf "$W"
