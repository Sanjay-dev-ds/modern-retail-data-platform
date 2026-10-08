-- One-off: add refund payments for voided/returned sales seeded before refunds existed.
-- One negative payment per original tender, dated when the sale was voided/returned.
-- Idempotent (skips sales that already have a refund). DMS replicates the inserts (Op = I).
-- Run on the platform host:  bash /opt/retail/scripts/init_db.sh /opt/retail/sql/pos/02_backfill_refunds.sql
INSERT INTO pos.payments (payment_id, transaction_id, method, amount, created_at)
SELECT gen_random_uuid(), p.transaction_id, p.method, -p.amount, t.updated_at
FROM pos.payments p
JOIN pos.transactions t ON t.transaction_id = p.transaction_id
WHERE t.status IN ('voided', 'returned')
  AND p.amount > 0
  AND NOT EXISTS (
    SELECT 1 FROM pos.payments r WHERE r.transaction_id = p.transaction_id AND r.amount < 0
  );
