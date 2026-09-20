#!/usr/bin/env bash
# One-time setup of a production Frappe bench for the rmg app on a fresh
# Ubuntu 22.04 server, mirroring the local bench (Python 3.14 via uv, Node 24,
# MariaDB 10.6, Redis 6, wkhtmltopdf 0.12.6.1), then restores the local site.
#
# Usage (on the server, as the sudo-capable admin user):
#   DOMAIN=rmg-demo.centralindia.cloudapp.azure.com BACKUP_DIR=~/backup bash setup_server.sh
# Safe to re-run: finished steps are skipped.
set -euo pipefail

DOMAIN=${DOMAIN:?set DOMAIN to the server DNS name}
BACKUP_DIR=${BACKUP_DIR:-$HOME/backup}
BENCH=$HOME/frappe-bench
RMG_REPO=https://github.com/Trisheetaazad/rmg-bench-app.git

# App commits matching the local bench (git ls-files -s apps)
declare -A PIN=(
	[frappe]=e929fc3c5dafc4d10e5d90ae78f5bc48f32fa1f5
	[erpnext]=e1f6bb70bc2ddffc923ac6430b79d2ecea422a7a
	[hrms]=6ae67c2a0e5927155c3e48767709feb83d21c4b6
	[payments]=07ea0798f95e8d754bc2f7019708a68a71ebead3
)

export PATH=$HOME/.local/bin:$PATH
export DEBIAN_FRONTEND=noninteractive
step() { printf '\n===== %s =====\n' "$*"; }

step "Swap (4 GB) so asset builds fit in 4 GB RAM"
if ! swapon --show | grep -q /swapfile; then
	sudo fallocate -l 4G /swapfile
	sudo chmod 600 /swapfile
	sudo mkswap /swapfile
	sudo swapon /swapfile
	echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab
fi

step "System packages"
sudo apt-get update -q
# ansible + fail2ban preinstalled so `bench setup production` doesn't pip-install them
sudo -E apt-get install -yq git curl build-essential pkg-config openssl \
	mariadb-server mariadb-client libmariadb-dev redis-server \
	nginx supervisor cron pipx ansible fail2ban certbot python3-certbot-nginx \
	fontconfig libxrender1 libxext6 xfonts-75dpi xfonts-base libjpeg-turbo8

step "wkhtmltopdf 0.12.6.1 (patched qt) for PDF printing"
if ! command -v wkhtmltopdf >/dev/null; then
	curl -fsSL -o /tmp/wkhtmltox.deb \
		https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb \
		&& sudo -E apt-get install -yq /tmp/wkhtmltox.deb \
		|| echo "WARNING: wkhtmltopdf install failed - only PDF printing is affected"
fi

step "Node 24 + yarn"
if ! node --version 2>/dev/null | grep -q '^v24'; then
	curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
	sudo -E apt-get install -yq nodejs
fi
command -v yarn >/dev/null || sudo npm install -g yarn

step "uv, Python 3.14, bench CLI"
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
uv python install 3.14
PY314=$(uv python find 3.14)
command -v bench >/dev/null || pipx install frappe-bench

step "MariaDB (utf8mb4) + root password"
sudo tee /etc/mysql/mariadb.conf.d/99-frappe.cnf >/dev/null <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
innodb_buffer_pool_size = 256M

[mysql]
default-character-set = utf8mb4
EOF
sudo systemctl restart mariadb
DB_PW_FILE=$HOME/.mariadb_root_password
if [ ! -s "$DB_PW_FILE" ]; then
	(umask 077; openssl rand -base64 24 | tr -d '/+=' > "$DB_PW_FILE")
	sudo mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$(cat "$DB_PW_FILE")'; FLUSH PRIVILEGES;"
fi
DB_PW=$(cat "$DB_PW_FILE")

step "bench init + apps pinned to the local commits"
[ -d "$BENCH" ] || bench init "$BENCH" --frappe-branch develop --python "$PY314" --skip-assets
cd "$BENCH"
pin() { git -C "apps/$1" fetch -q --depth 1 origin "${PIN[$1]}" && git -C "apps/$1" checkout -q "${PIN[$1]}"; }
pin frappe
for app in erpnext hrms payments; do
	[ -d "apps/$app" ] || bench get-app --branch develop --skip-assets "$app"
	pin "$app"
done
# Repo name (rmg-bench-app) differs from the app name, so clone straight into apps/rmg
[ -d apps/rmg ] || git clone -q --branch main "$RMG_REPO" apps/rmg
if ! grep -qx rmg sites/apps.txt; then
	{ cat sites/apps.txt; echo; echo rmg; } | grep -v '^$' > sites/apps.txt.new
	mv sites/apps.txt.new sites/apps.txt
fi

step "Requirements for the pinned code + asset build"
bench setup requirements
bench build

step "Site $DOMAIN restored from the local backup"
if [ ! -d "sites/$DOMAIN" ]; then
	DB_FILE=$(ls -t "$BACKUP_DIR"/*-database.sql.gz | head -1)
	PUB_FILE=$(ls -t "$BACKUP_DIR"/*-files.tar | grep -v private-files | head -1)
	PRIV_FILE=$(ls -t "$BACKUP_DIR"/*-private-files.tar | head -1)
	# Temporary admin password; the restore brings back the local Administrator password
	bench new-site "$DOMAIN" --db-root-password "$DB_PW" --admin-password "$(openssl rand -hex 12)"
	bench --site "$DOMAIN" restore "$DB_FILE" \
		--with-public-files "$PUB_FILE" --with-private-files "$PRIV_FILE" --db-root-password "$DB_PW"
	bench --site "$DOMAIN" migrate
fi
bench use "$DOMAIN"
bench --site "$DOMAIN" set-config host_name "https://$DOMAIN"
bench --site "$DOMAIN" enable-scheduler

step "Production: nginx + supervisor"
chmod o+x "$HOME"   # nginx must be able to reach the bench's static assets
sudo env PATH="$PATH" "$(command -v bench)" setup production "$USER" --yes

step "HTTPS certificate (Let's Encrypt)"
sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect \
	|| echo "WARNING: certbot failed - site is still reachable at http://$DOMAIN"

step "Done"
echo "Site: https://$DOMAIN"
echo "MariaDB root password: $DB_PW_FILE"
