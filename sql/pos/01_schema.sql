-- POS / orders source schema (system of record for in-store and online sales).
-- Replicated to S3 by DMS (full load + CDC). Rules that follow from that:
--   * Every table has a primary key (DMS CDC requires one).
--   * updated_at is maintained by the application (the generator), not by triggers.
--   * Value checks (quantity > 0, price > 0, ...) are intentionally NOT enforced: the generator
--     injects invalid values that the dbt tests downstream must catch. See docs/source-contracts.md.
CREATE SCHEMA IF NOT EXISTS pos;

-- One row per physical store, plus store_id 0 = 'Online' for web/app orders.
-- format/region change rarely -> SCD2 dimension downstream.
CREATE TABLE pos.stores (
  store_id    INT PRIMARY KEY,
  store_name  TEXT        NOT NULL,
  region      TEXT        NOT NULL,            -- north, south, east, west, online
  format      TEXT        NOT NULL,            -- hyper, express, outlet, online
  open_date   DATE        NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Loyalty-registered customers. Anonymous shoppers have no row here.
-- loyalty_tier changes over time -> SCD2 dimension downstream. email/phone are PII.
CREATE TABLE pos.customers (
  customer_id   BIGINT PRIMARY KEY,
  email         TEXT,                          -- nullable: some sign-ups skip it (defect: null_values)
  phone         TEXT,
  loyalty_tier  TEXT        NOT NULL,          -- bronze, silver, gold
  home_store_id INT         NOT NULL REFERENCES pos.stores (store_id),
  signup_at     TIMESTAMPTZ NOT NULL,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Order header: one row per sale. Grain: transaction.
-- status moves completed -> voided (minutes later) or completed -> returned (days later).
CREATE TABLE pos.transactions (
  transaction_id UUID PRIMARY KEY,
  store_id       INT            NOT NULL REFERENCES pos.stores (store_id),
  customer_id    BIGINT         REFERENCES pos.customers (customer_id),  -- null = anonymous
  channel        TEXT           NOT NULL,      -- store, online (online <=> store_id = 0)
  txn_ts         TIMESTAMPTZ    NOT NULL,      -- business time of the sale
  status         TEXT           NOT NULL,      -- completed, voided, returned
  total_amount   NUMERIC(12, 2) NOT NULL,      -- sum of lines net of discount
  currency       CHAR(3)        NOT NULL DEFAULT 'USD',
  created_at     TIMESTAMPTZ    NOT NULL DEFAULT now(),  -- insert time (history rows: backdated)
  updated_at     TIMESTAMPTZ    NOT NULL DEFAULT now()
);

-- Order lines. Grain: one product on one transaction. This is the sales fact grain.
CREATE TABLE pos.transaction_lines (
  transaction_id  UUID           NOT NULL REFERENCES pos.transactions (transaction_id),
  line_no         INT            NOT NULL,
  sku             TEXT           NOT NULL,     -- no FK on purpose: SKUs come from the catalog file
                                               -- and orphan SKUs are an injected defect
  quantity        INT            NOT NULL,
  unit_price      NUMERIC(10, 2) NOT NULL,     -- price charged, may differ from catalog list_price
  discount_amount NUMERIC(10, 2) NOT NULL DEFAULT 0,
  promo_code      TEXT,
  PRIMARY KEY (transaction_id, line_no)
);

-- Tenders. Grain: one payment; ~5% of transactions are split across methods, so joining this
-- table to transaction_lines fans out (double counts) -- model it as its own fact.
CREATE TABLE pos.payments (
  payment_id     UUID PRIMARY KEY,
  transaction_id UUID           NOT NULL REFERENCES pos.transactions (transaction_id),
  method         TEXT           NOT NULL,      -- card, cash, wallet, gift_card
  amount         NUMERIC(12, 2) NOT NULL,
  created_at     TIMESTAMPTZ    NOT NULL DEFAULT now()
);
