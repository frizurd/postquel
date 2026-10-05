-- Demo data for trying Postquel: createdb postquel_demo && psql postquel_demo -f scripts/seed-demo.sql
DROP TABLE IF EXISTS orders, customers, tags CASCADE;
DROP SCHEMA IF EXISTS analytics CASCADE;

CREATE TABLE customers (
    id         bigserial PRIMARY KEY,
    uuid       uuid NOT NULL DEFAULT gen_random_uuid(),
    name       text NOT NULL,
    email      text,
    country    text,
    is_active  boolean NOT NULL DEFAULT true,
    balance    numeric(12, 2),
    metadata   jsonb,
    notes      text,
    created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO customers (name, email, country, is_active, balance, metadata, notes, created_at)
SELECT 'Customer ' || g,
       CASE WHEN g % 13 = 0 THEN NULL ELSE 'user' || g || '@example.com' END,
       (ARRAY['ID', 'NL', 'US', 'DE', 'JP', 'SG'])[1 + g % 6],
       g % 7 <> 0,
       round((random() * 10000)::numeric, 2),
       jsonb_build_object('tier', (ARRAY['free', 'pro', 'team'])[1 + g % 3], 'score', g % 100),
       CASE WHEN g % 50 = 0 THEN E'multi-line\nnote for ' || g END,
       now() - (g || ' minutes')::interval
FROM generate_series(1, 100000) g;

CREATE TABLE orders (
    id          bigserial PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customers (id),
    total       numeric(10, 2) NOT NULL,
    status      text NOT NULL,
    placed_at   timestamp NOT NULL
);

INSERT INTO orders (customer_id, total, status, placed_at)
SELECT 1 + (random() * 99999)::int,
       round((random() * 500)::numeric, 2),
       (ARRAY['pending', 'paid', 'shipped', 'refunded'])[1 + g % 4],
       now() - (g || ' seconds')::interval
FROM generate_series(1, 250000) g;

-- No primary key: shows up read-only in the browser.
CREATE TABLE tags (name text, color text);
INSERT INTO tags VALUES ('urgent', 'red'), ('later', 'gray');

CREATE SCHEMA analytics;
CREATE VIEW analytics.revenue_by_country AS
SELECT c.country, count(*) AS orders, sum(o.total) AS revenue
FROM orders o JOIN customers c ON c.id = o.customer_id
GROUP BY c.country;

ANALYZE;
