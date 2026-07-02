-- =====================================================================
-- 01_setup.sql
-- Creates the medallion datasets and the two reference ("seed") tables.
-- Run with:  bq query --use_legacy_sql=false < sql/01_setup.sql
-- Datasets use 2-part names (dataset.table) so nothing is hard-coded to a
-- project id; BigQuery resolves them against the --project_id you pass in.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS raw     OPTIONS (location = 'US');
CREATE SCHEMA IF NOT EXISTS staging OPTIONS (location = 'US');
CREATE SCHEMA IF NOT EXISTS marts   OPTIONS (location = 'US');

-- ---------- FX rates (currency -> USD conversion factor) ----------
-- Static placeholders. In production this becomes a daily table joined on date.
CREATE OR REPLACE TABLE raw.fx_rates (
  currency     STRING,
  usd_per_unit FLOAT64,
  note         STRING
);
INSERT INTO raw.fx_rates (currency, usd_per_unit, note) VALUES
  ('USD', 1.00, 'base currency'),
  ('CAD', 0.73, 'static placeholder; replace with daily rates in prod'),
  ('GBP', 1.27, 'static placeholder; replace with daily rates in prod');

-- ---------- DMA -> region crosswalk (documented assumption) ----------
-- Store visits are per-DMA; campaigns are per-region. There is no source
-- crosswalk, so we define one here (split at the Mississippi). This is the
-- honest join key for relating spend to visits at region grain.
CREATE OR REPLACE TABLE raw.dma_region_map (
  dma_code INT64,
  dma_name STRING,
  region   STRING
);
INSERT INTO raw.dma_region_map (dma_code, dma_name, region) VALUES
  (501, 'New York', 'East'),
  (504, 'Philadelphia', 'East'),
  (505, 'Detroit', 'East'),
  (506, 'Boston', 'East'),
  (511, 'Washington DC', 'East'),
  (524, 'Atlanta', 'East'),
  (528, 'Miami-Ft. Lauderdale', 'East'),
  (539, 'Tampa-St. Petersburg', 'East'),
  (602, 'Chicago', 'East'),
  (618, 'Houston', 'West'),
  (623, 'Dallas-Ft. Worth', 'West'),
  (753, 'Phoenix', 'West'),
  (803, 'Los Angeles', 'West'),
  (807, 'San Francisco-Oakland-San Jose', 'West'),
  (819, 'Seattle-Tacoma', 'West');
