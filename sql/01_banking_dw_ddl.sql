-- =============================================================================
--  GLOBAL BANKING DATA WAREHOUSE — PostgreSQL DDL (NO PK/FK CONSTRAINTS)
--  Companion to: Banking DW Model v1.0 (Kimball Architecture)
--  Schemas:  banking_dw  (dimensions + facts)
--            banking_ref  (reference / lookup data)
--  Compatible: PostgreSQL 13+
--  Run order: This file (DDL) → 02_banking_dw_data.sql (seed data)
-- =============================================================================

-- Drop & recreate schemas for clean setup
DROP SCHEMA IF EXISTS banking_dw  CASCADE;
DROP SCHEMA IF EXISTS banking_ref CASCADE;

CREATE SCHEMA banking_ref;
CREATE SCHEMA banking_dw;

-- Helpful comment
COMMENT ON SCHEMA banking_ref IS 'Reference / lookup tables: currencies, countries, exchange rates';
COMMENT ON SCHEMA banking_dw  IS 'Dimensional model: conformed dimensions, subject dimensions, fact tables, bridge tables';

-- ─────────────────────────────────────────────────────────────────────────────
--  SECTION 1 — REFERENCE DATA (banking_ref)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE banking_ref.country (
    country_code        CHAR(3)         NOT NULL,
    country_code_2      CHAR(2),
    country_name        VARCHAR(100)    NOT NULL,
    region              VARCHAR(50),
    sub_region          VARCHAR(80),
    aml_risk_rating     VARCHAR(10)     CHECK (aml_risk_rating IN ('LOW','MEDIUM','HIGH','BLACKLIST')),
    fatf_member         BOOLEAN         DEFAULT FALSE,
    fatf_grey_list      BOOLEAN         DEFAULT FALSE,
    fatf_black_list     BOOLEAN         DEFAULT FALSE,
    eu_member           BOOLEAN         DEFAULT FALSE,
    gdpr_adequate       BOOLEAN         DEFAULT FALSE,
    sanctions_risk_flag BOOLEAN         DEFAULT FALSE,
    fatca_iga_type      VARCHAR(10)     CHECK (fatca_iga_type IN ('MODEL_1','MODEL_2','NONE')),
    calling_code        VARCHAR(10),
    is_active           BOOLEAN         DEFAULT TRUE
);

CREATE TABLE banking_ref.currency (
    currency_code           CHAR(3)         NOT NULL,
    currency_name           VARCHAR(100)    NOT NULL,
    currency_symbol         VARCHAR(5),
    minor_unit_decimals     SMALLINT        DEFAULT 2,
    is_active               BOOLEAN         DEFAULT TRUE,
    is_restricted           BOOLEAN         DEFAULT FALSE,
    is_reporting_currency   BOOLEAN         DEFAULT FALSE,
    country_code            CHAR(3)
);

CREATE TABLE banking_ref.exchange_rate (
    rate_id             UUID            DEFAULT gen_random_uuid() NOT NULL,
    from_currency_code  CHAR(3)         NOT NULL,
    to_currency_code    CHAR(3)         NOT NULL,
    rate_type           VARCHAR(20)     NOT NULL CHECK (rate_type IN ('SPOT','TT_BUY','TT_SELL','CARD_RATE','MID_RATE')),
    rate_date           DATE            NOT NULL,
    rate_value          NUMERIC(15,8)   NOT NULL,
    rate_source         VARCHAR(50)     DEFAULT 'INTERNAL',
    valid_from_datetime TIMESTAMP       NOT NULL,
    valid_to_datetime   TIMESTAMP
);

-- ─────────────────────────────────────────────────────────────────────────────
--  SECTION 2 — CONFORMED DIMENSIONS (banking_dw)
-- ─────────────────────────────────────────────────────────────────────────────

-- ── DIM_DATE ─────────────────────────────────────────────────────────────────
CREATE TABLE banking_dw.dim_date (
    date_sk                 INTEGER         NOT NULL,   -- YYYYMMDD
    full_date               DATE            NOT NULL,
    day_of_week_num         SMALLINT,
    day_of_week_name        VARCHAR(10),
    day_of_month            SMALLINT,
    week_of_year            SMALLINT,
    month_num               SMALLINT,
    month_name              VARCHAR(10),
    quarter_num             SMALLINT,
    quarter_name            CHAR(2),
    calendar_year           SMALLINT,
    fiscal_year             SMALLINT,
    fiscal_quarter          SMALLINT,
    fiscal_month            SMALLINT,
    is_weekend              BOOLEAN         DEFAULT FALSE,
    is_public_holiday       BOOLEAN         DEFAULT FALSE,
    is_bank_working_day     BOOLEAN         DEFAULT TRUE,
    is_month_end            BOOLEAN         DEFAULT FALSE,
    is_quarter_end          BOOLEAN         DEFAULT FALSE,
    is_year_end             BOOLEAN         DEFAULT FALSE,
    is_fiscal_month_end     BOOLEAN         DEFAULT FALSE,
    days_in_month           SMALLINT,
    days_remaining_month    SMALLINT,
    prior_year_date_sk      INTEGER
);
COMMENT ON TABLE banking_dw.dim_date IS 'Date dimension — SCD Type 0 (static). Grain: one row per calendar day.';

-- ── DIM_GEOGRAPHY ─────────────────────────────────────────────────────────────
CREATE TABLE banking_dw.dim_geography (
    geography_sk            SERIAL          NOT NULL,
    country_code            CHAR(3)         NOT NULL,
    country_code_2          CHAR(2),
    country_name            VARCHAR(100)    NOT NULL,
    region                  VARCHAR(50),
    sub_region              VARCHAR(80),
    aml_risk_rating         VARCHAR(10)     CHECK (aml_risk_rating IN ('LOW','MEDIUM','HIGH','BLACKLIST')),
    fatf_member             BOOLEAN         DEFAULT FALSE,
    fatf_grey_list          BOOLEAN         DEFAULT FALSE,
    fatf_black_list         BOOLEAN         DEFAULT FALSE,
    eu_member               BOOLEAN         DEFAULT FALSE,
    gdpr_adequate           BOOLEAN         DEFAULT FALSE,
    sanctions_risk_flag     BOOLEAN         DEFAULT FALSE,
    fatca_iga_type          VARCHAR(10),
    -- SCD Type 2
    effective_from_date     DATE            NOT NULL DEFAULT CURRENT_DATE,
    effective_to_date       DATE,
    is_current_record       BOOLEAN         NOT NULL DEFAULT TRUE,
    dw_insert_datetime      TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_dim_geography_code ON banking_dw.dim_geography(country_code) WHERE is_current_record = TRUE;
COMMENT ON TABLE banking_dw.dim_geography IS 'Geography/Country dimension — SCD Type 2. Tracks FATF list changes.';

-- ── DIM_CURRENCY ──────────────────────────────────────────────────────────────
CREATE TABLE banking_dw.dim_currency (
    currency_sk             SERIAL          NOT NULL,
    currency_code           CHAR(3)         NOT NULL,
    currency_name           VARCHAR(100)    NOT NULL,
    currency_symbol         VARCHAR(5),
    minor_unit_decimals     SMALLINT        DEFAULT 2,
    country_sk              INTEGER,
    is_active               BOOLEAN         DEFAULT TRUE,
    is_restricted           BOOLEAN         DEFAULT FALSE,
    is_reporting_currency   BOOLEAN         DEFAULT FALSE,
    dw_insert_datetime      TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX idx_dim_currency_code ON banking_dw.dim_currency(currency_code);
COMMENT ON TABLE banking_dw.dim_currency IS 'Currency reference dimension — SCD Type 1.';

-- ── DIM_CUSTOMER ──────────────────────────────────────────────────────────────
CREATE TABLE banking_dw.dim_customer (
    customer_sk             BIGSERIAL       NOT NULL,
    customer_nk             VARCHAR(36)     NOT NULL,   -- OLTP party_id
    customer_number         VARCHAR(30),
    full_name               VARCHAR(255),               -- PII — mask in non-prod
    first_name              VARCHAR(100),               -- PII
    last_name               VARCHAR(100),               -- PII
    date_of_birth           DATE,                       -- PII — Sensitive
    age_band                VARCHAR(20),
    gender                  VARCHAR(15),
    nationality_country_sk  INTEGER,
    residency_country_sk    INTEGER,
    customer_type           VARCHAR(20)     CHECK (customer_type IN ('INDIVIDUAL','ORGANIZATION','TRUST')),
    customer_segment        VARCHAR(30),
    customer_sub_segment    VARCHAR(50),
    kyc_status              VARCHAR(20)     CHECK (kyc_status IN ('VERIFIED','PENDING','EXPIRED','REJECTED')),
    kyc_expiry_date         DATE,
    risk_rating             VARCHAR(10)     CHECK (risk_rating IN ('LOW','MEDIUM','HIGH','VERY_HIGH')),
    pep_flag                BOOLEAN         DEFAULT FALSE,
    sanctions_flag          BOOLEAN         DEFAULT FALSE,
    fatca_flag              BOOLEAN         DEFAULT FALSE,
    crs_flag                BOOLEAN         DEFAULT FALSE,
    acquisition_channel     VARCHAR(30),
    acquisition_date        DATE,
    relationship_tenure_yrs NUMERIC(5,1),
    branch_sk               INTEGER,
    relationship_mgr_sk     INTEGER,
    annual_income_band      VARCHAR(20),
    employment_status       VARCHAR(30),
    -- SCD Type 2
    effective_from_date     DATE            NOT NULL DEFAULT CURRENT_DATE,
    effective_to_date       DATE,
    is_current_record       BOOLEAN         NOT NULL DEFAULT TRUE,
    dw_insert_datetime      TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    dw_source_system        VARCHAR(50)     DEFAULT 'CBS'
);
CREATE INDEX idx_dim_customer_nk ON banking_dw.dim_customer(customer_nk) WHERE is_current_record = TRUE;
CREATE INDEX idx_dim_customer_segment ON banking_dw.dim_customer(customer_segment, risk_rating);
COMMENT ON TABLE banking_dw.dim_customer IS 'Customer dimension — SCD Type 2. PII columns tagged: full_name, date_of_birth, first_name, last_name.';

-- ── DIM_PRODUCT ───────────────────────────────────────────────────────────────
CREATE TABLE banking_dw.dim_product (
    product_sk              SERIAL          NOT NULL,
    product_nk              VARCHAR(36)     NOT NULL,
    product_code            VARCHAR(20)     NOT NULL,
    product_name            VARCHAR(200)    NOT NULL,
    product_category        VARCHAR(50),
    product_sub_category    VARCHAR(50),
    target_segment          VARCHAR(30),
    is_islamic              BOOLEAN         DEFAULT FALSE,
    islamic_contract_type   VARCHAR(30),
    product_status          VARCHAR(20)     CHECK (product_status IN ('ACTIVE','DISCONTINUED','SUSPENDED')),
    launch_date             DATE,
    base_interest_rate      NUMERIC(8,4),
    min_loan_amount         NUMERIC(20,2),
    max_loan_amount         NUMERIC(20,2),
    requires_collateral     BOOLEAN         DEFAULT FALSE,
    gl_code_asset           VARCHAR(20),
    gl_code_liability       VARCHAR(20),
    dw_insert_datetime      TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX idx_dim_product_code ON banking_dw.dim_product(product_code);
COMMENT ON TABLE banking_dw.dim_product IS 'Product catalog dimension — SCD Type 1.';

-- ── DIM_BRANCH ────────────────────────────────────────────────────────────────
CREATE TABLE banking_dw.dim_branch (
    branch_sk               SERIAL          NOT NULL,
    branch_nk               VARCHAR(36)     NOT NULL,
    branch_code             VARCHAR(10)     NOT NULL,
    branch_name             VARCHAR(200)    NOT NULL,
    branch_type             VARCHAR(30),
    channel_category        VARCHAR(20)     CHECK (channel_category IN ('PHYSICAL','DIGITAL','HYBRID')),
    region_name             VARCHAR(100),
    city                    VARCHAR(100),
    country_sk              INTEGER,
    swift_bic_code          VARCHAR(20),
    branch_status           VARCHAR(20)     CHECK (branch_status IN ('OPEN','CLOSED','TEMPORARILY_CLOSED')),
    manager_employee_sk     INTEGER,
    latitude                NUMERIC(9,6),
    longitude               NUMERIC(9,6),
    -- SCD Type 2
    effective_from_date     DATE            NOT NULL DEFAULT CURRENT_DATE,
    effective_to_date       DATE,
    is_current_record       BOOLEAN         NOT NULL DEFAULT TRUE
);
CREATE INDEX idx_dim_branch_code ON banking_dw.dim_branch(branch_code) WHERE is_current_record = TRUE;
COMMENT ON TABLE banking_dw.dim_branch IS 'Branch & channel dimension — SCD Type 2.';

-- ── DIM_EMPLOYEE ──────────────────────────────────────────────────────────────
CREATE TABLE banking_dw.dim_employee (
    employee_sk             SERIAL          NOT NULL,
    employee_nk             VARCHAR(36)     NOT NULL,
    employee_number         VARCHAR(20),
    full_name               VARCHAR(200),               -- PII — mask in non-prod
    job_title               VARCHAR(100),
    job_function            VARCHAR(50),
    department_name         VARCHAR(100),
    branch_sk               INTEGER,
    manager_employee_sk     INTEGER,
    hire_date               DATE,
    employment_status       VARCHAR(20)     CHECK (employment_status IN ('ACTIVE','ON_LEAVE','TERMINATED')),
    -- SCD Type 2
    effective_from_date     DATE            NOT NULL DEFAULT CURRENT_DATE,
    effective_to_date       DATE,
    is_current_record       BOOLEAN         NOT NULL DEFAULT TRUE
);
CREATE INDEX idx_dim_employee_nk ON banking_dw.dim_employee(employee_nk) WHERE is_current_record = TRUE;
COMMENT ON TABLE banking_dw.dim_employee IS 'Employee dimension — SCD Type 2. PII: full_name.';

-- ── DIM_ACCOUNT ───────────────────────────────────────────────────────────────
CREATE TABLE banking_dw.dim_account (
    account_sk              BIGSERIAL       NOT NULL,
    account_nk              VARCHAR(36)     NOT NULL,
    account_number          VARCHAR(34),                -- PII — mask in non-prod
    account_type            VARCHAR(30),
    account_status          VARCHAR(20)     CHECK (account_status IN ('ACTIVE','DORMANT','FROZEN','CLOSED','PENDING')),
    product_sk              INTEGER,
    customer_sk             BIGINT,
    branch_sk               INTEGER,
    currency_sk             INTEGER,
    open_date               DATE,
    close_date              DATE,
    interest_rate           NUMERIC(8,4),
    interest_rate_type      VARCHAR(20),
    overdraft_limit         NUMERIC(20,2)   DEFAULT 0,
    customer_segment        VARCHAR(30),
    is_salary_account       BOOLEAN         DEFAULT FALSE,
    is_dormant              BOOLEAN         DEFAULT FALSE,
    dormancy_date           DATE,
    -- SCD Type 2
    effective_from_date     DATE            NOT NULL DEFAULT CURRENT_DATE,
    effective_to_date       DATE,
    is_current_record       BOOLEAN         NOT NULL DEFAULT TRUE,
    dw_insert_datetime      TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_dim_account_nk ON banking_dw.dim_account(account_nk) WHERE is_current_record = TRUE;
CREATE INDEX idx_dim_account_customer ON banking_dw.dim_account(customer_sk, account_type);
COMMENT ON TABLE banking_dw.dim_account IS 'Account dimension — SCD Type 2. PII: account_number (IBAN).';

-- ── DIM_GL_ACCOUNT ────────────────────────────────────────────────────────────
CREATE TABLE banking_dw.dim_gl_account (
    gl_account_sk           SERIAL          NOT NULL,
    gl_account_nk           VARCHAR(36),
    gl_account_code         VARCHAR(20)     NOT NULL,
    gl_account_name         VARCHAR(200)    NOT NULL,
    account_class           VARCHAR(20)     CHECK (account_class IN ('ASSET','LIABILITY','EQUITY','INCOME','EXPENSE')),
    account_type            VARCHAR(50),
    normal_balance_side     VARCHAR(6)      CHECK (normal_balance_side IN ('DEBIT','CREDIT')),
    level1_name             VARCHAR(100),
    level2_name             VARCHAR(100),
    level3_name             VARCHAR(100),
    level4_name             VARCHAR(100),
    level5_name             VARCHAR(100),
    is_posting_account      BOOLEAN         DEFAULT TRUE,
    ifrs_statement_line     VARCHAR(100),
    is_interest_income      BOOLEAN         DEFAULT FALSE,
    is_interest_expense     BOOLEAN         DEFAULT FALSE,
    is_provision            BOOLEAN         DEFAULT FALSE,
    is_fee_income           BOOLEAN         DEFAULT FALSE,
    dw_insert_datetime      TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX idx_dim_gl_code ON banking_dw.dim_gl_account(gl_account_code);
COMMENT ON TABLE banking_dw.dim_gl_account IS 'GL Chart of Accounts dimension — SCD Type 1 with hierarchy roll-up levels.';

-- ── DIM_COLLATERAL ────────────────────────────────────────────────────────────
CREATE TABLE banking_dw.dim_collateral (
    collateral_sk           SERIAL          NOT NULL,
    collateral_nk           VARCHAR(36)     NOT NULL,
    collateral_type         VARCHAR(50),
    collateral_description  VARCHAR(500),
    owner_customer_sk       BIGINT,
    location_country_sk     INTEGER,
    nominal_value           NUMERIC(20,2),
    market_value            NUMERIC(20,2),
    eligible_value          NUMERIC(20,2),
    haircut_percentage      NUMERIC(5,2),
    legal_perfection_status VARCHAR(30),
    valuation_date          DATE,
    status                  VARCHAR(20)     CHECK (status IN ('ACTIVE','RELEASED','IMPAIRED','DISPOSED')),
    -- SCD Type 2
    effective_from_date     DATE            NOT NULL DEFAULT CURRENT_DATE,
    effective_to_date       DATE,
    is_current_record       BOOLEAN         NOT NULL DEFAULT TRUE
);
COMMENT ON TABLE banking_dw.dim_collateral IS 'Collateral asset dimension — SCD Type 2 (market value changes trigger new version).';

-- ── DIM_AML_RULE ──────────────────────────────────────────────────────────────
CREATE TABLE banking_dw.dim_aml_rule (
    aml_rule_sk             SERIAL          NOT NULL,
    rule_nk                 VARCHAR(36),
    rule_name               VARCHAR(200)    NOT NULL,
    rule_type               VARCHAR(30),
    rule_category           VARCHAR(50),
    risk_typology           VARCHAR(100),
    alert_severity_default  VARCHAR(10)     CHECK (alert_severity_default IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    threshold_description   VARCHAR(500),
    rule_version            VARCHAR(20),
    is_active               BOOLEAN         DEFAULT TRUE,
    ml_model_flag           BOOLEAN         DEFAULT FALSE,
    last_tuned_date         DATE,
    dw_insert_datetime      TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE banking_dw.dim_aml_rule IS 'AML rule/model dimension for AML Compliance mart.';

-- ─────────────────────────────────────────────────────────────────────────────
--  SECTION 3 — BRIDGE TABLES
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE banking_dw.bridge_account_customer (
    bridge_account_customer_sk  BIGSERIAL   NOT NULL,
    account_sk                  BIGINT      NOT NULL,
    customer_sk                 BIGINT      NOT NULL,
    role_type                   VARCHAR(30) NOT NULL,
    ownership_weight            NUMERIC(5,2) DEFAULT 100.00,
    effective_from_date         DATE,
    effective_to_date           DATE,
    is_current                  BOOLEAN     DEFAULT TRUE
);
CREATE INDEX idx_bridge_acct_cust ON banking_dw.bridge_account_customer(account_sk, customer_sk) WHERE is_current = TRUE;
COMMENT ON TABLE banking_dw.bridge_account_customer IS 'Bridge: M:N between accounts and customers (joint owners, guarantors).';

CREATE TABLE banking_dw.bridge_loan_collateral (
    bridge_loan_collateral_sk   BIGSERIAL   NOT NULL,
    account_sk                  BIGINT      NOT NULL,
    collateral_sk               INTEGER     NOT NULL,
    allocation_percentage       NUMERIC(5,2) DEFAULT 100.00,
    allocated_collateral_value  NUMERIC(20,2),
    effective_from_date         DATE,
    effective_to_date           DATE
);
COMMENT ON TABLE banking_dw.bridge_loan_collateral IS 'Bridge: M:N between loan accounts and collateral assets.';

-- ─────────────────────────────────────────────────────────────────────────────
--  SECTION 4 — FACT TABLES
-- ─────────────────────────────────────────────────────────────────────────────

-- ── FACT_TRANSACTION ─────────────────────────────────────────────────────────
-- NOTE: PostgreSQL requires the partition key (booking_date_sk) to be part of
-- any PRIMARY KEY or UNIQUE constraint on a partitioned table.
-- (PK removed per request.)
CREATE TABLE banking_dw.fact_transaction (
    transaction_sk              BIGINT          NOT NULL,   -- populated by generator; use sequence for new rows
    transaction_nk              VARCHAR(36)     NOT NULL,
    transaction_reference       VARCHAR(50),
    -- Date keys (no inline FK on partitioned table — enforced by ETL)
    booking_date_sk             INTEGER         NOT NULL,   -- FK → dim_date.date_sk (partition key)
    value_date_sk               INTEGER,                    -- FK → dim_date.date_sk
    transaction_datetime        TIMESTAMP       NOT NULL,
    -- Dimension keys (no inline FK on partitioned table — enforced by ETL)
    account_sk                  BIGINT,                     -- FK → dim_account.account_sk
    customer_sk                 BIGINT,                     -- FK → dim_customer.customer_sk
    product_sk                  INTEGER,                    -- FK → dim_product.product_sk
    branch_sk                   INTEGER,                    -- FK → dim_branch.branch_sk
    currency_sk                 INTEGER,                    -- FK → dim_currency.currency_sk
    teller_employee_sk          INTEGER,                    -- FK → dim_employee.employee_sk
    counterparty_country_sk     INTEGER,                    -- FK → dim_geography.geography_sk
    -- Descriptive
    transaction_type            VARCHAR(30),
    transaction_channel         VARCHAR(30),
    merchant_category_code      VARCHAR(10),
    -- Measures
    amount_txn_ccy              NUMERIC(20,2)   NOT NULL,
    amount_reporting_ccy        NUMERIC(20,2),
    fx_rate_applied             NUMERIC(12,6)   DEFAULT 1.000000,
    balance_after_txn           NUMERIC(20,2),
    -- Flags
    is_credit                   BOOLEAN         DEFAULT FALSE,
    is_debit                    BOOLEAN         DEFAULT FALSE,
    is_reversal                 BOOLEAN         DEFAULT FALSE,
    fraud_flag                  BOOLEAN         DEFAULT FALSE,
    fraud_score                 NUMERIC(5,2)    DEFAULT 0,
    aml_flag                    BOOLEAN         DEFAULT FALSE,
    ctr_flag                    BOOLEAN         DEFAULT FALSE,
    sar_linked_flag             BOOLEAN         DEFAULT FALSE,
    -- Audit
    dw_insert_datetime          TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    dw_batch_id                 VARCHAR(50)
) PARTITION BY RANGE (booking_date_sk);
COMMENT ON TABLE banking_dw.fact_transaction IS 'Transactional fact. Grain: one row per posted financial transaction. Partitioned by booking_date_sk (YYYYMMDD).';

-- Yearly partitions — add more as needed
CREATE TABLE banking_dw.fact_transaction_2022
    PARTITION OF banking_dw.fact_transaction
    FOR VALUES FROM (20220101) TO (20230101);

CREATE TABLE banking_dw.fact_transaction_2023
    PARTITION OF banking_dw.fact_transaction
    FOR VALUES FROM (20230101) TO (20240101);

CREATE TABLE banking_dw.fact_transaction_2024
    PARTITION OF banking_dw.fact_transaction
    FOR VALUES FROM (20240101) TO (20250101);

CREATE TABLE banking_dw.fact_transaction_2025
    PARTITION OF banking_dw.fact_transaction
    FOR VALUES FROM (20250101) TO (20260101);

-- Default partition catches any out-of-range rows (prevents insert errors)
CREATE TABLE banking_dw.fact_transaction_default
    PARTITION OF banking_dw.fact_transaction DEFAULT;

-- Sequence for transaction_sk (used instead of BIGSERIAL on partitioned table)
CREATE SEQUENCE banking_dw.fact_transaction_transaction_sk_seq
    START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER TABLE banking_dw.fact_transaction
    ALTER COLUMN transaction_sk SET DEFAULT nextval('banking_dw.fact_transaction_transaction_sk_seq');

-- Indexes (propagate automatically to all partitions)
CREATE INDEX idx_fact_txn_account   ON banking_dw.fact_transaction(account_sk);
CREATE INDEX idx_fact_txn_customer  ON banking_dw.fact_transaction(customer_sk);
CREATE INDEX idx_fact_txn_date      ON banking_dw.fact_transaction(booking_date_sk);
CREATE INDEX idx_fact_txn_nk        ON banking_dw.fact_transaction(transaction_nk);
CREATE INDEX idx_fact_txn_aml       ON banking_dw.fact_transaction(aml_flag, booking_date_sk) WHERE aml_flag = TRUE;
CREATE INDEX idx_fact_txn_fraud     ON banking_dw.fact_transaction(fraud_flag, booking_date_sk) WHERE fraud_flag = TRUE;

-- ── FACT_ACCOUNT_BALANCE_DAILY ────────────────────────────────────────────────
CREATE TABLE banking_dw.fact_account_balance_daily (
    balance_snapshot_sk         BIGSERIAL       NOT NULL,
    snapshot_date_sk            INTEGER         NOT NULL,
    account_sk                  BIGINT          NOT NULL,
    customer_sk                 BIGINT,
    product_sk                  INTEGER,
    branch_sk                   INTEGER,
    currency_sk                 INTEGER,
    -- Measures
    current_balance             NUMERIC(20,2)   NOT NULL DEFAULT 0,
    available_balance           NUMERIC(20,2)   DEFAULT 0,
    hold_amount                 NUMERIC(20,2)   DEFAULT 0,
    accrued_interest            NUMERIC(20,2)   DEFAULT 0,
    balance_reporting_ccy       NUMERIC(20,2),
    days_since_last_txn         INTEGER         DEFAULT 0,
    transaction_count_day       INTEGER         DEFAULT 0,
    credit_amount_day           NUMERIC(20,2)   DEFAULT 0,
    debit_amount_day            NUMERIC(20,2)   DEFAULT 0,
    -- Flags
    is_dormant_flag             BOOLEAN         DEFAULT FALSE,
    is_overdrawn                BOOLEAN         DEFAULT FALSE,
    -- Audit
    dw_insert_datetime          TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_fact_bal_account  ON banking_dw.fact_account_balance_daily(account_sk, snapshot_date_sk);
CREATE INDEX idx_fact_bal_customer ON banking_dw.fact_account_balance_daily(customer_sk, snapshot_date_sk);
COMMENT ON TABLE banking_dw.fact_account_balance_daily IS 'Periodic snapshot fact. Grain: one row per account per calendar day (EOD balance).';

-- ── FACT_LOAN_DAILY_SNAPSHOT ──────────────────────────────────────────────────
CREATE TABLE banking_dw.fact_loan_daily_snapshot (
    loan_snapshot_sk            BIGSERIAL       NOT NULL,
    snapshot_date_sk            INTEGER         NOT NULL,
    account_sk                  BIGINT          NOT NULL,
    customer_sk                 BIGINT,
    product_sk                  INTEGER,
    branch_sk                   INTEGER,
    currency_sk                 INTEGER,
    loan_type                   VARCHAR(30),
    -- Measures
    outstanding_principal       NUMERIC(20,2)   DEFAULT 0,
    outstanding_interest        NUMERIC(20,2)   DEFAULT 0,
    outstanding_fees            NUMERIC(20,2)   DEFAULT 0,
    total_outstanding           NUMERIC(20,2)   DEFAULT 0,
    total_outstanding_rcy       NUMERIC(20,2)   DEFAULT 0,
    days_past_due               INTEGER         DEFAULT 0,
    past_due_amount             NUMERIC(20,2)   DEFAULT 0,
    dpd_bucket                  VARCHAR(10)     CHECK (dpd_bucket IN ('0','1-30','31-60','61-90','91-180','180+','NPL')),
    -- IFRS 9
    ifrs9_stage                 SMALLINT        CHECK (ifrs9_stage IN (1,2,3)),
    ecl_provision_amount        NUMERIC(20,2)   DEFAULT 0,
    ecl_pd                      NUMERIC(8,6)    DEFAULT 0,
    ecl_lgd                     NUMERIC(8,6)    DEFAULT 0,
    ecl_ead                     NUMERIC(20,2)   DEFAULT 0,
    credit_grade                VARCHAR(10),
    -- Credit flags
    is_npl_flag                 BOOLEAN         DEFAULT FALSE,
    is_restructured             BOOLEAN         DEFAULT FALSE,
    is_written_off              BOOLEAN         DEFAULT FALSE,
    -- Collateral
    collateral_value            NUMERIC(20,2)   DEFAULT 0,
    loan_to_value_ratio         NUMERIC(6,4),
    interest_rate               NUMERIC(8,4),
    accrued_interest_rcy        NUMERIC(20,2)   DEFAULT 0,
    -- Audit
    dw_insert_datetime          TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_fact_loan_account   ON banking_dw.fact_loan_daily_snapshot(account_sk, snapshot_date_sk);
CREATE INDEX idx_fact_loan_customer  ON banking_dw.fact_loan_daily_snapshot(customer_sk);
CREATE INDEX idx_fact_loan_npl       ON banking_dw.fact_loan_daily_snapshot(is_npl_flag) WHERE is_npl_flag = TRUE;
CREATE INDEX idx_fact_loan_ifrs9     ON banking_dw.fact_loan_daily_snapshot(ifrs9_stage, snapshot_date_sk);
COMMENT ON TABLE banking_dw.fact_loan_daily_snapshot IS 'Periodic snapshot fact. Grain: one row per active loan per day. Contains IFRS 9 ECL fields, DPD buckets, and NPL flags.';

-- ── FACT_PAYMENT_ORDER ────────────────────────────────────────────────────────
CREATE TABLE banking_dw.fact_payment_order (
    payment_order_sk            BIGSERIAL       NOT NULL,
    payment_nk                  VARCHAR(36)     NOT NULL,
    instruction_date_sk         INTEGER         NOT NULL,
    settlement_date_sk          INTEGER,
    debtor_account_sk           BIGINT,
    debtor_customer_sk          BIGINT,
    debtor_branch_sk            INTEGER,
    currency_sk                 INTEGER,
    creditor_country_sk         INTEGER,
    -- Descriptive
    payment_type                VARCHAR(30),
    payment_status              VARCHAR(20),
    rejection_reason_code       VARCHAR(50),
    sanctions_screening_status  VARCHAR(20)     DEFAULT 'CLEAR',
    aml_screening_status        VARCHAR(20)     DEFAULT 'CLEAR',
    -- Measures
    payment_amount              NUMERIC(20,2)   NOT NULL,
    payment_amount_rcy          NUMERIC(20,2),
    fx_rate_applied             NUMERIC(12,6)   DEFAULT 1.000000,
    charge_amount               NUMERIC(12,2)   DEFAULT 0,
    processing_time_seconds     INTEGER,
    -- Flags
    is_cross_border             BOOLEAN         DEFAULT FALSE,
    is_stp                      BOOLEAN         DEFAULT TRUE,
    is_rejected                 BOOLEAN         DEFAULT FALSE,
    -- Audit
    dw_insert_datetime          TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_fact_pay_customer ON banking_dw.fact_payment_order(debtor_customer_sk);
CREATE INDEX idx_fact_pay_date     ON banking_dw.fact_payment_order(instruction_date_sk);
CREATE INDEX idx_fact_pay_status   ON banking_dw.fact_payment_order(payment_status, is_rejected);
COMMENT ON TABLE banking_dw.fact_payment_order IS 'Transactional fact. Grain: one row per payment order/instruction.';

-- ── FACT_AML_ALERT ────────────────────────────────────────────────────────────
CREATE TABLE banking_dw.fact_aml_alert (
    aml_alert_sk                BIGSERIAL       NOT NULL,
    alert_nk                    VARCHAR(36)     NOT NULL,
    -- Milestone date FKs (accumulating snapshot)
    generated_date_sk           INTEGER,
    assigned_date_sk            INTEGER,
    reviewed_date_sk            INTEGER,
    escalated_date_sk           INTEGER,
    closed_date_sk              INTEGER,
    sar_filed_date_sk           INTEGER,
    -- Dimension FKs
    subject_customer_sk         BIGINT,
    subject_account_sk          BIGINT,
    triggering_transaction_sk   BIGINT,  -- soft FK to fact_transaction
    assigned_analyst_sk         INTEGER,
    branch_sk                   INTEGER,
    aml_rule_sk                 INTEGER,
    -- Descriptive
    alert_type                  VARCHAR(50),
    alert_severity              VARCHAR(10)     CHECK (alert_severity IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    alert_status                VARCHAR(30),
    generated_by                VARCHAR(30),
    -- Measures
    ml_risk_score               NUMERIC(5,2)    DEFAULT 0,
    alert_amount                NUMERIC(20,2),
    alert_amount_rcy            NUMERIC(20,2),
    days_to_assign              INTEGER,
    days_to_close               INTEGER,
    -- Flags
    is_false_positive           BOOLEAN         DEFAULT FALSE,
    is_sar_filed                BOOLEAN         DEFAULT FALSE,
    -- Audit
    dw_insert_datetime          TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_fact_aml_customer  ON banking_dw.fact_aml_alert(subject_customer_sk);
CREATE INDEX idx_fact_aml_severity  ON banking_dw.fact_aml_alert(alert_severity, alert_status);
CREATE INDEX idx_fact_aml_sar       ON banking_dw.fact_aml_alert(is_sar_filed) WHERE is_sar_filed = TRUE;
CREATE INDEX idx_fact_aml_date      ON banking_dw.fact_aml_alert(generated_date_sk);
COMMENT ON TABLE banking_dw.fact_aml_alert IS 'Accumulating snapshot fact. Grain: one row per AML alert (updated as milestones occur).';

-- ── FACT_GL_BALANCE ───────────────────────────────────────────────────────────
CREATE TABLE banking_dw.fact_gl_balance (
    gl_balance_sk               BIGSERIAL       NOT NULL,
    period_end_date_sk          INTEGER         NOT NULL,
    gl_account_sk               INTEGER         NOT NULL,
    branch_sk                   INTEGER,
    currency_sk                 INTEGER,
    cost_center_code            VARCHAR(20),
    profit_center_code          VARCHAR(20),
    period_type                 VARCHAR(10)     CHECK (period_type IN ('MONTHLY','QUARTERLY','ANNUAL')),
    -- Measures
    opening_balance             NUMERIC(22,2)   DEFAULT 0,
    total_debits                NUMERIC(22,2)   DEFAULT 0,
    total_credits               NUMERIC(22,2)   DEFAULT 0,
    closing_balance             NUMERIC(22,2)   DEFAULT 0,
    closing_balance_rcy         NUMERIC(22,2)   DEFAULT 0,
    ytd_balance                 NUMERIC(22,2)   DEFAULT 0,
    budget_amount               NUMERIC(22,2),
    variance_vs_budget          NUMERIC(22,2),
    prior_year_balance          NUMERIC(22,2),
    yoy_variance                NUMERIC(22,2),
    -- Flags
    is_audited                  BOOLEAN         DEFAULT FALSE,
    -- Audit
    dw_insert_datetime          TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_fact_gl_account ON banking_dw.fact_gl_balance(gl_account_sk, period_end_date_sk);
CREATE INDEX idx_fact_gl_branch  ON banking_dw.fact_gl_balance(branch_sk, period_end_date_sk);
COMMENT ON TABLE banking_dw.fact_gl_balance IS 'Periodic snapshot fact. Grain: one row per GL account per period per branch. Powers Financial Performance mart.';

-- ─────────────────────────────────────────────────────────────────────────────
--  SECTION 5 — ANALYTICAL VIEWS (Data Mart layer)
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Customer 360 View ─────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW banking_dw.vw_customer_360 AS
SELECT
    c.customer_sk,
    c.customer_number,
    c.full_name,
    c.customer_type,
    c.customer_segment,
    c.age_band,
    c.risk_rating,
    c.kyc_status,
    c.pep_flag,
    c.acquisition_channel,
    c.acquisition_date,
    c.relationship_tenure_yrs,
    g_nat.country_name                          AS nationality,
    g_res.country_name                          AS residency_country,
    COUNT(DISTINCT a.account_sk)               AS total_accounts,
    COUNT(DISTINCT CASE WHEN a.account_type = 'CURRENT' THEN a.account_sk END)         AS current_accounts,
    COUNT(DISTINCT CASE WHEN a.account_type = 'SAVINGS' THEN a.account_sk END)         AS savings_accounts,
    COUNT(DISTINCT CASE WHEN a.account_type = 'LOAN'    THEN a.account_sk END)         AS loan_accounts,
    COUNT(DISTINCT CASE WHEN a.account_type = 'CREDIT_CARD' THEN a.account_sk END)     AS credit_cards,
    SUM(b.current_balance * fx.rate_value)     AS total_balance_usd,
    MAX(b.snapshot_date_sk)                    AS latest_snapshot_date_sk
FROM banking_dw.dim_customer            c
LEFT JOIN banking_dw.dim_account        a  ON a.customer_sk = c.customer_sk AND a.is_current_record
LEFT JOIN banking_dw.dim_geography      g_nat ON g_nat.geography_sk = c.nationality_country_sk AND g_nat.is_current_record
LEFT JOIN banking_dw.dim_geography      g_res ON g_res.geography_sk = c.residency_country_sk  AND g_res.is_current_record
LEFT JOIN banking_dw.fact_account_balance_daily b ON b.account_sk = a.account_sk
    AND b.snapshot_date_sk = (SELECT MAX(snapshot_date_sk) FROM banking_dw.fact_account_balance_daily)
LEFT JOIN banking_ref.exchange_rate     fx ON fx.from_currency_code = (
        SELECT currency_code FROM banking_dw.dim_currency WHERE currency_sk = a.currency_sk)
    AND fx.to_currency_code = 'USD'
    AND fx.rate_type = 'MID_RATE'
    AND fx.valid_to_datetime IS NULL
WHERE c.is_current_record = TRUE
GROUP BY c.customer_sk, c.customer_number, c.full_name, c.customer_type,
         c.customer_segment, c.age_band, c.risk_rating, c.kyc_status,
         c.pep_flag, c.acquisition_channel, c.acquisition_date,
         c.relationship_tenure_yrs, g_nat.country_name, g_res.country_name;

COMMENT ON VIEW banking_dw.vw_customer_360 IS 'Customer 360 mart view — aggregates account count, balance, product mix per customer.';

-- ── Credit Risk View ──────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW banking_dw.vw_credit_risk_portfolio AS
SELECT
    d.full_date                                 AS snapshot_date,
    p.product_sub_category                      AS loan_type,
    c.customer_segment,
    l.credit_grade,
    l.ifrs9_stage,
    l.dpd_bucket,
    COUNT(*)                                    AS loan_count,
    SUM(l.total_outstanding_rcy)                AS total_exposure_usd,
    SUM(l.ecl_provision_amount)                 AS total_ecl_provision,
    AVG(l.ecl_pd)                               AS avg_pd,
    AVG(l.ecl_lgd)                              AS avg_lgd,
    AVG(l.loan_to_value_ratio)                  AS avg_ltv,
    SUM(CASE WHEN l.is_npl_flag THEN l.total_outstanding_rcy ELSE 0 END) AS npl_exposure_usd,
    ROUND(
        100.0 * SUM(CASE WHEN l.is_npl_flag THEN l.total_outstanding_rcy ELSE 0 END)
             / NULLIF(SUM(l.total_outstanding_rcy), 0), 2
    )                                           AS npl_ratio_pct
FROM banking_dw.fact_loan_daily_snapshot    l
JOIN banking_dw.dim_date                    d  ON d.date_sk = l.snapshot_date_sk
JOIN banking_dw.dim_customer                c  ON c.customer_sk = l.customer_sk AND c.is_current_record
JOIN banking_dw.dim_product                 p  ON p.product_sk = l.product_sk
GROUP BY d.full_date, p.product_sub_category, c.customer_segment,
         l.credit_grade, l.ifrs9_stage, l.dpd_bucket;

COMMENT ON VIEW banking_dw.vw_credit_risk_portfolio IS 'Credit Risk mart view — IFRS 9 staging, NPL ratio, ECL by portfolio segment.';

-- ── Financial Performance View ────────────────────────────────────────────────
CREATE OR REPLACE VIEW banking_dw.vw_financial_performance AS
SELECT
    d.calendar_year,
    d.month_num,
    d.month_name,
    d.fiscal_year,
    d.fiscal_quarter,
    gl.level1_name                              AS p_and_l_category,
    gl.level2_name                              AS p_and_l_subcategory,
    gl.account_class,
    gl.account_type,
    br.branch_name,
    br.region_name,
    SUM(g.closing_balance_rcy)                  AS closing_balance_usd,
    SUM(g.ytd_balance)                          AS ytd_balance_usd,
    SUM(g.budget_amount)                        AS budget_usd,
    SUM(g.closing_balance_rcy - COALESCE(g.budget_amount, 0)) AS variance_vs_budget,
    SUM(g.prior_year_balance)                   AS prior_year_usd,
    SUM(g.closing_balance_rcy - COALESCE(g.prior_year_balance, 0)) AS yoy_change,
    ROUND(
        100.0 * SUM(g.closing_balance_rcy - COALESCE(g.prior_year_balance, 0))
             / NULLIF(ABS(SUM(COALESCE(g.prior_year_balance, 0))), 0), 2
    )                                           AS yoy_growth_pct
FROM banking_dw.fact_gl_balance             g
JOIN banking_dw.dim_date                    d  ON d.date_sk = g.period_end_date_sk
JOIN banking_dw.dim_gl_account              gl ON gl.gl_account_sk = g.gl_account_sk
JOIN banking_dw.dim_branch                  br ON br.branch_sk = g.branch_sk AND br.is_current_record
WHERE g.period_type = 'MONTHLY'
GROUP BY d.calendar_year, d.month_num, d.month_name, d.fiscal_year, d.fiscal_quarter,
         gl.level1_name, gl.level2_name, gl.account_class, gl.account_type,
         br.branch_name, br.region_name;

COMMENT ON VIEW banking_dw.vw_financial_performance IS 'Financial Performance mart view — P&L by period, branch, GL category with YoY and budget variance.';

-- ── AML Compliance View ───────────────────────────────────────────────────────
CREATE OR REPLACE VIEW banking_dw.vw_aml_compliance_dashboard AS
SELECT
    gd.full_date                                AS alert_generated_date,
    r.rule_name,
    r.rule_category,
    a.alert_type,
    a.alert_severity,
    a.alert_status,
    a.generated_by,
    c.customer_segment,
    c.risk_rating                               AS customer_risk_rating,
    br.region_name,
    COUNT(*)                                    AS alert_count,
    AVG(a.ml_risk_score)                        AS avg_ml_score,
    SUM(a.alert_amount_rcy)                     AS total_alert_amount_usd,
    SUM(CASE WHEN a.is_false_positive  THEN 1 ELSE 0 END) AS false_positive_count,
    SUM(CASE WHEN a.is_sar_filed       THEN 1 ELSE 0 END) AS sar_filed_count,
    ROUND(100.0 * SUM(CASE WHEN a.is_false_positive THEN 1 ELSE 0 END)
               / NULLIF(COUNT(*), 0), 2)         AS false_positive_rate_pct,
    AVG(a.days_to_close)                        AS avg_days_to_close,
    AVG(a.days_to_assign)                       AS avg_days_to_assign
FROM banking_dw.fact_aml_alert              a
LEFT JOIN banking_dw.dim_date               gd ON gd.date_sk = a.generated_date_sk
LEFT JOIN banking_dw.dim_aml_rule           r  ON r.aml_rule_sk = a.aml_rule_sk
LEFT JOIN banking_dw.dim_customer           c  ON c.customer_sk = a.subject_customer_sk AND c.is_current_record
LEFT JOIN banking_dw.dim_branch             br ON br.branch_sk = a.branch_sk AND br.is_current_record
GROUP BY gd.full_date, r.rule_name, r.rule_category, a.alert_type,
         a.alert_severity, a.alert_status, a.generated_by,
         c.customer_segment, c.risk_rating, br.region_name;

COMMENT ON VIEW banking_dw.vw_aml_compliance_dashboard IS 'AML Compliance mart view — alert volumes, false positive rates, SAR filing rates by rule, severity, and customer segment.';

-- ── Payments Analytics View ───────────────────────────────────────────────────
CREATE OR REPLACE VIEW banking_dw.vw_payments_analytics AS
SELECT
    d.full_date                                 AS instruction_date,
    d.calendar_year,
    d.month_name,
    p.payment_type,
    p.payment_status,
    gc.country_name                             AS creditor_country,
    gc.aml_risk_rating                          AS creditor_country_risk,
    br.region_name                              AS debtor_region,
    cu.currency_code,
    COUNT(*)                                    AS payment_count,
    SUM(p.payment_amount_rcy)                   AS total_volume_usd,
    AVG(p.payment_amount_rcy)                   AS avg_payment_usd,
    SUM(p.charge_amount)                        AS total_charges_usd,
    AVG(p.processing_time_seconds)              AS avg_processing_secs,
    ROUND(100.0 * SUM(CASE WHEN p.is_stp      THEN 1 ELSE 0 END) / NULLIF(COUNT(*),0), 2) AS stp_rate_pct,
    ROUND(100.0 * SUM(CASE WHEN p.is_rejected THEN 1 ELSE 0 END) / NULLIF(COUNT(*),0), 2) AS rejection_rate_pct,
    SUM(CASE WHEN p.is_cross_border THEN p.payment_amount_rcy ELSE 0 END) AS cross_border_volume_usd,
    SUM(CASE WHEN p.sanctions_screening_status = 'HIT' THEN 1 ELSE 0 END) AS sanctions_hits
FROM banking_dw.fact_payment_order          p
JOIN banking_dw.dim_date                    d  ON d.date_sk = p.instruction_date_sk
LEFT JOIN banking_dw.dim_geography          gc ON gc.geography_sk = p.creditor_country_sk AND gc.is_current_record
LEFT JOIN banking_dw.dim_branch             br ON br.branch_sk = p.debtor_branch_sk AND br.is_current_record
LEFT JOIN banking_dw.dim_currency           cu ON cu.currency_sk = p.currency_sk
GROUP BY d.full_date, d.calendar_year, d.month_name, p.payment_type,
         p.payment_status, gc.country_name, gc.aml_risk_rating,
         br.region_name, cu.currency_code;

COMMENT ON VIEW banking_dw.vw_payments_analytics IS 'Payments & Liquidity mart view — STP rates, rejection rates, cross-border corridors, sanctions hits.';

-- =============================================================================
--  END OF DDL SCRIPT
--  Next: Run 02_banking_dw_data.sql to load synthesised data
-- =============================================================================
