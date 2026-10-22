#!/bin/bash
# Nagios Core 4.5.14 + Nagios Plugins + PNP4Nagios (PHP 8.5) on Ubuntu 26.04 Server
# Run as a normal user with sudo:  bash install-nagios.sh
set -u
SECONDS=0

NAGIOS_VER=4.5.14
PLUGINS_VER=2.5
PHPV=8.5
LOG=~/log.txt

log() { echo "$*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }

# wget with bounded retries
fetch() { # url outfile
  for n in 1 2 3 4 5; do
    wget -q -O "$2" "$1" && return 0
    log "download failed ($n/5): $1"; rm -f "$2"; sleep 5
  done
  return 1
}

export DEBIAN_FRONTEND=noninteractive

log "== apt: base =="
# auto-restart services during upgrades (needrestart)
[ -f /etc/needrestart/needrestart.conf ] && \
  sudo sed -i "s/^#\?\$nrconf{restart} = .*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
sudo apt-get update
sudo apt-get install -y software-properties-common ca-certificates lsb-release apt-transport-https

# PHP 8.5: use distro package if present, else Ondrej PPA
if ! apt-cache show php${PHPV} >/dev/null 2>&1; then
  log "php${PHPV} not in distro repo, adding ppa:ondrej/php"
  sudo LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
  sudo apt-get update
fi

log "== apt: nagios + php${PHPV} =="
sudo apt-get install -y autoconf gcc libc6 make wget unzip git apache2 apache2-utils \
  php${PHPV} libapache2-mod-php${PHPV} php${PHPV}-cli php${PHPV}-gd php${PHPV}-xml \
  libgd-dev openssl libssl-dev \
  libmcrypt-dev bc gawk dc build-essential snmp libnet-snmp-perl gettext
log "== apt: pnp4nagios deps =="
sudo apt-get install -y rrdtool librrds-perl
log "apt finished. ${SECONDS}s"

# mod_php needs prefork
sudo a2dismod -f mpm_event mpm_worker >/dev/null 2>&1
sudo a2enmod mpm_prefork rewrite cgi php${PHPV}

# ---------- Nagios Core ----------
cd /tmp || exit 1
log "downloading nagios-${NAGIOS_VER}"
fetch "https://github.com/NagiosEnterprises/nagioscore/releases/download/nagios-${NAGIOS_VER}/nagios-${NAGIOS_VER}.tar.gz" nagioscore.tar.gz \
  || die "nagios core download"
tar xzf nagioscore.tar.gz
cd /tmp/nagios-${NAGIOS_VER} || die "cd nagios"
sudo ./configure --with-httpd-conf=/etc/apache2/sites-enabled || die "nagios configure"
sudo make all || die "nagios make"
sudo make install-groups-users
sudo usermod -a -G nagios www-data
sudo make install
sudo make install-daemoninit
sudo make install-commandmode
sudo make install-config
sudo make install-webconf

log "creating nagiosadmin/nagiosadmin"
sudo htpasswd -b -c /usr/local/nagios/etc/htpasswd.users nagiosadmin nagiosadmin

# ---------- Exfoliation theme (dark mode capable) ----------
SS=/usr/local/nagios/share/stylesheets
THEME_URL=https://github.com/jbrek/4.5.14/raw/refs/heads/main/nagios-stylesheets.tar.gz
if wget -q -O /tmp/nagios-stylesheets.tar.gz "$THEME_URL"; then
  sudo cp -an "$SS" "$SS.orig"
  sudo tar -xzf /tmp/nagios-stylesheets.tar.gz -C "$SS"
  sudo chown -R root:root "$SS"; sudo chmod 644 "$SS"/*.css
  log "theme installed"
else
  log "WARN: theme download failed, using default Nagios theme"
fi

# ---------- Nagios Plugins ----------
cd /tmp || exit 1
log "downloading nagios-plugins-${PLUGINS_VER}"
fetch "https://github.com/nagios-plugins/nagios-plugins/releases/download/release-${PLUGINS_VER}/nagios-plugins-${PLUGINS_VER}.tar.gz" nagios-plugins.tar.gz \
  || die "plugins download"
tar zxf nagios-plugins.tar.gz
cd /tmp/nagios-plugins-${PLUGINS_VER} || die "cd plugins"
sudo ./tools/setup
sudo ./configure
sudo make
sudo make install

# ---------- PNP4Nagios (PHP 8+ fork) ----------
log "== PNP4Nagios =="
cd /tmp || exit 1
rm -rf /tmp/pnp4nagios
git clone --depth 1 https://github.com/pnp4nagios/pnp4nagios.git || die "pnp4nagios clone"
cd /tmp/pnp4nagios || exit 1
sudo ./configure --with-nagios-user=nagios --with-nagios-group=nagios \
  --with-httpd-conf=/etc/apache2/sites-enabled || die "pnp configure"
sudo make all || die "pnp make"
# sample-config step reads /etc/nagios/nagios.cfg; point it at our nagios.cfg temporarily
sudo mkdir -p /etc/nagios
sudo ln -sf /usr/local/nagios/etc/nagios.cfg /etc/nagios/nagios.cfg
sudo make fullinstall || die "pnp install"
sudo rm -f /etc/nagios/nagios.cfg; sudo rmdir /etc/nagios 2>/dev/null
# apache config for pnp: use the sample shipped with pnp4nagios
sudo cp /usr/local/pnp4nagios/etc/config_samples/http_server_apache/pnp4nagios.conf /etc/apache2/conf-available/pnp4nagios.conf
PF=/etc/apache2/conf-available/pnp4nagios.conf
sudo sed -i 's#^\(\s*AuthUserFile\).*#\1 /usr/local/nagios/etc/htpasswd.users#' $PF
# drop the IfVersion blocks: "Require all granted" there would bypass the login
sudo sed -i '/<IfVersion >= 2.3>/,/<\/IfVersion>/d; /<IfVersion < 2.3>/,/<\/IfVersion>/d' $PF
sudo a2enconf pnp4nagios
# post-install: remove installer check, enable npcd
sudo rm -f /usr/local/pnp4nagios/share/install.php
# PHP 8.5 vs old Kohana: disable PCRE JIT, replace removed E_STRICT constant
echo "pcre.jit=0" | sudo tee /etc/php/${PHPV}/apache2/conf.d/99-pcre-jit.ini >/dev/null
grep -rl 'E_STRICT' /usr/local/pnp4nagios/share 2>/dev/null | sudo xargs -r sed -i.bak 's/\bE_STRICT\b/2048/g'
sudo sed -i 's/^RUN_AS_USER=.*/&/' /usr/local/pnp4nagios/etc/npcd.cfg 2>/dev/null
sudo systemctl enable npcd 2>/dev/null || sudo update-rc.d npcd defaults

# wire PNP into nagios (bulk mode + npcd)
NCFG=/usr/local/nagios/etc/nagios.cfg
if ! grep -q "PNP4NAGIOS" "$NCFG"; then
  sudo sed -i 's/^process_performance_data=.*/process_performance_data=1/' "$NCFG"
  sudo tee -a "$NCFG" >/dev/null <<'EOF'

# --- PNP4NAGIOS bulk mode w/ npcd ---
service_perfdata_file=/usr/local/pnp4nagios/var/service-perfdata
service_perfdata_file_template=DATATYPE::SERVICEPERFDATA\tTIMET::$TIMET$\tHOSTNAME::$HOSTNAME$\tSERVICEDESC::$SERVICEDESC$\tSERVICEPERFDATA::$SERVICEPERFDATA$\tSERVICECHECKCOMMAND::$SERVICECHECKCOMMAND$\tHOSTSTATE::$HOSTSTATE$\tHOSTSTATETYPE::$HOSTSTATETYPE$\tSERVICESTATE::$SERVICESTATE$\tSERVICESTATETYPE::$SERVICESTATETYPE$
service_perfdata_file_mode=a
service_perfdata_file_processing_interval=15
service_perfdata_file_processing_command=process-service-perfdata-file

host_perfdata_file=/usr/local/pnp4nagios/var/host-perfdata
host_perfdata_file_template=DATATYPE::HOSTPERFDATA\tTIMET::$TIMET$\tHOSTNAME::$HOSTNAME$\tHOSTPERFDATA::$HOSTPERFDATA$\tHOSTCHECKCOMMAND::$HOSTCHECKCOMMAND$\tHOSTSTATE::$HOSTSTATE$\tHOSTSTATETYPE::$HOSTSTATETYPE$
host_perfdata_file_mode=a
host_perfdata_file_processing_interval=15
host_perfdata_file_processing_command=process-host-perfdata-file
EOF
  sudo tee -a /usr/local/nagios/etc/objects/commands.cfg >/dev/null <<'EOF'

# --- PNP4NAGIOS ---
define command {
    command_name    process-service-perfdata-file
    command_line    /bin/mv /usr/local/pnp4nagios/var/service-perfdata /usr/local/pnp4nagios/var/spool/pnp4nagios/service-perfdata.$TIMET$
}
define command {
    command_name    process-host-perfdata-file
    command_line    /bin/mv /usr/local/pnp4nagios/var/host-perfdata /usr/local/pnp4nagios/var/spool/pnp4nagios/host-perfdata.$TIMET$
}
EOF
fi

# graph icons (action_url) on all localhost checks
sudo tee /usr/local/nagios/etc/objects/pnp-templates.cfg >/dev/null <<'EOF2'
define host {
    name            host-pnp
    action_url      /pnp4nagios/index.php/graph?host=$HOSTNAME$&srv=_HOST_
    process_perf_data 1
    register        0
}
define service {
    name            srv-pnp
    action_url      /pnp4nagios/index.php/graph?host=$HOSTNAME$&srv=$SERVICEDESC$
    process_perf_data 1
    register        0
}
EOF2
grep -q pnp-templates.cfg "$NCFG" || \
  echo "cfg_file=/usr/local/nagios/etc/objects/pnp-templates.cfg" | sudo tee -a "$NCFG" >/dev/null
LH=/usr/local/nagios/etc/objects/localhost.cfg
sudo cp -n "$LH" "$LH.orig"
sudo sed -i -E 's/^(\s*use\s+)local-service\b/\1local-service,srv-pnp/; s/^(\s*use\s+)linux-server\b/\1linux-server,host-pnp/' "$LH"

# ---------- Start ----------
log "validating nagios config"
sudo /usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg | tail -n 5 | tee -a "$LOG"

sudo systemctl daemon-reload
sudo systemctl enable nagios apache2
sudo systemctl restart apache2 npcd nagios

log "FINISHED. ${SECONDS}s"
ip=$(hostname -I | awk '{print $1}')
log "nagios : http://${ip}/nagios   (nagiosadmin/nagiosadmin)"
log "pnp4nagios : http://${ip}/pnp4nagios"
log "log file at /tmp/install-nagios.log"
cp "$LOG" /tmp/install-nagios.log
rm -f "$LOG"
