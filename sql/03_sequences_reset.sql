-- =============================================================================
--  03_sequences_reset.sql
--  Resets all SERIAL/BIGSERIAL sequences after explicit integer PK inserts.
--  This prevents "duplicate key" errors when new rows are inserted after load.
--  Uses pg_get_serial_sequence() for robustness — works regardless of 
--  auto-generated sequence name conventions.
-- =============================================================================

SET search_path TO banking_dw, banking_ref, public;

-- ── Reference / Lookup sequences ─────────────────────────────────────────────

SELECT setval(
    pg_get_serial_sequence('banking_dw.dim_geography', 'geography_sk'),
    COALESCE((SELECT MAX(geography_sk) FROM banking_dw.dim_geography), 0) + 1,
    false
);

SELECT setval(
    pg_get_serial_sequence('banking_dw.dim_currency', 'currency_sk'),
    COALESCE((SELECT MAX(currency_sk) FROM banking_dw.dim_currency), 0) + 1,
    false
);

-- ── Conformed Dimension sequences ─────────────────────────────────────────────

SELECT setval(
    pg_get_serial_sequence('banking_dw.dim_customer', 'customer_sk'),
    COALESCE((SELECT MAX(customer_sk) FROM banking_dw.dim_customer), 0) + 1,
    false
);

SELECT setval(
    pg_get_serial_sequence('banking_dw.dim_product', 'product_sk'),
    COALESCE((SELECT MAX(product_sk) FROM banking_dw.dim_product), 0) + 1,
    false
);

SELECT setval(
    pg_get_serial_sequence('banking_dw.dim_branch', 'branch_sk'),
    COALESCE((SELECT MAX(branch_sk) FROM banking_dw.dim_branch), 0) + 1,
    false
);

SELECT setval(
    pg_get_serial_sequence('banking_dw.dim_employee', 'employee_sk'),
    COALESCE((SELECT MAX(employee_sk) FROM banking_dw.dim_employee), 0) + 1,
    false
);

SELECT setval(
    pg_get_serial_sequence('banking_dw.dim_account', 'account_sk'),
    COALESCE((SELECT MAX(account_sk) FROM banking_dw.dim_account), 0) + 1,
    false
);

-- ── Subject Dimension sequences ───────────────────────────────────────────────

SELECT setval(
    pg_get_serial_sequence('banking_dw.dim_gl_account', 'gl_account_sk'),
    COALESCE((SELECT MAX(gl_account_sk) FROM banking_dw.dim_gl_account), 0) + 1,
    false
);

SELECT setval(
    pg_get_serial_sequence('banking_dw.dim_collateral', 'collateral_sk'),
    COALESCE((SELECT MAX(collateral_sk) FROM banking_dw.dim_collateral), 0) + 1,
    false
);

SELECT setval(
    pg_get_serial_sequence('banking_dw.dim_aml_rule', 'aml_rule_sk'),
    COALESCE((SELECT MAX(aml_rule_sk) FROM banking_dw.dim_aml_rule), 0) + 1,
    false
);

-- ── Bridge Table sequences ────────────────────────────────────────────────────

SELECT setval(
    pg_get_serial_sequence('banking_dw.bridge_account_customer', 'bridge_account_customer_sk'),
    COALESCE((SELECT MAX(bridge_account_customer_sk) FROM banking_dw.bridge_account_customer), 0) + 1,
    false
);

SELECT setval(
    pg_get_serial_sequence('banking_dw.bridge_loan_collateral', 'bridge_loan_collateral_sk'),
    COALESCE((SELECT MAX(bridge_loan_collateral_sk) FROM banking_dw.bridge_loan_collateral), 0) + 1,
    false
);

-- ── Fact Table sequences ──────────────────────────────────────────────────────

-- fact_transaction uses an explicit named sequence (not BIGSERIAL) because
-- PostgreSQL partitioned tables cannot use BIGSERIAL directly.
SELECT setval(
    'banking_dw.fact_transaction_transaction_sk_seq',
    COALESCE((SELECT MAX(transaction_sk) FROM banking_dw.fact_transaction), 0) + 1,
    false
);

SELECT setval(
    pg_get_serial_sequence('banking_dw.fact_account_balance_daily', 'balance_snapshot_sk'),
    COALESCE((SELECT MAX(balance_snapshot_sk) FROM banking_dw.fact_account_balance_daily), 0) + 1,
    false
);

SELECT setval(
    pg_get_serial_sequence('banking_dw.fact_loan_daily_snapshot', 'loan_snapshot_sk'),
    COALESCE((SELECT MAX(loan_snapshot_sk) FROM banking_dw.fact_loan_daily_snapshot), 0) + 1,
    false
);

SELECT setval(
    pg_get_serial_sequence('banking_dw.fact_payment_order', 'payment_order_sk'),
    COALESCE((SELECT MAX(payment_order_sk) FROM banking_dw.fact_payment_order), 0) + 1,
    false
);

SELECT setval(
    pg_get_serial_sequence('banking_dw.fact_aml_alert', 'aml_alert_sk'),
    COALESCE((SELECT MAX(aml_alert_sk) FROM banking_dw.fact_aml_alert), 0) + 1,
    false
);

SELECT setval(
    pg_get_serial_sequence('banking_dw.fact_gl_balance', 'gl_balance_sk'),
    COALESCE((SELECT MAX(gl_balance_sk) FROM banking_dw.fact_gl_balance), 0) + 1,
    false
);

-- ── Verification: print all current sequence values ───────────────────────────
SELECT
    schemaname,
    sequencename,
    last_value
FROM pg_sequences
WHERE schemaname = 'banking_dw'
ORDER BY sequencename;

-- =============================================================================
--  Sequence reset complete. All auto-increment columns are now safe for
--  new INSERT operations without explicit PK values.
-- =============================================================================
