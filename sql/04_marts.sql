-- =====================================================================
-- 04_marts.sql
-- The star schema. Tables (not views) so the dashboard queries are fast.
-- Partitioned by date and clustered by the common filter keys.
-- =====================================================================

-- ---------- dim_campaign ----------
-- Grain: one row per campaign_id.
-- Resolves the mid-flight rename (campaign 1090) by taking the most recent
-- name seen across both platforms as canonical.
CREATE OR REPLACE TABLE marts.dim_campaign AS
WITH names AS (
  SELECT campaign_id, date_day, campaign_name_raw FROM staging.stg_meta_ads
  UNION ALL
  SELECT campaign_id, date_day, campaign_name_raw FROM staging.stg_google_ads
),
ranked AS (
  SELECT
    campaign_id,
    campaign_name_raw AS campaign_name,
    ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY date_day DESC) AS rn
  FROM names
),
latest AS (
  SELECT campaign_id, campaign_name FROM ranked WHERE rn = 1
)
SELECT
  m.campaign_id,
  l.campaign_name,
  m.brand,
  m.product_line,
  m.region,
  m.campaign_start_date,
  m.campaign_end_date,
  m.budget_usd,
  m.budget_usd IS NOT NULL AS has_budget
FROM staging.stg_campaign_metadata m
LEFT JOIN latest l USING (campaign_id);

-- ---------- fct_ad_performance_daily ----------
-- Grain: one row per (date, platform, campaign_id). Additive measures only.
-- Meta is rolled up from its finer grain; Google is already campaign/day.
-- Surrogate key via MD5 of the grain.
CREATE OR REPLACE TABLE marts.fct_ad_performance_daily
PARTITION BY date_day
CLUSTER BY platform, campaign_id
AS
WITH meta_rolled AS (
  SELECT
    date_day, platform, campaign_id,
    SUM(impressions)          AS impressions,
    SUM(clicks)               AS clicks,
    SUM(spend_usd)            AS spend_usd,
    SUM(conversions)          AS conversions,
    SUM(conversion_value_usd) AS conversion_value_usd
  FROM staging.stg_meta_ads
  GROUP BY date_day, platform, campaign_id
),
unioned AS (
  SELECT * FROM meta_rolled
  UNION ALL
  SELECT
    date_day, platform, campaign_id, impressions, clicks,
    spend_usd, conversions, conversion_value_usd
  FROM staging.stg_google_ads
)
SELECT
  TO_HEX(MD5(CONCAT(
    CAST(date_day AS STRING), '|', platform, '|', CAST(campaign_id AS STRING)
  )))                        AS ad_performance_sk,
  date_day,
  platform,
  campaign_id,
  impressions,
  clicks,
  spend_usd,
  conversions,
  conversion_value_usd
FROM unioned;

-- ---------- fct_store_visits_daily ----------
-- Grain: one row per (date, dma). Enriched with region.
CREATE OR REPLACE TABLE marts.fct_store_visits_daily
PARTITION BY date_day
CLUSTER BY dma_code
AS
SELECT
  v.date_day,
  v.dma_code,
  v.dma_name,
  r.region,
  v.attributed_visits,
  v.attribution_window_days
FROM staging.stg_store_visits v
LEFT JOIN raw.dma_region_map r USING (dma_code);

-- ---------- mart_campaign_performance (analyst one-big-table) ----------
-- Grain: (date, platform, campaign_id) with campaign attributes + pre-computed
-- month/week buckets. This is what the dashboard and ad-hoc queries hit.
CREATE OR REPLACE TABLE marts.mart_campaign_performance
PARTITION BY date_day
CLUSTER BY platform, campaign_id
AS
SELECT
  f.date_day,
  DATE_TRUNC(f.date_day, MONTH)        AS month_start,
  DATE_TRUNC(f.date_day, WEEK(MONDAY)) AS week_start,
  f.platform,
  f.campaign_id,
  c.campaign_name,
  c.brand,
  c.product_line,
  c.region,
  c.budget_usd,
  c.has_budget,
  c.campaign_start_date,
  c.campaign_end_date,
  f.impressions,
  f.clicks,
  f.spend_usd,
  f.conversions,
  f.conversion_value_usd
FROM marts.fct_ad_performance_daily f
LEFT JOIN marts.dim_campaign c USING (campaign_id);
