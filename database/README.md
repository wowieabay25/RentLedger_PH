# Database – Rental Property Monitoring System

## Files

| File | Purpose |
|---|---|
| `schema.sql` | All tables, enums, indexes, and triggers |
| `seed.sql` | Sample data for development/testing |
| `views.sql` | Reporting views (dashboard, aging, occupancy, etc.) |

## Entity Relationship Overview

```
users
  └── creates → properties, units, tenants, leases, billings, payments, tickets

properties
  └── has many → units

units
  └── has many → leases (one active at a time, enforced by exclusion constraint)
  └── has many → utility_readings
  └── has many → maintenance_tickets

tenants
  └── has many → leases
  └── has many → deposits
  └── has many → billings
  └── has many → payments

leases
  └── has many → billings (one per billing_period, unique constraint)
  └── has many → deposits

billings
  └── has many → billing_items   (rent, water, electricity, parking, etc.)
  └── has many → payments
  └── has many → utility_readings

payments
  └── has many → payment_allocations → billing_items

deposits
  └── has many → deposit_transactions
```

## Key Constraints & Automation

| Mechanism | What it does |
|---|---|
| Exclusion constraint on `leases` | Prevents overlapping active leases on the same unit |
| Unique on `(lease_id, billing_period)` | One bill per tenant per month |
| Unique on `(unit_id, utility_type, billing_period)` | One utility reading per type per month |
| `sync_billing_total` trigger | Keeps `billings.total_amount` in sync with `billing_items` |
| `sync_billing_paid` trigger | Keeps `billings.total_paid` and `status` in sync with `payments` |
| `sync_unit_status` trigger | Sets unit to occupied/vacant when lease status changes |
| Generated column `billings.balance` | Always equals `total_amount – total_paid` |
| Generated columns on `utility_readings` | Auto-computes `consumption` and `amount` |

## Running Locally (Supabase / PostgreSQL)

```bash
# Apply schema
psql -d your_db -f schema.sql

# Load views
psql -d your_db -f views.sql

# Load sample data
psql -d your_db -f seed.sql
```

## Reporting Views

| View | Used for |
|---|---|
| `vw_dashboard` | Dashboard KPI cards |
| `vw_tenant_ledger` | Tenant billing history |
| `vw_ar_aging` | Accounts receivable aging buckets |
| `vw_occupancy` | Occupancy rate per property |
| `vw_lease_expiry` | Expiring / expired lease alerts |
| `vw_income_per_property` | Revenue per property (current month) |
| `vw_deposit_liability` | Outstanding deposit obligations |
| `vw_monthly_collection` | Payments collected by month and method |
