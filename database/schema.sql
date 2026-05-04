-- ============================================================
-- Rental Property Monitoring System – Database Schema
-- PostgreSQL
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- ENUMS
-- ============================================================

CREATE TYPE user_role AS ENUM ('admin', 'manager', 'staff');

CREATE TYPE property_type AS ENUM (
  'apartment', 'boarding_house', 'condo', 'commercial', 'house', 'other'
);

CREATE TYPE unit_status AS ENUM ('vacant', 'occupied', 'repair');

CREATE TYPE lease_status AS ENUM ('active', 'expired', 'terminated', 'pending');

CREATE TYPE billing_status AS ENUM (
  'draft', 'issued', 'partially_paid', 'paid', 'overdue'
);

CREATE TYPE billing_item_type AS ENUM (
  'rent', 'water', 'electricity', 'parking', 'internet', 'penalty', 'other'
);

CREATE TYPE payment_method AS ENUM (
  'cash', 'gcash', 'maya', 'bank_transfer', 'check'
);

CREATE TYPE deposit_type AS ENUM (
  'security', 'advance_rent', 'utility', 'other'
);

CREATE TYPE deposit_txn_type AS ENUM (
  'received', 'applied', 'refunded', 'forfeited', 'adjusted'
);

CREATE TYPE ticket_status AS ENUM (
  'open', 'in_progress', 'completed', 'cancelled'
);

CREATE TYPE ticket_priority AS ENUM ('low', 'medium', 'high', 'urgent');

-- ============================================================
-- 1. USERS
-- ============================================================

CREATE TABLE users (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  full_name      VARCHAR(150)        NOT NULL,
  email          VARCHAR(255) UNIQUE NOT NULL,
  password_hash  TEXT                NOT NULL,
  role           user_role           NOT NULL DEFAULT 'staff',
  phone          VARCHAR(30),
  is_active      BOOLEAN             NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 2. PROPERTIES
-- ============================================================

CREATE TABLE properties (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name           VARCHAR(200)  NOT NULL,
  address        TEXT          NOT NULL,
  type           property_type NOT NULL DEFAULT 'apartment',
  owner_name     VARCHAR(150),
  owner_contact  VARCHAR(30),
  notes          TEXT,
  created_by     UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 3. UNITS
-- ============================================================

CREATE TABLE units (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  property_id    UUID          NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  unit_number    VARCHAR(50)   NOT NULL,
  floor          VARCHAR(20),
  monthly_rent   NUMERIC(12,2) NOT NULL DEFAULT 0,
  status         unit_status   NOT NULL DEFAULT 'vacant',
  description    TEXT,
  created_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  UNIQUE (property_id, unit_number)
);

-- ============================================================
-- 4. TENANTS
-- ============================================================

CREATE TABLE tenants (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  full_name       VARCHAR(150) NOT NULL,
  phone           VARCHAR(30),
  email           VARCHAR(255),
  id_type         VARCHAR(60),   -- e.g. "Driver's License", "Passport"
  id_number       VARCHAR(100),
  emergency_name  VARCHAR(150),
  emergency_phone VARCHAR(30),
  notes           TEXT,
  is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
  created_by      UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 5. LEASES
-- ============================================================

CREATE TABLE leases (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id           UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  unit_id             UUID          NOT NULL REFERENCES units(id) ON DELETE RESTRICT,
  start_date          DATE          NOT NULL,
  end_date            DATE          NOT NULL,
  monthly_rent        NUMERIC(12,2) NOT NULL,
  due_day             SMALLINT      NOT NULL DEFAULT 1 CHECK (due_day BETWEEN 1 AND 31),
  grace_period_days   SMALLINT      NOT NULL DEFAULT 0,
  penalty_type        VARCHAR(20)   NOT NULL DEFAULT 'fixed' CHECK (penalty_type IN ('fixed','percent')),
  penalty_value       NUMERIC(10,2) NOT NULL DEFAULT 0,
  status              lease_status  NOT NULL DEFAULT 'active',
  renewal_notes       TEXT,
  created_by          UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  -- Only one active lease per unit at a time
  EXCLUDE USING gist (
    unit_id WITH =,
    daterange(start_date, end_date, '[]') WITH &&
  ) WHERE (status = 'active')
);

-- ============================================================
-- 6. DEPOSITS
-- ============================================================

CREATE TABLE deposits (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  lease_id      UUID          NOT NULL REFERENCES leases(id) ON DELETE RESTRICT,
  tenant_id     UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  type          deposit_type  NOT NULL,
  amount        NUMERIC(12,2) NOT NULL DEFAULT 0,
  balance       NUMERIC(12,2) NOT NULL DEFAULT 0,  -- running balance
  notes         TEXT,
  created_by    UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE TABLE deposit_transactions (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  deposit_id    UUID              NOT NULL REFERENCES deposits(id) ON DELETE CASCADE,
  txn_type      deposit_txn_type  NOT NULL,
  amount        NUMERIC(12,2)     NOT NULL,
  balance_after NUMERIC(12,2)     NOT NULL,
  reference     VARCHAR(200),       -- billing_id or payment_id if applied
  notes         TEXT,
  created_by    UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ        NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 7. BILLINGS
-- ============================================================

CREATE TABLE billings (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  lease_id        UUID            NOT NULL REFERENCES leases(id) ON DELETE RESTRICT,
  tenant_id       UUID            NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  unit_id         UUID            NOT NULL REFERENCES units(id) ON DELETE RESTRICT,
  billing_period  DATE            NOT NULL,   -- first day of the billing month
  due_date        DATE            NOT NULL,
  total_amount    NUMERIC(12,2)   NOT NULL DEFAULT 0,
  total_paid      NUMERIC(12,2)   NOT NULL DEFAULT 0,
  balance         NUMERIC(12,2)   GENERATED ALWAYS AS (total_amount - total_paid) STORED,
  status          billing_status  NOT NULL DEFAULT 'draft',
  notes           TEXT,
  issued_at       TIMESTAMPTZ,
  created_by      UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

  UNIQUE (lease_id, billing_period)
);

CREATE TABLE billing_items (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  billing_id    UUID               NOT NULL REFERENCES billings(id) ON DELETE CASCADE,
  item_type     billing_item_type  NOT NULL,
  description   VARCHAR(255),
  quantity      NUMERIC(10,4)      NOT NULL DEFAULT 1,
  unit_price    NUMERIC(12,2)      NOT NULL DEFAULT 0,
  amount        NUMERIC(12,2)      NOT NULL DEFAULT 0,  -- quantity × unit_price
  created_at    TIMESTAMPTZ        NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 8. UTILITY READINGS
-- ============================================================

CREATE TABLE utility_readings (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  billing_id       UUID          REFERENCES billings(id) ON DELETE SET NULL,
  unit_id          UUID          NOT NULL REFERENCES units(id) ON DELETE CASCADE,
  utility_type     VARCHAR(30)   NOT NULL CHECK (utility_type IN ('water','electricity')),
  billing_period   DATE          NOT NULL,
  previous_reading NUMERIC(12,4) NOT NULL DEFAULT 0,
  current_reading  NUMERIC(12,4) NOT NULL DEFAULT 0,
  consumption      NUMERIC(12,4) GENERATED ALWAYS AS (current_reading - previous_reading) STORED,
  rate             NUMERIC(10,4) NOT NULL DEFAULT 0,
  amount           NUMERIC(12,2) GENERATED ALWAYS AS (
                     ROUND((current_reading - previous_reading) * rate, 2)
                   ) STORED,
  notes            TEXT,
  read_by          UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  UNIQUE (unit_id, utility_type, billing_period)
);

-- ============================================================
-- 9. PAYMENTS
-- ============================================================

CREATE TABLE payments (
  id             UUID           PRIMARY KEY DEFAULT uuid_generate_v4(),
  billing_id     UUID           NOT NULL REFERENCES billings(id) ON DELETE RESTRICT,
  tenant_id      UUID           NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  amount         NUMERIC(12,2)  NOT NULL,
  method         payment_method NOT NULL,
  reference_no   VARCHAR(150),   -- GCash ref, check no., bank trace, etc.
  payment_date   DATE           NOT NULL DEFAULT CURRENT_DATE,
  notes          TEXT,
  received_by    UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at     TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- Tracks which billing items a payment covers (supports partial/multi-source)
CREATE TABLE payment_allocations (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  payment_id      UUID          NOT NULL REFERENCES payments(id) ON DELETE CASCADE,
  billing_item_id UUID          NOT NULL REFERENCES billing_items(id) ON DELETE CASCADE,
  allocated_amount NUMERIC(12,2) NOT NULL,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- ============================================================
-- 10. MAINTENANCE TICKETS
-- ============================================================

CREATE TABLE maintenance_tickets (
  id            UUID           PRIMARY KEY DEFAULT uuid_generate_v4(),
  unit_id       UUID           NOT NULL REFERENCES units(id) ON DELETE CASCADE,
  tenant_id     UUID           REFERENCES tenants(id) ON DELETE SET NULL,
  title         VARCHAR(255)   NOT NULL,
  description   TEXT,
  priority      ticket_priority NOT NULL DEFAULT 'medium',
  status        ticket_status  NOT NULL DEFAULT 'open',
  reported_date DATE           NOT NULL DEFAULT CURRENT_DATE,
  resolved_date DATE,
  cost          NUMERIC(12,2),
  assigned_to   VARCHAR(150),
  notes         TEXT,
  created_by    UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- ============================================================
-- INDEXES
-- ============================================================

-- Properties & Units
CREATE INDEX idx_units_property       ON units(property_id);
CREATE INDEX idx_units_status         ON units(status);

-- Leases
CREATE INDEX idx_leases_tenant        ON leases(tenant_id);
CREATE INDEX idx_leases_unit          ON leases(unit_id);
CREATE INDEX idx_leases_status        ON leases(status);
CREATE INDEX idx_leases_end_date      ON leases(end_date);           -- expiry alerts

-- Billings
CREATE INDEX idx_billings_lease       ON billings(lease_id);
CREATE INDEX idx_billings_tenant      ON billings(tenant_id);
CREATE INDEX idx_billings_unit        ON billings(unit_id);
CREATE INDEX idx_billings_status      ON billings(status);
CREATE INDEX idx_billings_due_date    ON billings(due_date);         -- overdue queries
CREATE INDEX idx_billings_period      ON billings(billing_period);

-- Billing Items
CREATE INDEX idx_billing_items_billing ON billing_items(billing_id);

-- Payments
CREATE INDEX idx_payments_billing     ON payments(billing_id);
CREATE INDEX idx_payments_tenant      ON payments(tenant_id);
CREATE INDEX idx_payments_date        ON payments(payment_date);

-- Deposits
CREATE INDEX idx_deposits_lease       ON deposits(lease_id);
CREATE INDEX idx_deposits_tenant      ON deposits(tenant_id);
CREATE INDEX idx_deposit_txns_deposit ON deposit_transactions(deposit_id);

-- Utility Readings
CREATE INDEX idx_utility_unit         ON utility_readings(unit_id);
CREATE INDEX idx_utility_period       ON utility_readings(billing_period);

-- Maintenance
CREATE INDEX idx_tickets_unit         ON maintenance_tickets(unit_id);
CREATE INDEX idx_tickets_status       ON maintenance_tickets(status);

-- ============================================================
-- TRIGGERS — auto-update updated_at
-- ============================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_properties_updated_at
  BEFORE UPDATE ON properties
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_units_updated_at
  BEFORE UPDATE ON units
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_tenants_updated_at
  BEFORE UPDATE ON tenants
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_leases_updated_at
  BEFORE UPDATE ON leases
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_deposits_updated_at
  BEFORE UPDATE ON deposits
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_billings_updated_at
  BEFORE UPDATE ON billings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_tickets_updated_at
  BEFORE UPDATE ON maintenance_tickets
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- TRIGGER — sync billing total_amount from items
-- ============================================================

CREATE OR REPLACE FUNCTION sync_billing_total()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  UPDATE billings
  SET total_amount = (
    SELECT COALESCE(SUM(amount), 0)
    FROM billing_items
    WHERE billing_id = COALESCE(NEW.billing_id, OLD.billing_id)
  ),
  updated_at = NOW()
  WHERE id = COALESCE(NEW.billing_id, OLD.billing_id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_billing_items_sync
  AFTER INSERT OR UPDATE OR DELETE ON billing_items
  FOR EACH ROW EXECUTE FUNCTION sync_billing_total();

-- ============================================================
-- TRIGGER — sync billing total_paid and status from payments
-- ============================================================

CREATE OR REPLACE FUNCTION sync_billing_paid()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_billing_id UUID;
  v_total      NUMERIC(12,2);
  v_paid       NUMERIC(12,2);
  v_status     billing_status;
BEGIN
  v_billing_id := COALESCE(NEW.billing_id, OLD.billing_id);

  SELECT total_amount INTO v_total FROM billings WHERE id = v_billing_id;

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM payments WHERE billing_id = v_billing_id;

  IF v_paid = 0 THEN
    v_status := 'issued';
  ELSIF v_paid >= v_total THEN
    v_status := 'paid';
  ELSE
    v_status := 'partially_paid';
  END IF;

  UPDATE billings
  SET total_paid = v_paid,
      status     = v_status,
      updated_at = NOW()
  WHERE id = v_billing_id;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_sync
  AFTER INSERT OR UPDATE OR DELETE ON payments
  FOR EACH ROW EXECUTE FUNCTION sync_billing_paid();

-- ============================================================
-- TRIGGER — update unit status when lease changes
-- ============================================================

CREATE OR REPLACE FUNCTION sync_unit_status()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'active' THEN
    UPDATE units SET status = 'occupied', updated_at = NOW()
    WHERE id = NEW.unit_id;
  ELSIF NEW.status IN ('expired','terminated') THEN
    -- Only set vacant if no other active lease exists
    IF NOT EXISTS (
      SELECT 1 FROM leases
      WHERE unit_id = NEW.unit_id AND status = 'active' AND id <> NEW.id
    ) THEN
      UPDATE units SET status = 'vacant', updated_at = NOW()
      WHERE id = NEW.unit_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_lease_unit_status
  AFTER INSERT OR UPDATE OF status ON leases
  FOR EACH ROW EXECUTE FUNCTION sync_unit_status();
