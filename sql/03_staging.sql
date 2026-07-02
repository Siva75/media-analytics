-- =====================================================================
-- 03_staging.sql
-- One view per source. All data-quality fixes live here. Views are free to
-- store and always reflect the latest raw data.
-- =====================================================================

-- ---------- Meta: currency fix + null handling ----------
-- Grain: native (date, campaign, adset, ad, objective, placement).
-- Fix 1: spend is sometimes in CAD/GBP (flagged via `currency`, sometimes null).
--        Convert to true USD via raw.fx_rates; null currency -> USD.
-- Fix 2: null conversions / conversion_value -> 0.
CREATE OR REPLACE VIEW staging.stg_meta_ads AS
WITH cleaned AS (
  SELECT
    CAST(`date` AS DATE)                                      AS date_day,
    CAST(timestamp_pst AS TIMESTAMP)                          AS event_ts_pst,
    CAST(campaign_id AS INT64)                                AS campaign_id,
    campaign_name                                             AS campaign_name_raw,
    adset_id,
    ad_id,
    UPPER(objective)                                          AS objective,
    placement,
    CAST(impressions AS INT64)                                AS impressions,
    CAST(clicks AS INT64)                                     AS clicks,
    COALESCE(UPPER(currency), 'USD')                          AS reported_currency,
    CAST(spend_usd AS FLOAT64)                                AS spend_local,
    COALESCE(CAST(conversions AS FLOAT64), 0)                 AS conversions,
    COALESCE(CAST(conversion_value_usd AS FLOAT64), 0)        AS conversion_value_usd
  FROM raw.meta_ads_daily
)
SELECT
  c.date_day,
  'meta'                                                      AS platform,
  c.campaign_id,
  c.campaign_name_raw,
  c.adset_id,
  c.ad_id,
  c.objective,
  c.placement,
  c.impressions,
  c.clicks,
  c.reported_currency,
  c.spend_local,
  ROUND(c.spend_local * COALESCE(fx.usd_per_unit, 1.0), 2)    AS spend_usd,
  c.conversions,
  c.conversion_value_usd
FROM cleaned c
LEFT JOIN raw.fx_rates fx
  ON c.reported_currency = fx.currency;

-- ---------- Google: micros conversion + de-duplication ----------
-- Grain: one row per (date, campaign) after dedup.
-- Fix 1: cost/value are in micros -> divide by 1e6.
-- Fix 2: export bug duplicates some (campaign, date) rows. Spend & conversions
--        are identical within each dup group, so keep ONE row (max impressions).
CREATE OR REPLACE VIEW staging.stg_google_ads AS
WITH typed AS (
  SELECT
    CAST(`date` AS DATE)                              AS date_day,
    CAST(timestamp_utc AS TIMESTAMP)                  AS event_ts_utc,
    CAST(campaign_id AS INT64)                        AS campaign_id,
    campaign_name                                     AS campaign_name_raw,
    advertising_channel_type                          AS channel_type,
    CAST(impressions AS INT64)                        AS impressions,
    CAST(clicks AS INT64)                             AS clicks,
    CAST(cost_micros AS NUMERIC) / 1000000.0          AS spend_usd,
    CAST(conversions AS FLOAT64)                      AS conversions,
    CAST(conversions_value_micros AS NUMERIC) / 1000000.0 AS conversion_value_usd
  FROM raw.google_ads_daily
),
deduped AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY campaign_id, date_day
      ORDER BY impressions DESC, spend_usd DESC
    ) AS rn
  FROM typed
)
SELECT
  date_day,
  'google'                        AS platform,
  campaign_id,
  campaign_name_raw,
  channel_type,
  impressions,
  clicks,
  ROUND(spend_usd, 2)             AS spend_usd,
  conversions,
  ROUND(conversion_value_usd, 2)  AS conversion_value_usd
FROM deduped
WHERE rn = 1;

-- ---------- Store visits ----------
-- Grain: one row per (date, dma). Attribution window is an attribute.
CREATE OR REPLACE VIEW staging.stg_store_visits AS
SELECT
  CAST(`date` AS DATE)                    AS date_day,
  CAST(dma_code AS INT64)                 AS dma_code,
  dma_name,
  CAST(attributed_visits AS INT64)        AS attributed_visits,
  CAST(attribution_window_days AS INT64)  AS attribution_window_days
FROM raw.store_visits;

-- ---------- Campaign metadata ----------
-- Grain: one row per campaign_id. budget_usd stays NULL when absent on purpose.
CREATE OR REPLACE VIEW staging.stg_campaign_metadata AS
SELECT
  CAST(campaign_id AS INT64)         AS campaign_id,
  brand,
  product_line,
  region,
  CAST(campaign_start_date AS DATE)  AS campaign_start_date,
  CAST(campaign_end_date AS DATE)    AS campaign_end_date,
  CAST(budget_usd AS FLOAT64)        AS budget_usd
FROM raw.campaign_metadata;
