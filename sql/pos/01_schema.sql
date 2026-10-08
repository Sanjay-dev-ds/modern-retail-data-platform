-- POS source schema. Every table has a primary key (required for DMS CDC).
CREATE SCHEMA IF NOT EXISTS pos;

CREATE TABLE pos.stores (
  store_id    INT PRIMARY KEY,
  store_name  TEXT        NOT NULL,
  region      TEXT        NOT NULL,
  format      TEXT        NOT NULL,            -- hyper, express, outlet
  open_date   DATE        NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE pos.registers (
  register_id INT PRIMARY KEY,
  store_id    INT  NOT NULL REFERENCES pos.stores (store_id),
  status      TEXT NOT NULL
);

CREATE TABLE pos.loyalty_members (
  loyalty_id  BIGINT PRIMARY KEY,
  customer_id BIGINT,                          -- nullable on purpose (partial linkage)
  tier        TEXT        NOT NULL,
  email       TEXT,
  phone       TEXT,
  joined_at   TIMESTAMPTZ NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE pos.transactions (
  transaction_id UUID PRIMARY KEY,
  store_id       INT         NOT NULL REFERENCES pos.stores (store_id),
  register_id    INT         NOT NULL REFERENCES pos.registers (register_id),
  loyalty_id     BIGINT,
  txn_ts         TIMESTAMPTZ NOT NULL,
  status         TEXT        NOT NULL,         -- completed, voided, returned
  total_amount   NUMERIC(12, 2) NOT NULL,
  currency       CHAR(3)     NOT NULL DEFAULT 'USD',
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE pos.transaction_lines (
  transaction_id  UUID           NOT NULL REFERENCES pos.transactions (transaction_id),
  line_no         INT            NOT NULL,
  sku             TEXT           NOT NULL,     -- no FK on purpose (orphan SKU defects)
  quantity        INT            NOT NULL,
  unit_price      NUMERIC(10, 2) NOT NULL,
  discount_amount NUMERIC(10, 2) NOT NULL DEFAULT 0,
  promo_id        TEXT,
  PRIMARY KEY (transaction_id, line_no)
);

CREATE TABLE pos.payments (
  payment_id     UUID PRIMARY KEY,
  transaction_id UUID           NOT NULL REFERENCES pos.transactions (transaction_id),
  method         TEXT           NOT NULL,      -- card, cash, wallet
  amount         NUMERIC(12, 2) NOT NULL,
  card_token     TEXT                          -- tokenized, never real PANs
);
