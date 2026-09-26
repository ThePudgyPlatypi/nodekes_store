#!/usr/bin/env bash
# Magento application setup for web_store. Run as your normal user (NOT sudo),
# after 01-system-setup.sh. Safe to re-run:
#   - fresh checkout  -> composer install + setup:install
#   - existing install -> composer install + setup:upgrade (use this for deploys)
#
# Per-environment settings are env vars; defaults are for local dev:
#   SITE_URL=https://staging.example.com/ MAGE_MODE=production ADMIN_FRONTNAME=backend_x7k2 \
#     bash devsetup/02-magento-setup.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="$HOME/.config/web_store/secrets.env"

SITE_URL="${SITE_URL:-http://web-store.test/}"
MAGE_MODE="${MAGE_MODE:-developer}"               # developer | production
ADMIN_FRONTNAME="${ADMIN_FRONTNAME:-admin}"        # dev only - use an obscure name on staging/prod
ADMIN_EMAIL="${ADMIN_EMAIL:-cstehm@chrisstehm.com}"
ADMIN_FIRSTNAME="${ADMIN_FIRSTNAME:-Chris}"
ADMIN_LASTNAME="${ADMIN_LASTNAME:-Stehm}"
TIMEZONE="${TIMEZONE:-America/New_York}"

[[ $EUID -ne 0 ]] || { echo "Run as your normal user, not root/sudo." >&2; exit 1; }
[[ -f $SECRETS_FILE ]] || { echo "Missing $SECRETS_FILE - run 01-system-setup.sh first." >&2; exit 1; }
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
cd "$PROJECT_DIR"

# ---------------------------------------------------------------- composer auth
if ! composer config -g http-basic.repo.magento.com >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Composer has no repo.magento.com keys. Get them from commercemarketplace.adobe.com
(My Profile -> Access Keys), then run:
    composer config -g http-basic.repo.magento.com <public-key> <private-key>
EOF
    exit 1
fi

# ---------------------------------------------------------------- secrets
# Anchored match: OPENSEARCH_INITIAL_ADMIN_PASSWORD also contains "ADMIN_PASS".
if ! grep -q '^ADMIN_PASS=' "$SECRETS_FILE"; then
    printf 'ADMIN_USER=admin\nADMIN_PASS=Adm1n-%s\n' "$(openssl rand -hex 8)" >> "$SECRETS_FILE"
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

# ---------------------------------------------------------------- code
log "composer install"
composer install --no-interaction

# ---------------------------------------------------------------- install / upgrade
if [[ -f app/etc/env.php ]]; then
    log "Existing install found - running setup:upgrade"
    php bin/magento setup:upgrade --keep-generated --no-interaction
else
    log "Fresh install - running setup:install"
    php bin/magento setup:install \
        --base-url="$SITE_URL" \
        --db-host=127.0.0.1 --db-name="$DB_NAME" --db-user="$DB_USER" --db-password="$DB_PASS" \
        --admin-firstname="$ADMIN_FIRSTNAME" --admin-lastname="$ADMIN_LASTNAME" --admin-email="$ADMIN_EMAIL" \
        --admin-user="$ADMIN_USER" --admin-password="$ADMIN_PASS" --backend-frontname="$ADMIN_FRONTNAME" \
        --language=en_US --currency=USD --timezone="$TIMEZONE" --use-rewrites=1 \
        --search-engine=opensearch --opensearch-host=127.0.0.1 --opensearch-port=9200 --opensearch-index-prefix=web_store \
        --cache-backend=valkey --cache-backend-valkey-server=127.0.0.1 --cache-backend-valkey-port=6379 --cache-backend-valkey-db=0 \
        --page-cache=valkey --page-cache-valkey-server=127.0.0.1 --page-cache-valkey-port=6379 --page-cache-valkey-db=1 \
        --no-interaction
fi

# ---------------------------------------------------------------- per-environment config
log "Environment config"
php bin/magento setup:config:set --backend-frontname="$ADMIN_FRONTNAME" --no-interaction >/dev/null
# Sessions -> Valkey db2 via the *redis* handler. 2.4.9's installer accepts --session-save=valkey,
# but no framework handler is registered for it, so it silently falls back to PHP file sessions.
# Valkey is Redis-protocol compatible, so the redis handler works. (Set here so upgrades get it too.)
php bin/magento setup:config:set --session-save=redis --session-save-redis-host=127.0.0.1 \
    --session-save-redis-port=6379 --session-save-redis-db=2 --no-interaction >/dev/null
php bin/magento deploy:mode:set "$MAGE_MODE"
php bin/magento cron:install --force
php bin/magento cache:flush

log "Done"
php bin/magento info:adminuri
echo "Store: $SITE_URL   Admin user: $ADMIN_USER   (password: grep ADMIN_PASS $SECRETS_FILE)"
