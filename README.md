# Nagios Core 4.5.14 installer for Ubuntu 26.04

One script that builds Nagios Core from source on a fresh Ubuntu 26.04 LTS server, with graphs and a dark theme.

## What it installs

- Nagios Core **4.5.14** (built from source, `/usr/local/nagios`)
- Nagios Plugins **2.5** (built from source, `/usr/local/nagios/libexec`)
- Apache 2 with **PHP 8.5** (`mod_php`, prefork)
- **PNP4Nagios** (PHP 8+ fork from `pnp4nagios/pnp4nagios`) with `npcd` and bulk mode, at `/pnp4nagios`
- **Exfoliation** theme with dark mode (follows the browser/OS setting)
- Graph icons on every check in `localhost.cfg`

## Install

```bash
wget https://raw.githubusercontent.com/jbrek/4.5.14/main/install-nagios.sh
bash install-nagios.sh
```

Run as a normal user with `sudo`. Takes about 3 minutes. Log: `/tmp/install-nagios.log`.

| URL | Purpose |
|---|---|
| `http://<ip>/nagios` | Nagios web UI |
| `http://<ip>/pnp4nagios` | PNP4Nagios graphs |

Login: `nagiosadmin` / `nagiosadmin`. **Change it after install:**

```bash
sudo htpasswd /usr/local/nagios/etc/htpasswd.users nagiosadmin
```

Graphs appear a few minutes after the first checks run.

## Versions

Set at the top of the script:

```bash
NAGIOS_VER=4.5.14
PLUGINS_VER=2.5
PHPV=8.5
```

## What the script changes

- **PHP 8.5:** uses the distro package, and only adds `ppa:ondrej/php` if the distro does not have it.
- **PNP4Nagios:** the sample Apache config is copied to `conf-available/pnp4nagios.conf`. The `Require all granted` block is removed so the Nagios login is required, and `AuthUserFile` is pointed at `htpasswd.users`.
- **PHP 8.5 workarounds for PNP:** `pcre.jit=0` and `E_STRICT` replaced with `2048` (originals kept as `*.bak`).
- **Perfdata:** `nagios.cfg` and `commands.cfg` are set up for npcd bulk mode. Files are moved to `/usr/local/pnp4nagios/var/spool/pnp4nagios/`.
- **Graph icons:** `objects/pnp-templates.cfg` adds `action_url` to `host-pnp` and `srv-pnp`. `localhost.cfg` uses them (original saved as `localhost.cfg.orig`).
- **Theme:** `nagios-stylesheets.tar.gz` from this repo is extracted into `share/stylesheets` (original saved as `stylesheets.orig`). If the download fails, the default theme stays.

To add graphs to other hosts and services, add the templates to them:

```
use linux-server,host-pnp          # hosts
use local-service,srv-pnp          # services
```

## Troubleshooting

```bash
sudo /usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg   # config check
systemctl status nagios apache2 npcd
ls /usr/local/pnp4nagios/var/spool/pnp4nagios                           # should be empty (npcd consumes it)
ls /usr/local/pnp4nagios/var/log/pnp4nagios/rrd/localhost               # RRD files appear here
sudo tail /var/log/apache2/error.log
```

- **Checks show "No such file" for `check_*`:** the plugins build failed. Run `cd /tmp/nagios-plugins-2.5 && sudo make 2>&1 | tail`.
- **PNP "perfdata directory does not exist":** perfdata is not reaching `npcd`. Check the `process-*-perfdata-file` commands in `objects/commands.cfg` point at `var/spool/pnp4nagios/`.

## Credits

- Theme: [Exfoliation](https://exchange.nagios.org/) by Matthew Wall (2010), with a dark mode added. The original copyright and permission notices are kept in each CSS file.
- [Nagios Core](https://github.com/NagiosEnterprises/nagioscore), [Nagios Plugins](https://github.com/nagios-plugins/nagios-plugins), [PNP4Nagios](https://github.com/pnp4nagios/pnp4nagios).
