#!/bin/bash
set -euo pipefail

###############################################################################
#  install_banking_dw.sh
#  Ubuntu Server — One-Click Banking Data Warehouse Installer
#
#  What this script does:
#   1. Removes ALL existing PostgreSQL installations cleanly
#   2. Installs latest stable PostgreSQL (17) from official pgdg repo
#   3. Creates user 'postgres' with password 'Password1001'
#   4. Creates database 'banking_dw' with UTF-8 encoding
#   5. Loads the full Banking DW schema (DDL)
#   6. Loads all synthesised seed data
#   7. Resets sequences for safe future inserts
#   8. Verifies row counts
#
#  Usage:
#   chmod +x install_banking_dw.sh
#   sudo bash install_banking_dw.sh
#
#  Requirements: Ubuntu 20.04 / 22.04 / 24.04 LTS  |  Root / sudo access
#  Tested on: Ubuntu 22.04 LTS, Ubuntu 24.04 LTS
###############################################################################

# ── Configuration — change these if needed ───────────────────────────────────
PG_VERSION="17"
DB_NAME="banking_dw"
DB_USER="postgres"
DB_PASSWORD="Password1001"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/sql"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "\n${CYAN}[$(date '+%H:%M:%S')] INFO${RESET}  $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')]   OK${RESET}  $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN${RESET}  $*"; }
err()  { echo -e "\n${RED}[$(date '+%H:%M:%S')] ERROR${RESET} $*\n" >&2; exit 1; }
sep()  { echo -e "\n${BOLD}══════════════════════════════════════════════════════${RESET}"; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
sep
echo -e "${BOLD}  Global Banking Data Warehouse — Ubuntu Installer${RESET}"
echo -e "${BOLD}  PostgreSQL ${PG_VERSION} | Database: ${DB_NAME}${RESET}"
sep

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root. Use: sudo bash install_banking_dw.sh"
fi

# Check Ubuntu
if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    warn "This script is designed for Ubuntu. Proceeding anyway — may need adjustments."
fi

# Check SQL files exist
for f in "01_banking_dw_ddl.sql" "02_banking_dw_data.sql" "03_sequences_reset.sql"; do
    if [ ! -f "${SQL_DIR}/${f}" ]; then
        err "Required SQL file not found: ${SQL_DIR}/${f}\nEnsure all files are in the 'sql/' subdirectory next to this script."
    fi
done
ok "All SQL files found in ${SQL_DIR}"

# ── STEP 1: Remove all existing PostgreSQL installations ─────────────────────
sep
log "STEP 1 — Removing all existing PostgreSQL installations ..."

# Stop any running PostgreSQL services
log "  Stopping all PostgreSQL services ..."
systemctl list-units --type=service --state=running 2>/dev/null \
    | grep -oP 'postgresql[^\s]+' \
    | xargs -r systemctl stop 2>/dev/null || true
systemctl stop postgresql 2>/dev/null || true

# Kill any lingering postgres processes
pkill -u postgres 2>/dev/null || true
sleep 2

# Remove all postgresql packages
log "  Purging postgresql packages ..."
INSTALLED_PG=$(dpkg --list 2>/dev/null | grep -oP 'postgresql[-\d]*' | sort -u | tr '\n' ' ')
if [ -n "${INSTALLED_PG}" ]; then
    log "  Found: ${INSTALLED_PG}"
    # shellcheck disable=SC2086
    apt-get purge -y --auto-remove ${INSTALLED_PG} 2>/dev/null || true
    ok "  Purged: ${INSTALLED_PG}"
else
    log "  No existing PostgreSQL packages found"
fi

# Remove leftover data directories and config
log "  Removing leftover data directories ..."
rm -rf /var/lib/postgresql 2>/dev/null || true
rm -rf /etc/postgresql 2>/dev/null || true
rm -rf /var/log/postgresql 2>/dev/null || true
rm -rf /tmp/.s.PGSQL* 2>/dev/null || true

# Remove stale pgdg repo list (will be recreated below)
rm -f /etc/apt/sources.list.d/pgdg.list 2>/dev/null || true

ok "STEP 1 complete — all PostgreSQL installations removed"

# ── STEP 2: Install latest stable PostgreSQL ──────────────────────────────────
sep
log "STEP 2 — Installing PostgreSQL ${PG_VERSION} from official pgdg repository ..."

# Install prerequisites
log "  Installing prerequisites ..."
apt-get update -y -q
apt-get install -y -q --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    sudo

# Add pgdg APT repository
log "  Adding PostgreSQL APT repository ..."
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

UBUNTU_CODENAME=$(lsb_release -cs)
echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
    https://apt.postgresql.org/pub/repos/apt \
    ${UBUNTU_CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list

apt-get update -y -q

# Install PostgreSQL
log "  Installing PostgreSQL ${PG_VERSION} ..."
apt-get install -y -q \
    postgresql-${PG_VERSION} \
    postgresql-client-${PG_VERSION} \
    postgresql-contrib-${PG_VERSION}

ok "STEP 2 complete — PostgreSQL ${PG_VERSION} installed"

# Verify installation
PG_ACTUAL=$("${PG_BIN:=/usr/lib/postgresql/${PG_VERSION}/bin}/postgres" --version 2>/dev/null || true)
log "  Installed: ${PG_ACTUAL}"

# ── STEP 3: Configure PostgreSQL ──────────────────────────────────────────────
sep
log "STEP 3 — Configuring PostgreSQL ..."

PGDATA="/var/lib/postgresql/${PG_VERSION}/main"
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
PG_CONF="${PGDATA}/postgresql.conf"
PG_HBA="${PGDATA}/pg_hba.conf"
PG_LOG="/var/log/postgresql/install.log"

# Create log directory
mkdir -p /var/log/postgresql
chown postgres:postgres /var/log/postgresql

# Ensure cluster is initialised (pg_createcluster should have done this)
if [ ! -f "${PG_CONF}" ]; then
    log "  Re-initialising cluster ..."
    pg_createcluster ${PG_VERSION} main --start || true
fi

# Configure postgresql.conf
log "  Tuning postgresql.conf ..."
cat >> "${PG_CONF}" << PGEOF

# ── Banking DW tuning (added by install_banking_dw.sh) ───────────────────────
listen_addresses = '*'
max_connections = 200
shared_buffers = 512MB
effective_cache_size = 1536MB
maintenance_work_mem = 128MB
work_mem = 32MB
wal_buffers = 16MB
checkpoint_completion_target = 0.9
random_page_cost = 1.1
effective_io_concurrency = 200
default_statistics_target = 100
log_min_duration_statement = 5000
log_line_prefix = '%t [%p]: user=%u,db=%d,app=%a '
PGEOF

# Configure pg_hba.conf to allow password auth from anywhere
log "  Configuring pg_hba.conf ..."
cat > "${PG_HBA}" << HBAEOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
host    all             all             0.0.0.0/0               scram-sha-256
HBAEOF

ok "STEP 3 complete — PostgreSQL configured"

# ── STEP 4: Start PostgreSQL service ──────────────────────────────────────────
sep
log "STEP 4 — Starting PostgreSQL service ..."

systemctl daemon-reload
systemctl enable postgresql 2>/dev/null || true
systemctl restart postgresql

# Wait for ready
for i in $(seq 1 30); do
    if sudo -u postgres "${PG_BIN}/pg_isready" -q 2>/dev/null; then
        ok "PostgreSQL is ready (took ${i}s)"
        break
    fi
    if [ "${i}" -eq 30 ]; then
        err "PostgreSQL did not become ready within 30 seconds. Check: journalctl -xe"
    fi
    sleep 1
done

# ── STEP 5: Set up user and database ──────────────────────────────────────────
sep
log "STEP 5 — Creating user, database, and extensions ..."

# Set postgres password
log "  Setting password for postgres user ..."
sudo -u postgres "${PG_BIN}/psql" -c \
    "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';" \
    > /dev/null

# Create database
log "  Creating database '${DB_NAME}' ..."
DB_EXISTS=$(sudo -u postgres "${PG_BIN}/psql" -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';" 2>/dev/null)

if [ "${DB_EXISTS}" != "1" ]; then
    sudo -u postgres "${PG_BIN}/psql" << SQLEOF
CREATE DATABASE ${DB_NAME}
    OWNER = ${DB_USER}
    ENCODING = 'UTF8'
    LC_COLLATE = 'en_US.UTF-8'
    LC_CTYPE = 'en_US.UTF-8'
    TEMPLATE = template0
    CONNECTION LIMIT = -1;
COMMENT ON DATABASE ${DB_NAME} IS 'Global Banking Data Warehouse — Kimball Dimensional Model';
SQLEOF
    ok "  Database '${DB_NAME}' created"
else
    warn "  Database '${DB_NAME}' already exists"
fi

# Enable extensions
log "  Enabling extensions ..."
sudo -u postgres "${PG_BIN}/psql" -d "${DB_NAME}" << SQLEOF
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQLEOF
ok "STEP 5 complete"

# ── Helper: run a SQL file with timing and error handling ─────────────────────
run_sql() {
    local label="$1"
    local file="$2"
    local start end elapsed lines

    lines=$(wc -l < "${file}")
    log "  ▶ ${label} (${lines} lines) ..."
    start=$(date +%s)

    if sudo -u postgres "${PG_BIN}/psql" \
            --username="${DB_USER}" \
            --dbname="${DB_NAME}" \
            --set=ON_ERROR_STOP=1 \
            --set=client_min_messages=warning \
            --file="${file}" \
            >> "${PG_LOG}" 2>&1; then
        end=$(date +%s)
        elapsed=$((end - start))
        ok "  ✓ ${label} — done in ${elapsed}s"
    else
        warn "  ✗ ${label} FAILED. Last 50 lines of log:"
        echo "──────────────────────────────────────────"
        tail -50 "${PG_LOG}" >&2
        echo "──────────────────────────────────────────"
        err "SQL load failed at: ${label}\nLog file: ${PG_LOG}\nFix the error and re-run the script."
    fi
}

# ── STEP 6: Load DDL ──────────────────────────────────────────────────────────
sep
log "STEP 6 — Loading Banking DW schema (DDL) ..."
run_sql "01 — DDL: schemas, dimensions, facts, views" \
        "${SQL_DIR}/01_banking_dw_ddl.sql"

# ── STEP 7: Load seed data ────────────────────────────────────────────────────
sep
log "STEP 7 — Loading synthesised seed data (~11 MB, may take 1-3 minutes) ..."
run_sql "02 — Seed data: dimensions + facts" \
        "${SQL_DIR}/02_banking_dw_data.sql"

# ── STEP 8: Reset sequences ───────────────────────────────────────────────────
sep
log "STEP 8 — Resetting SERIAL sequences ..."
run_sql "03 — Sequence reset" \
        "${SQL_DIR}/03_sequences_reset.sql"

# ── STEP 9: ANALYZE for query planner ────────────────────────────────────────
sep
log "STEP 9 — Running ANALYZE to update query planner statistics ..."
sudo -u postgres "${PG_BIN}/psql" -d "${DB_NAME}" \
    -c "ANALYZE;" >> "${PG_LOG}" 2>&1
ok "ANALYZE complete"

# ── STEP 10: Verify row counts ────────────────────────────────────────────────
sep
log "STEP 10 — Verifying data load ..."

psql_count() {
    sudo -u postgres "${PG_BIN}/psql" -d "${DB_NAME}" -tAc \
        "SELECT COUNT(*) FROM $1;" 2>/dev/null || echo "ERROR"
}

declare -A EXPECTED=(
    ["banking_dw.dim_date"]=1000
    ["banking_dw.dim_geography"]=25
    ["banking_dw.dim_currency"]=10
    ["banking_dw.dim_branch"]=15
    ["banking_dw.dim_employee"]=50
    ["banking_dw.dim_product"]=15
    ["banking_dw.dim_customer"]=400
    ["banking_dw.dim_account"]=800
    ["banking_dw.dim_collateral"]=100
    ["banking_dw.dim_gl_account"]=25
    ["banking_dw.dim_aml_rule"]=10
    ["banking_dw.bridge_account_customer"]=800
    ["banking_dw.bridge_loan_collateral"]=100
    ["banking_dw.fact_transaction"]=10000
    ["banking_dw.fact_account_balance_daily"]=10000
    ["banking_dw.fact_loan_daily_snapshot"]=2000
    ["banking_dw.fact_payment_order"]=1500
    ["banking_dw.fact_aml_alert"]=200
    ["banking_dw.fact_gl_balance"]=2000
)

ALL_OK=true
for table in "${!EXPECTED[@]}"; do
    actual=$(psql_count "${table}")
    expected="${EXPECTED[$table]}"
    if [ "${actual}" = "ERROR" ]; then
        warn "  ⚠ ${table}: QUERY ERROR"
        ALL_OK=false
    elif [ "${actual}" -ge "${expected}" ] 2>/dev/null; then
        printf "  ${GREEN}✓${RESET} %-45s %s rows\n" "${table}" "${actual}"
    else
        warn "  ⚠ ${table}: ${actual} rows (expected ≥ ${expected})"
    fi
done

if [ "${ALL_OK}" = "true" ]; then
    ok "STEP 10 complete — all tables verified"
else
    warn "Some tables have unexpected counts — check logs at: ${PG_LOG}"
fi

# ── Configure firewall (optional) ─────────────────────────────────────────────
if command -v ufw &>/dev/null; then
    UFW_STATUS=$(ufw status 2>/dev/null | head -1)
    if [[ "${UFW_STATUS}" == *"active"* ]]; then
        log "UFW is active — allowing port 5432 ..."
        ufw allow 5432/tcp comment "PostgreSQL Banking DW" >> /dev/null 2>&1
        ok "UFW rule added for port 5432"
    fi
fi

# ── Write .pgpass for passwordless psql ───────────────────────────────────────
PGPASS_FILE="/root/.pgpass"
echo "localhost:5432:${DB_NAME}:${DB_USER}:${DB_PASSWORD}" > "${PGPASS_FILE}"
chmod 600 "${PGPASS_FILE}"
ok ".pgpass configured at ${PGPASS_FILE}"

# ── Final summary ─────────────────────────────────────────────────────────────
sep
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║   Banking Data Warehouse — Installation Complete! ✓     ║"
echo "  ╠══════════════════════════════════════════════════════════╣"
printf "  ║   PostgreSQL Version : %-35s║\n" "${PG_VERSION}"
printf "  ║   Host               : %-35s║\n" "$(hostname -I | awk '{print $1}') (server IP)"
echo "  ║   Port               : 5432                             ║"
printf "  ║   Database           : %-35s║\n" "${DB_NAME}"
printf "  ║   Username           : %-35s║\n" "${DB_USER}"
printf "  ║   Password           : %-35s║\n" "${DB_PASSWORD}"
echo "  ╠══════════════════════════════════════════════════════════╣"
echo "  ║   Schemas loaded     : banking_dw  |  banking_ref        ║"
echo "  ╠══════════════════════════════════════════════════════════╣"
echo "  ║   Quick connect:                                         ║"
printf "  ║   psql -h localhost -U %s -d %-22s║\n" "${DB_USER}" "${DB_NAME}"
echo "  ╠══════════════════════════════════════════════════════════╣"
echo "  ║   Try a mart view:                                       ║"
echo "  ║   SELECT * FROM banking_dw.vw_customer_360 LIMIT 10;    ║"
echo "  ╠══════════════════════════════════════════════════════════╣"
printf "  ║   Install log        : %-35s║\n" "${PG_LOG}"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# Print connection string for BI tools / OpenMetadata
echo -e "${BOLD}Connection string (JDBC):${RESET}"
echo "  jdbc:postgresql://localhost:5432/${DB_NAME}"
echo ""
echo -e "${BOLD}Connection string (psycopg2 / SQLAlchemy):${RESET}"
echo "  postgresql://${DB_USER}:${DB_PASSWORD}@localhost:5432/${DB_NAME}"
echo ""
