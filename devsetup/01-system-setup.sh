#!/usr/bin/env bash
# One-time system setup for the nodekes_store Magento 2.4.9 dev environment (WSL2 / Ubuntu 24.04).
# Installs: PHP 8.5 (FPM) + Apache 2.4, MySQL 8.4 LTS, OpenSearch 3.x, Valkey 9, Composer.
# Run with: sudo bash setup/01-system-setup.sh
set -euo pipefail

DEV_USER="${SUDO_USER:-chris}"
DEV_HOME="$(getent passwd "$DEV_USER" | cut -d: -f6)"
PROJECT_DIR="$DEV_HOME/projects/nodekes_store"
SITE_HOST="nodekes.test"
PHP_V="8.5"
VALKEY_V="9.1.2"
VALKEY_SHA256="0d2a79936cbafa5f527a5175536bb17bd3f767f95f53529e59dddfacf762eec0"
DB_NAME="nodekes"
DB_USER="nodekes"
SECRETS_FILE="$DEV_HOME/.config/nodekes/secrets.env"

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- secrets
# Create as the dev user so parent dirs like ~/.config aren't left owned by root.
sudo -u "$DEV_USER" mkdir -p "$(dirname "$SECRETS_FILE")"
chmod 700 "$(dirname "$SECRETS_FILE")"
if [[ ! -f $SECRETS_FILE ]]; then
    cat > "$SECRETS_FILE" <<EOF
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
OPENSEARCH_INITIAL_ADMIN_PASSWORD=Os-$(openssl rand -hex 12)-A1!
EOF
    chown "$DEV_USER:$DEV_USER" "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

# ---------------------------------------------------------------- base + repos
log "Base packages and apt repositories"
# Write every key/source before the first `apt-get update`, so a stale key from a
# previous run can never block the script (curl, gpg and add-apt-repository ship with Ubuntu).
install -d -m 755 /etc/apt/keyrings

add-apt-repository -y -n ppa:ondrej/php

# The -2023 key file carries the old (expired Oct 2025) copy of key B7B3B788A8D3785C; -2025 has the extended expiry.
curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 | gpg --dearmor --yes -o /etc/apt/keyrings/mysql.gpg
echo "deb [signed-by=/etc/apt/keyrings/mysql.gpg] http://repo.mysql.com/apt/ubuntu noble mysql-8.4-lts mysql-tools" \
    > /etc/apt/sources.list.d/mysql.list

curl -fsSL https://artifacts.opensearch.org/publickeys/opensearch-release.pgp | gpg --dearmor --yes -o /etc/apt/keyrings/opensearch.gpg
echo "deb [signed-by=/etc/apt/keyrings/opensearch.gpg] https://artifacts.opensearch.org/releases/bundle/opensearch/3.x/apt stable main" \
    > /etc/apt/sources.list.d/opensearch-3.x.list

apt-get update
apt-get install -y ca-certificates gnupg lsb-release unzip git acl

# ---------------------------------------------------------------- PHP 8.5 + Apache
log "PHP $PHP_V (FPM + CLI) and Apache"
apt-get install -y apache2 \
    php$PHP_V-fpm php$PHP_V-cli php$PHP_V-bcmath php$PHP_V-curl php$PHP_V-gd php$PHP_V-intl \
    php$PHP_V-mbstring php$PHP_V-mysql php$PHP_V-soap php$PHP_V-xml php$PHP_V-xsl php$PHP_V-zip

cat > /etc/php/$PHP_V/mods-available/zz-magento.ini <<'EOF'
; Magento dev settings
memory_limit = 2G
max_execution_time = 1800
realpath_cache_size = 10M
realpath_cache_ttl = 7200
zlib.output_compression = Off
date.timezone = America/New_York
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 512
opcache.max_accelerated_files = 60000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 0
opcache.save_comments = 1
upload_max_filesize = 64M
post_max_size = 64M
EOF
phpenmod -v $PHP_V zz-magento
# CLI gets unlimited memory for setup:di:compile, static-content:deploy, etc.
echo "memory_limit = -1" > /etc/php/$PHP_V/cli/conf.d/99-magento-cli.ini

# FPM runs as the dev user so files written by Magento are owned by you (no permission juggling).
cat > /etc/php/$PHP_V/fpm/pool.d/www.conf <<EOF
[www]
user = $DEV_USER
group = $DEV_USER
listen = /run/php/php$PHP_V-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 20
pm.start_servers = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 6
EOF

# Apache (www-data) needs to traverse $DEV_HOME (mode 750) to serve static files from pub/.
usermod -aG "$DEV_USER" www-data

a2dismod -q mpm_prefork 2>/dev/null || true
a2dismod -q "php$PHP_V" 2>/dev/null || true
a2enmod -q mpm_event proxy_fcgi setenvif rewrite headers expires deflate
a2enconf -q php$PHP_V-fpm

cat > /etc/apache2/sites-available/$SITE_HOST.conf <<EOF
<VirtualHost *:80>
    ServerName $SITE_HOST
    DocumentRoot $PROJECT_DIR/pub

    <Directory $PROJECT_DIR/pub>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php$PHP_V-fpm.sock|fcgi://localhost"
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/$SITE_HOST-error.log
    CustomLog \${APACHE_LOG_DIR}/$SITE_HOST-access.log combined
</VirtualHost>
EOF
# Bind IPv4 explicitly: with the default dual-stack `Listen 80`, WSL's localhost relay only
# forwards [::1]:80 to Windows, so http://127.0.0.1 (and nodekes.test) fails from the browser.
sed -i 's/^Listen 80$/Listen 0.0.0.0:80/' /etc/apache2/ports.conf
a2dissite -q 000-default
a2ensite -q $SITE_HOST
grep -q "$SITE_HOST" /etc/hosts || echo "127.0.0.1 $SITE_HOST" >> /etc/hosts

# ---------------------------------------------------------------- Composer
log "Composer"
EXPECTED_SIG="$(curl -fsSL https://composer.github.io/installer.sig)"
php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
ACTUAL_SIG="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
[[ $EXPECTED_SIG == "$ACTUAL_SIG" ]] || { echo "Composer installer checksum mismatch" >&2; exit 1; }
php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
rm -f /tmp/composer-setup.php

# ---------------------------------------------------------------- MySQL 8.4
log "MySQL 8.4 LTS"
apt-get install -y mysql-server   # root authenticates via auth_socket (sudo mysql)
cat > /etc/mysql/mysql.conf.d/zz-magento.cnf <<'EOF'
[mysqld]
bind-address = 127.0.0.1
# Magento creates triggers (MView indexers); required when binary logging is on.
log_bin_trust_function_creators = 1
innodb_buffer_pool_size = 2G
max_allowed_packet = 64M
EOF
systemctl enable --now mysql
systemctl restart mysql
mysql <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# ---------------------------------------------------------------- OpenSearch 3
log "OpenSearch 3.x"
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-opensearch.conf
sysctl -q -w vm.max_map_count=262144
OPENSEARCH_INITIAL_ADMIN_PASSWORD="$OPENSEARCH_INITIAL_ADMIN_PASSWORD" apt-get install -y opensearch

cat > /etc/opensearch/opensearch.yml <<'EOF'
cluster.name: nodekes-dev
node.name: node-1
path.data: /var/lib/opensearch
path.logs: /var/log/opensearch
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node
# Local dev only: plain HTTP, no auth.
plugins.security.disabled: true
EOF
install -d /etc/opensearch/jvm.options.d
printf -- '-Xms2g\n-Xmx2g\n' > /etc/opensearch/jvm.options.d/heap.options
systemctl daemon-reload
systemctl enable --now opensearch

# ---------------------------------------------------------------- Valkey 9
log "Valkey $VALKEY_V"
cd /tmp
curl -fsSLO "https://download.valkey.io/releases/valkey-$VALKEY_V-noble-x86_64.tar.gz"
echo "$VALKEY_SHA256  valkey-$VALKEY_V-noble-x86_64.tar.gz" | sha256sum -c -
tar xzf "valkey-$VALKEY_V-noble-x86_64.tar.gz"
install -m 755 "valkey-$VALKEY_V-noble-x86_64"/bin/* /usr/local/bin/
rm -rf "valkey-$VALKEY_V-noble-x86_64" "valkey-$VALKEY_V-noble-x86_64.tar.gz"

id valkey &>/dev/null || useradd --system --home-dir /var/lib/valkey --shell /usr/sbin/nologin valkey
install -d -o valkey -g valkey -m 750 /var/lib/valkey /var/log/valkey
install -d -m 755 /etc/valkey
cat > /etc/valkey/valkey.conf <<'EOF'
bind 127.0.0.1 -::1
port 6379
protected-mode yes
daemonize no
dir /var/lib/valkey
logfile /var/log/valkey/valkey.log
maxmemory 1gb
maxmemory-policy allkeys-lru
# Cache/session data only; no need to persist to disk in dev.
save ""
appendonly no
EOF
cat > /etc/systemd/system/valkey.service <<'EOF'
[Unit]
Description=Valkey in-memory data store
After=network.target

[Service]
User=valkey
Group=valkey
ExecStart=/usr/local/bin/valkey-server /etc/valkey/valkey.conf
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now valkey

# ---------------------------------------------------------------- start web stack
log "Starting PHP-FPM and Apache"
systemctl enable --now php$PHP_V-fpm apache2
systemctl restart php$PHP_V-fpm apache2

log "Verification"
php -v | head -1
sudo -u "$DEV_USER" composer --version 2>/dev/null | head -1 || true
mysql --version
apache2 -v | head -1
/usr/local/bin/valkey-cli ping
for i in {1..30}; do curl -fs http://127.0.0.1:9200 >/dev/null && break; sleep 2; done
curl -fs http://127.0.0.1:9200 | grep -E '"number"|"distribution"' || echo "OpenSearch not responding yet (check: journalctl -u opensearch)"

log "Done. DB credentials are in $SECRETS_FILE"
