-- ============================================================
-- FILE: functions/dss_load/schema.sql
-- PURPOSE: Create the database tables
-- ============================================================
-- Run this once when setting up the database.
-- In production use a migration tool like Flyway or Alembic.
-- For portfolio, run manually via Cloud SQL proxy:
-- psql "host=127.0.0.1 dbname=insurance_db user=insurance_app" -f schema.sql
-- ============================================================

-- -----------------------------------
-- POLICIES TABLE
-- -----------------------------------
CREATE TABLE IF NOT EXISTS policies (
    policy_id        VARCHAR(50)    PRIMARY KEY,
    customer_name    VARCHAR(255)   NOT NULL,
    policy_type      VARCHAR(50)    NOT NULL CHECK (policy_type IN ('auto', 'home', 'life', 'health')),
    premium_amount   DECIMAL(10, 2) NOT NULL,
    coverage_amount  DECIMAL(12, 2) NOT NULL,
    start_date       DATE           NOT NULL,
    end_date         DATE           NOT NULL,
    status           VARCHAR(20)    NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'expired', 'cancelled')),
    last_updated     TIMESTAMP      NOT NULL DEFAULT NOW(),
    created_at       TIMESTAMP      NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_policies_status ON policies(status);
CREATE INDEX IF NOT EXISTS idx_policies_customer ON policies(customer_name);

-- -----------------------------------
-- CLAIMS TABLE
-- -----------------------------------
CREATE TABLE IF NOT EXISTS claims (
    claim_id         VARCHAR(50)    PRIMARY KEY,
    policy_id        VARCHAR(50)    NOT NULL REFERENCES policies(policy_id),
    claim_date       DATE           NOT NULL,
    claim_amount     DECIMAL(10, 2) NOT NULL,
    description      TEXT,
    status           VARCHAR(20)    NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'under_review', 'approved', 'denied')),
    last_updated     TIMESTAMP      NOT NULL DEFAULT NOW(),
    created_at       TIMESTAMP      NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_claims_policy_id ON claims(policy_id);
CREATE INDEX IF NOT EXISTS idx_claims_status ON claims(status);
