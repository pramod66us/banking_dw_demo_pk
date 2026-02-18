# Global Banking Data Warehouse — Docker & Ubuntu Deployment

## What's in this package

```
docker-banking-dw/
├── Dockerfile                 # Ubuntu 24.04 + PostgreSQL 17 image
├── docker-compose.yml         # One-click: includes pgAdmin 4 UI
├── entrypoint.sh              # Container init + data load script
├── pgadmin_servers.json       # Auto-connects pgAdmin to the DW
├── install_banking_dw.sh      # Bare-metal Ubuntu installer
└── sql/
    ├── 01_banking_dw_ddl.sql  # Schema: schemas, tables, indexes, views
    ├── 02_banking_dw_data.sql # Seed data: ~57,000 rows across 19 tables
    └── 03_sequences_reset.sql # Fixes SERIAL sequences after bulk insert
```

---

## Option A — Docker (Recommended)

### Prerequisites
- Docker Engine 20.10+
- Docker Compose v2.0+

### One-click start

```bash
# 1. Clone / copy this folder to your server
# 2. Run:
docker compose up --build
```

That's it. The container will:
1. Install PostgreSQL 17 on Ubuntu 24.04
2. Create database `banking_dw` with user `postgres` / `Password1001`
3. Load all DDL (schemas, dimensions, facts, views)
4. Load ~57,000 rows of synthesised banking data
5. Reset all SERIAL sequences
6. Stay running with PostgreSQL in the foreground

**First build takes ~2–5 minutes** (downloads Ubuntu + PostgreSQL).
Subsequent starts (no rebuild) take ~60 seconds to load data.

### Access

| Service | URL / Address |
|---------|---------------|
| PostgreSQL | `localhost:5432` |
| pgAdmin 4 | `http://localhost:8080` |
| pgAdmin login | `admin@bankingdw.local` / `Password1001` |

pgAdmin will auto-connect to the database — no manual server setup needed.

### Stop / Start

```bash
# Stop (data is persisted in Docker volumes)
docker compose down

# Start again (data already loaded — fast)
docker compose up

# Full rebuild from scratch
docker compose down -v   # removes volumes
docker compose up --build
```

### Connect with psql

```bash
# From your host machine (Docker Desktop or port mapping)
psql -h localhost -U postgres -d banking_dw
# Password: Password1001

# Inside the container
docker exec -it banking-dw-postgres bash
psql -U postgres -d banking_dw
```

### Connect from external tools (DBeaver, DataGrip, OpenMetadata)

| Parameter | Value |
|-----------|-------|
| Host | `<your-server-ip>` or `localhost` |
| Port | `5432` |
| Database | `banking_dw` |
| Username | `postgres` |
| Password | `Password1001` |
| SSL Mode | `prefer` |

**JDBC URL:**
```
jdbc:postgresql://localhost:5432/banking_dw
```

**SQLAlchemy / psycopg2:**
```
postgresql://postgres:Password1001@localhost:5432/banking_dw
```

---

## Option B — Ubuntu Bare-Metal (No Docker)

Use this when you want PostgreSQL installed directly on an Ubuntu server (no containers).

### What the script does
1. **Removes** all existing PostgreSQL packages, data directories, and config files cleanly
2. **Installs** PostgreSQL 17 from the official PostgreSQL APT repository
3. **Configures** `postgresql.conf` with DW-optimised settings
4. **Configures** `pg_hba.conf` for password auth from any host
5. **Creates** database `banking_dw` with UTF-8 encoding
6. **Loads** DDL + seed data + resets sequences
7. **Runs** ANALYZE for query planner
8. **Configures** UFW firewall rule (if active)
9. **Prints** connection details

### Requirements
- Ubuntu 20.04 / 22.04 / 24.04 LTS
- Root / sudo access
- Internet access (to download PostgreSQL from apt.postgresql.org)
- ~2 GB free disk space

### Run

```bash
# 1. Copy the entire docker-banking-dw folder to your Ubuntu server
# 2. Make scripts executable
chmod +x install_banking_dw.sh entrypoint.sh

# 3. Run as root
sudo bash install_banking_dw.sh
```

### Customise credentials (optional)

Edit the variables at the top of `install_banking_dw.sh`:

```bash
PG_VERSION="17"          # Change to 16 or 15 if needed
DB_NAME="banking_dw"     # Database name
DB_USER="postgres"       # Superuser
DB_PASSWORD="Password1001"
```

---

## Database Schema Summary

### Schemas

| Schema | Purpose |
|--------|---------|
| `banking_ref` | Reference / lookup tables (country, currency, FX rates) |
| `banking_dw` | Dimensional model (dimensions, facts, bridges, views) |

### Dimensions

| Table | Type | Grain | Rows |
|-------|------|-------|------|
| `dim_date` | Conformed | Per calendar day | 1,096 |
| `dim_geography` | Conformed SCD2 | Country version | 30 |
| `dim_currency` | Conformed SCD1 | Currency | 12 |
| `dim_customer` | Conformed SCD2 | Customer version | 500 |
| `dim_account` | Conformed SCD2 | Account version | ~1,200 |
| `dim_product` | Conformed SCD1 | Product | 18 |
| `dim_branch` | Conformed SCD2 | Branch version | 20 |
| `dim_employee` | Conformed SCD2 | Employee version | 60 |
| `dim_gl_account` | Subject SCD1 | GL CoA account | 33 |
| `dim_collateral` | Subject SCD2 | Collateral version | 120 |
| `dim_aml_rule` | Subject SCD1 | AML rule/model | 12 |

### Fact Tables

| Table | Type | Grain | Rows |
|-------|------|-------|------|
| `fact_transaction` | Transactional | Per transaction | 15,000 |
| `fact_account_balance_daily` | Periodic Snapshot | Per account × month | ~28,700 |
| `fact_loan_daily_snapshot` | Periodic Snapshot | Per loan × month | ~3,700 |
| `fact_payment_order` | Transactional | Per payment | 2,000 |
| `fact_aml_alert` | Accumulating Snapshot | Per alert | 300 |
| `fact_gl_balance` | Periodic Snapshot | Per GL × period | ~4,000 |

> `fact_transaction` is range-partitioned by year: `_2023`, `_2024`, `_2025`

### Mart Views (ready to query)

```sql
SELECT * FROM banking_dw.vw_customer_360 LIMIT 20;
SELECT * FROM banking_dw.vw_credit_risk_portfolio WHERE snapshot_date = '2024-12-31';
SELECT * FROM banking_dw.vw_financial_performance WHERE calendar_year = 2024;
SELECT * FROM banking_dw.vw_aml_compliance_dashboard WHERE alert_severity = 'HIGH';
SELECT * FROM banking_dw.vw_payments_analytics ORDER BY total_volume_usd DESC;
```

---

## Sample Governance Queries (OpenMetadata Demo)

### DQ: Referential Integrity
```sql
SELECT COUNT(*) AS orphan_transactions
FROM banking_dw.fact_transaction t
LEFT JOIN banking_dw.dim_account a ON a.account_sk = t.account_sk
WHERE a.account_sk IS NULL;
-- Expected: 0
```

### DQ: Uniqueness
```sql
SELECT customer_nk, COUNT(*) AS cnt
FROM banking_dw.dim_customer
WHERE is_current_record = TRUE
GROUP BY customer_nk HAVING COUNT(*) > 1;
-- Expected: 0 rows
```

### IFRS 9 Portfolio
```sql
SELECT ifrs9_stage, dpd_bucket,
    COUNT(*) AS loans,
    SUM(total_outstanding_rcy) AS exposure_usd,
    ROUND(AVG(ecl_pd)::numeric, 4) AS avg_pd
FROM banking_dw.fact_loan_daily_snapshot l
JOIN banking_dw.dim_date d ON d.date_sk = l.snapshot_date_sk
WHERE d.full_date = '2024-12-31'
GROUP BY ifrs9_stage, dpd_bucket ORDER BY 1, 2;
```

### AML False Positive Rate
```sql
SELECT r.rule_name,
    COUNT(*) AS alerts,
    ROUND(100.0 * SUM(CASE WHEN is_false_positive THEN 1 ELSE 0 END) / COUNT(*), 1) AS fp_pct
FROM banking_dw.fact_aml_alert a
JOIN banking_dw.dim_aml_rule r ON r.aml_rule_sk = a.aml_rule_sk
GROUP BY r.rule_name ORDER BY fp_pct DESC;
```

### Net Interest Margin
```sql
SELECT d.calendar_year, d.month_num,
    SUM(CASE WHEN gl.is_interest_income  THEN g.closing_balance_rcy ELSE 0 END) AS interest_income,
    SUM(CASE WHEN gl.is_interest_expense THEN g.closing_balance_rcy ELSE 0 END) AS interest_expense,
    SUM(CASE WHEN gl.is_interest_income  THEN g.closing_balance_rcy ELSE 0 END) -
    SUM(CASE WHEN gl.is_interest_expense THEN g.closing_balance_rcy ELSE 0 END) AS nii
FROM banking_dw.fact_gl_balance g
JOIN banking_dw.dim_gl_account gl ON gl.gl_account_sk = g.gl_account_sk
JOIN banking_dw.dim_date d ON d.date_sk = g.period_end_date_sk
WHERE g.period_type = 'MONTHLY'
GROUP BY 1, 2 ORDER BY 1, 2;
```

---

## OpenMetadata Connection

```yaml
source:
  type: postgres
  serviceName: banking-dw-demo
  serviceConnection:
    config:
      type: Postgres
      hostPort: localhost:5432
      database: banking_dw
      username: postgres
      password: Password1001
  sourceConfig:
    config:
      schemaFilterPattern:
        includes:
          - banking_dw
          - banking_ref
      tableFilterPattern:
        excludes:
          - pg_*
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Port 5432 already in use | `sudo lsof -i :5432` then kill the process, or change port in compose |
| Docker build fails (network) | Ensure internet access; try `docker build --network=host .` |
| Data load slow | Normal for 11 MB SQL file; Docker: ~2 min; bare-metal: ~1 min |
| `FATAL: password authentication failed` | Use `psql -h localhost` (not `psql` alone) to force TCP not socket |
| Container exits immediately | Check `docker logs banking-dw-postgres` |
| Ubuntu script: `initdb` not found | Ensure `/usr/lib/postgresql/17/bin` is in PATH or use full path |
