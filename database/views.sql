-- ============================================================
-- Reporting Views – Rental Property Monitoring System
-- ============================================================

-- -------------------------------------------------------
-- Dashboard Summary
-- -------------------------------------------------------
CREATE OR REPLACE VIEW vw_dashboard AS
SELECT
  (SELECT COUNT(*) FROM properties)                                          AS total_properties,
  (SELECT COUNT(*) FROM units)                                               AS total_units,
  (SELECT COUNT(*) FROM units WHERE status = 'occupied')                     AS occupied_units,
  (SELECT COUNT(*) FROM units WHERE status = 'vacant')                       AS vacant_units,
  (SELECT COUNT(*) FROM units WHERE status = 'repair')                       AS units_in_repair,
  (SELECT COALESCE(SUM(total_amount), 0) FROM billings
   WHERE billing_period = date_trunc('month', NOW()))                        AS monthly_billed,
  (SELECT COALESCE(SUM(total_paid), 0) FROM billings
   WHERE billing_period = date_trunc('month', NOW()))                        AS monthly_collected,
  (SELECT COALESCE(SUM(balance), 0) FROM billings
   WHERE status IN ('issued','partially_paid','overdue'))                    AS outstanding_balance,
  (SELECT COUNT(*) FROM billings WHERE status = 'overdue')                   AS overdue_count,
  (SELECT COUNT(*) FROM leases
   WHERE status = 'active'
     AND end_date BETWEEN NOW() AND NOW() + INTERVAL '30 days')             AS expiring_in_30_days,
  (SELECT COUNT(*) FROM maintenance_tickets
   WHERE status IN ('open','in_progress'))                                   AS open_tickets;

-- -------------------------------------------------------
-- Tenant Ledger (full billing + payment history per tenant)
-- -------------------------------------------------------
CREATE OR REPLACE VIEW vw_tenant_ledger AS
SELECT
  t.id           AS tenant_id,
  t.full_name    AS tenant_name,
  u.unit_number,
  p.name         AS property_name,
  b.billing_period,
  b.due_date,
  b.total_amount,
  b.total_paid,
  b.balance,
  b.status       AS billing_status
FROM billings b
JOIN tenants   t ON t.id = b.tenant_id
JOIN units     u ON u.id = b.unit_id
JOIN properties p ON p.id = u.property_id
ORDER BY t.full_name, b.billing_period;

-- -------------------------------------------------------
-- AR Aging Report
-- -------------------------------------------------------
CREATE OR REPLACE VIEW vw_ar_aging AS
SELECT
  t.id                                        AS tenant_id,
  t.full_name                                 AS tenant_name,
  u.unit_number,
  p.name                                      AS property_name,
  COALESCE(SUM(CASE
    WHEN NOW()::DATE - b.due_date <= 0 THEN b.balance END), 0) AS current_due,
  COALESCE(SUM(CASE
    WHEN NOW()::DATE - b.due_date BETWEEN 1  AND 30  THEN b.balance END), 0) AS days_1_30,
  COALESCE(SUM(CASE
    WHEN NOW()::DATE - b.due_date BETWEEN 31 AND 60  THEN b.balance END), 0) AS days_31_60,
  COALESCE(SUM(CASE
    WHEN NOW()::DATE - b.due_date > 60             THEN b.balance END), 0) AS days_61_plus,
  COALESCE(SUM(b.balance), 0)                 AS total_outstanding
FROM billings b
JOIN tenants    t ON t.id = b.tenant_id
JOIN units      u ON u.id = b.unit_id
JOIN properties p ON p.id = u.property_id
WHERE b.status IN ('issued','partially_paid','overdue')
  AND b.balance > 0
GROUP BY t.id, t.full_name, u.unit_number, p.name
ORDER BY total_outstanding DESC;

-- -------------------------------------------------------
-- Occupancy Report per Property
-- -------------------------------------------------------
CREATE OR REPLACE VIEW vw_occupancy AS
SELECT
  p.id                                AS property_id,
  p.name                              AS property_name,
  COUNT(u.id)                         AS total_units,
  SUM(CASE WHEN u.status = 'occupied' THEN 1 ELSE 0 END) AS occupied,
  SUM(CASE WHEN u.status = 'vacant'   THEN 1 ELSE 0 END) AS vacant,
  SUM(CASE WHEN u.status = 'repair'   THEN 1 ELSE 0 END) AS in_repair,
  ROUND(
    100.0 * SUM(CASE WHEN u.status = 'occupied' THEN 1 ELSE 0 END)
    / NULLIF(COUNT(u.id), 0), 2
  )                                   AS occupancy_rate_pct
FROM properties p
LEFT JOIN units u ON u.property_id = p.id
GROUP BY p.id, p.name
ORDER BY p.name;

-- -------------------------------------------------------
-- Lease Expiry Alerts
-- -------------------------------------------------------
CREATE OR REPLACE VIEW vw_lease_expiry AS
SELECT
  l.id           AS lease_id,
  t.full_name    AS tenant_name,
  t.phone        AS tenant_phone,
  u.unit_number,
  p.name         AS property_name,
  l.start_date,
  l.end_date,
  l.end_date - NOW()::DATE AS days_remaining,
  CASE
    WHEN l.end_date < NOW()::DATE         THEN 'Expired'
    WHEN l.end_date <= NOW()::DATE + 30   THEN 'Expiring Soon'
    ELSE 'Active'
  END            AS expiry_status
FROM leases l
JOIN tenants    t ON t.id = l.tenant_id
JOIN units      u ON u.id = l.unit_id
JOIN properties p ON p.id = u.property_id
WHERE l.status = 'active'
ORDER BY l.end_date;

-- -------------------------------------------------------
-- Income per Property (current month)
-- -------------------------------------------------------
CREATE OR REPLACE VIEW vw_income_per_property AS
SELECT
  p.id                             AS property_id,
  p.name                           AS property_name,
  date_trunc('month', NOW())       AS period,
  COALESCE(SUM(b.total_amount), 0) AS total_billed,
  COALESCE(SUM(b.total_paid),   0) AS total_collected,
  COALESCE(SUM(b.balance),      0) AS total_outstanding
FROM properties p
LEFT JOIN units    u ON u.property_id = p.id
LEFT JOIN billings b ON b.unit_id = u.id
  AND b.billing_period = date_trunc('month', NOW())
GROUP BY p.id, p.name
ORDER BY total_collected DESC;

-- -------------------------------------------------------
-- Deposit Liability Summary (what is owed back to tenants)
-- -------------------------------------------------------
CREATE OR REPLACE VIEW vw_deposit_liability AS
SELECT
  t.id           AS tenant_id,
  t.full_name    AS tenant_name,
  u.unit_number,
  p.name         AS property_name,
  d.type         AS deposit_type,
  d.amount       AS original_amount,
  d.balance      AS current_balance
FROM deposits d
JOIN tenants    t ON t.id = d.tenant_id
JOIN leases     l ON l.id = d.lease_id
JOIN units      u ON u.id = l.unit_id
JOIN properties p ON p.id = u.property_id
WHERE l.status = 'active'
ORDER BY p.name, t.full_name;

-- -------------------------------------------------------
-- Monthly Collection Summary
-- -------------------------------------------------------
CREATE OR REPLACE VIEW vw_monthly_collection AS
SELECT
  date_trunc('month', py.payment_date)  AS month,
  py.method                             AS payment_method,
  COUNT(py.id)                          AS transaction_count,
  SUM(py.amount)                        AS total_collected
FROM payments py
GROUP BY date_trunc('month', py.payment_date), py.method
ORDER BY month DESC, total_collected DESC;
