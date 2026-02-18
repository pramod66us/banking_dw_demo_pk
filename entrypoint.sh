#!/bin/bash
set -euo pipefail

###############################################################################
# Banking DW — Docker Entrypoint
# Initialises PostgreSQL, creates DB, loads DDL + data in correct order
###############################################################################

PG_VERSION="${PG_VERSION:-17}"
DB_NAME="${DB_NAME:-banking_dw}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-Password1001}"
PGDATA="/var/lib/postgresql/${PG_VERSION}/main"
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
INIT_DIR="/docker-entrypoint-initdb"
PG_LOG="/var/log/postgresql/postgresql-${PG_VERSION}-main.log"

# ── Colours for readable output ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
sep()  { echo -e "${BOLD}──────────────────────────────────────────────────────${RESET}"; }

sep
echo -e "${BOLD}  Global Banking Data Warehouse — PostgreSQL ${PG_VERSION}${RESET}"
echo -e "${BOLD}  One-Click Docker Setup${RESET}"
sep

# ── 1. Ensure log directory exists ────────────────────────────────────────────
mkdir -p /var/log/postgresql
chown postgres:postgres /var/log/postgresql

# ── 2. Initialise the PostgreSQL cluster if not already done ─────────────────
if [ ! -f "${PGDATA}/PG_VERSION" ]; then
    log "Initialising PostgreSQL ${PG_VERSION} cluster at ${PGDATA} ..."
    mkdir -p "${PGDATA}"
    chown -R postgres:postgres "${PGDATA}"
    chmod 700 "${PGDATA}"

    sudo -u postgres "${PG_BIN}/initdb" \
        --pgdata="${PGDATA}" \
        --auth-local=trust \
        --auth-host=scram-sha-256 \
        --encoding=UTF8 \
        --locale=en_US.UTF-8 \
        --username="${DB_USER}" \
        > /tmp/initdb.log 2>&1 || {
            cat /tmp/initdb.log
            err "initdb failed — see above"
        }
    ok "Cluster initialised"
else
    log "PostgreSQL cluster already initialised — skipping initdb"
fi

# ── 3. Configure postgresql.conf for performance ─────────────────────────────
PG_CONF="${PGDATA}/postgresql.conf"
PG_HBA="${PGDATA}/pg_hba.conf"

log "Tuning postgresql.conf ..."
cat >> "${PG_CONF}" << PGEOF

# ── Banking DW tuning (added by entrypoint) ───────────────────────────────────
listen_addresses = '*'
max_connections = 100
shared_buffers = 256MB
effective_cache_size = 768MB
maintenance_work_mem = 64MB
work_mem = 16MB
wal_buffers = 16MB
checkpoint_completion_target = 0.9
random_page_cost = 1.1
effective_io_concurrency = 200
default_statistics_target = 100
log_min_duration_statement = 5000
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
PGEOF
ok "postgresql.conf tuned"

# ── 4. Configure pg_hba.conf — allow password auth from anywhere ─────────────
log "Configuring pg_hba.conf ..."
cat > "${PG_HBA}" << HBAEOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
host    all             all             0.0.0.0/0               scram-sha-256
HBAEOF
ok "pg_hba.conf configured"

# ── 5. Start PostgreSQL ───────────────────────────────────────────────────────
log "Starting PostgreSQL ${PG_VERSION} ..."
sudo -u postgres "${PG_BIN}/pg_ctl" \
    -D "${PGDATA}" \
    -l "${PG_LOG}" \
    start

# Wait until PostgreSQL is ready to accept connections
for i in $(seq 1 30); do
    if sudo -u postgres "${PG_BIN}/pg_isready" -q; then
        ok "PostgreSQL is ready"
        break
    fi
    if [ "${i}" -eq 30 ]; then
        cat "${PG_LOG}" 2>/dev/null | tail -20
        err "PostgreSQL failed to start within 30 seconds"
    fi
    sleep 1
done

# ── 6. Set postgres password ─────────────────────────────────────────────────
log "Setting password for user '${DB_USER}' ..."
sudo -u postgres "${PG_BIN}/psql" -c \
    "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';" \
    > /dev/null 2>&1
ok "Password set"

# ── 7. Create the banking DW database ────────────────────────────────────────
log "Creating database '${DB_NAME}' ..."
DB_EXISTS=$(sudo -u postgres "${PG_BIN}/psql" -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';")

if [ "${DB_EXISTS}" != "1" ]; then
    sudo -u postgres "${PG_BIN}/psql" -c \
        "CREATE DATABASE ${DB_NAME}
             OWNER = ${DB_USER}
             ENCODING = 'UTF8'
             LC_COLLATE = 'en_US.UTF-8'
             LC_CTYPE = 'en_US.UTF-8'
             TEMPLATE = template0
             CONNECTION LIMIT = -1;" \
        > /dev/null 2>&1
    ok "Database '${DB_NAME}' created"
else
    warn "Database '${DB_NAME}' already exists — skipping create"
fi

# ── 8. Enable required extensions ────────────────────────────────────────────
log "Enabling PostgreSQL extensions ..."
sudo -u postgres "${PG_BIN}/psql" -d "${DB_NAME}" -c \
    "CREATE EXTENSION IF NOT EXISTS pgcrypto;
     CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" \
    > /dev/null 2>&1
ok "Extensions enabled"

# ── 9. Run initialisation SQL scripts in order ───────────────────────────────
sep
log "Loading Banking DW schema and data ..."
sep

run_sql() {
    local label="$1"
    local file="$2"
    local lines
    lines=$(wc -l < "${file}")

    log "▶ Running: ${label} (${lines} lines) ..."
    local start_time
    start_time=$(date +%s)

    # Run with error output captured; on failure print last 30 lines of psql output
    if sudo -u postgres "${PG_BIN}/psql" \
            --username="${DB_USER}" \
            --dbname="${DB_NAME}" \
            --set=ON_ERROR_STOP=1 \
            --set=client_min_messages=warning \
            --file="${file}" \
            > /tmp/psql_out.log 2>&1; then
        local end_time
        end_time=$(date +%s)
        ok "  ✓ ${label} loaded in $((end_time - start_time))s"
    else
        warn "  ✗ ${label} FAILED — last 40 lines:"
        tail -40 /tmp/psql_out.log >&2
        err "Aborting. Fix the SQL error above and rebuild the image."
    fi
}

# Script 01 — DDL: schemas, dimensions, facts, views
run_sql "01 — DDL (schemas, tables, indexes, views)" \
        "${INIT_DIR}/01_banking_dw_ddl.sql"

# Script 02 — Data: all INSERT statements
run_sql "02 — Seed data (dimensions + facts)" \
        "${INIT_DIR}/02_banking_dw_data.sql"

# Script 03 — Sequence reset (must run after explicit SK inserts)
run_sql "03 — Sequence reset (SERIAL auto-increment alignment)" \
        "${INIT_DIR}/03_sequences_reset.sql"

# ── 10. Verify load ───────────────────────────────────────────────────────────
sep
log "Verifying data load ..."

verify() {
    local table="$1"
    local expected="$2"
    local actual
    actual=$(sudo -u postgres "${PG_BIN}/psql" -d "${DB_NAME}" -tAc \
        "SELECT COUNT(*) FROM ${table};" 2>/dev/null || echo "ERROR")
    if [ "${actual}" = "ERROR" ]; then
        warn "  ⚠  ${table} — could not query"
    elif [ "${actual}" -ge "${expected}" ] 2>/dev/null; then
        ok "  ✓ ${table}: ${actual} rows"
    else
        warn "  ⚠  ${table}: ${actual} rows (expected ≥ ${expected})"
    fi
}

verify "banking_dw.dim_date"                   1000
verify "banking_dw.dim_geography"              25
verify "banking_dw.dim_currency"               10
verify "banking_dw.dim_branch"                 15
verify "banking_dw.dim_employee"               50
verify "banking_dw.dim_product"                15
verify "banking_dw.dim_customer"               400
verify "banking_dw.dim_account"                800
verify "banking_dw.dim_collateral"             100
verify "banking_dw.dim_gl_account"             25
verify "banking_dw.dim_aml_rule"               10
verify "banking_dw.bridge_account_customer"    800
verify "banking_dw.bridge_loan_collateral"     100
verify "banking_dw.fact_transaction"           10000
verify "banking_dw.fact_account_balance_daily" 10000
verify "banking_dw.fact_loan_daily_snapshot"   2000
verify "banking_dw.fact_payment_order"         1500
verify "banking_dw.fact_aml_alert"             200
verify "banking_dw.fact_gl_balance"            2000

# ── 11. Print connection summary ─────────────────────────────────────────────
sep
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║   Banking Data Warehouse — Ready!                    ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║   Host     : localhost (or your Docker host IP)      ║"
echo "  ║   Port     : 5432                                    ║"
printf "  ║   Database : %-38s║\n" "${DB_NAME}"
printf "  ║   Username : %-38s║\n" "${DB_USER}"
printf "  ║   Password : %-38s║\n" "${DB_PASSWORD}"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║   Schemas  : banking_dw  |  banking_ref              ║"
echo "  ║   Views    : vw_customer_360                         ║"
echo "  ║              vw_credit_risk_portfolio                ║"
echo "  ║              vw_financial_performance                ║"
echo "  ║              vw_aml_compliance_dashboard             ║"
echo "  ║              vw_payments_analytics                   ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║   psql quick connect:                                ║"
printf "  ║   psql -h localhost -U %s -d %s%-17s║\n" "${DB_USER}" "${DB_NAME}" ""
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
sep

# ── 12. Keep PostgreSQL running in foreground ─────────────────────────────────
log "PostgreSQL is running. Container will stay alive."
log "Press Ctrl+C to stop."
echo ""

# Trap SIGTERM/SIGINT for graceful shutdown
shutdown_postgres() {
    log "Shutting down PostgreSQL gracefully ..."
    sudo -u postgres "${PG_BIN}/pg_ctl" -D "${PGDATA}" stop -m fast
    ok "PostgreSQL stopped. Goodbye."
    exit 0
}
trap shutdown_postgres SIGTERM SIGINT

# Tail the PostgreSQL log so the container stays alive and logs are visible
tail -f "${PG_LOG}" &
TAIL_PID=$!

# Wait for PostgreSQL process
while sudo -u postgres "${PG_BIN}/pg_isready" -q; do
    sleep 5
done

# If pg_isready fails, PostgreSQL stopped unexpectedly
kill "${TAIL_PID}" 2>/dev/null || true
err "PostgreSQL stopped unexpectedly. Check logs above."
