-- =====================================================================
-- 99_production_procedures.sql
-- Wraps the whole pipeline into stored procedures so the daily job is a single
-- CALL marts.sp_run_pipeline() — no external orchestrator needed. Install once;
-- the Cloud Scheduler + scheduled query (orchestration/) then just calls it.
--
-- Replace __RAW_BUCKET__ before installing (deploy_prod.sh does this).
-- Staging + analytics are VIEWS, so they never need rebuilding — only raw load
-- and mart tables are (re)materialized here.
-- =====================================================================

CREATE OR REPLACE PROCEDURE marts.sp_load_raw()
BEGIN
  LOAD DATA OVERWRITE raw.meta_ads_daily (
    `date` DATE, timestamp_pst TIMESTAMP, campaign_id INT64, campaign_name STRING,
    adset_id STRING, ad_id STRING, objective STRING, placement STRING,
    impressions INT64, clicks INT64, spend_usd FLOAT64, currency STRING,
    conversions FLOAT64, conversion_value_usd FLOAT64
  ) FROM FILES (format='CSV', uris=['__RAW_BUCKET__/meta_ads_daily.csv'], skip_leading_rows=1);

  LOAD DATA OVERWRITE raw.store_visits (
    `date` DATE, dma_code INT64, dma_name STRING,
    attributed_visits INT64, attribution_window_days INT64
  ) FROM FILES (format='CSV', uris=['__RAW_BUCKET__/store_visits.csv'], skip_leading_rows=1);

  LOAD DATA OVERWRITE raw.campaign_metadata (
    campaign_id INT64, brand STRING, product_line STRING, region STRING,
    campaign_start_date DATE, campaign_end_date DATE, budget_usd FLOAT64
  ) FROM FILES (format='CSV', uris=['__RAW_BUCKET__/campaign_metadata.csv'], skip_leading_rows=1);

  LOAD DATA OVERWRITE raw.google_ads_daily_nested
  FROM FILES (format='JSON', uris=['__RAW_BUCKET__/google_ads_daily.json']);

  CREATE OR REPLACE TABLE raw.google_ads_daily AS
  SELECT `date`, timestamp_utc, campaign.id AS campaign_id, campaign.name AS campaign_name,
         campaign.advertising_channel_type AS advertising_channel_type,
         metrics.impressions AS impressions, metrics.clicks AS clicks,
         metrics.cost_micros AS cost_micros, metrics.conversions AS conversions,
         metrics.conversions_value_micros AS conversions_value_micros
  FROM raw.google_ads_daily_nested;
END;

CREATE OR REPLACE PROCEDURE marts.sp_build_marts()
BEGIN
  CREATE OR REPLACE TABLE marts.dim_campaign AS
  WITH names AS (
    SELECT campaign_id, date_day, campaign_name_raw FROM staging.stg_meta_ads
    UNION ALL
    SELECT campaign_id, date_day, campaign_name_raw FROM staging.stg_google_ads
  ),
  ranked AS (
    SELECT campaign_id, campaign_name_raw AS campaign_name,
           ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY date_day DESC) AS rn
    FROM names
  ),
  latest AS (SELECT campaign_id, campaign_name FROM ranked WHERE rn = 1)
  SELECT m.campaign_id, l.campaign_name, m.brand, m.product_line, m.region,
         m.campaign_start_date, m.campaign_end_date, m.budget_usd,
         m.budget_usd IS NOT NULL AS has_budget
  FROM staging.stg_campaign_metadata m
  LEFT JOIN latest l USING (campaign_id);

  CREATE OR REPLACE TABLE marts.fct_ad_performance_daily
  PARTITION BY date_day CLUSTER BY platform, campaign_id AS
  WITH meta_rolled AS (
    SELECT date_day, platform, campaign_id,
           SUM(impressions) impressions, SUM(clicks) clicks, SUM(spend_usd) spend_usd,
           SUM(conversions) conversions, SUM(conversion_value_usd) conversion_value_usd
    FROM staging.stg_meta_ads GROUP BY date_day, platform, campaign_id
  ),
  unioned AS (
    SELECT * FROM meta_rolled
    UNION ALL
    SELECT date_day, platform, campaign_id, impressions, clicks, spend_usd,
           conversions, conversion_value_usd FROM staging.stg_google_ads
  )
  SELECT TO_HEX(MD5(CONCAT(CAST(date_day AS STRING),'|',platform,'|',CAST(campaign_id AS STRING)))) AS ad_performance_sk,
         date_day, platform, campaign_id, impressions, clicks, spend_usd, conversions, conversion_value_usd
  FROM unioned;

  CREATE OR REPLACE TABLE marts.fct_store_visits_daily
  PARTITION BY date_day CLUSTER BY dma_code AS
  SELECT v.date_day, v.dma_code, v.dma_name, r.region, v.attributed_visits, v.attribution_window_days
  FROM staging.stg_store_visits v
  LEFT JOIN raw.dma_region_map r USING (dma_code);

  CREATE OR REPLACE TABLE marts.mart_campaign_performance
  PARTITION BY date_day CLUSTER BY platform, campaign_id AS
  SELECT f.date_day, DATE_TRUNC(f.date_day, MONTH) AS month_start,
         DATE_TRUNC(f.date_day, WEEK(MONDAY)) AS week_start,
         f.platform, f.campaign_id, c.campaign_name, c.brand, c.product_line, c.region,
         c.budget_usd, c.has_budget, c.campaign_start_date, c.campaign_end_date,
         f.impressions, f.clicks, f.spend_usd, f.conversions, f.conversion_value_usd
  FROM marts.fct_ad_performance_daily f
  LEFT JOIN marts.dim_campaign c USING (campaign_id);
END;

-- One entry point for the daily job.
CREATE OR REPLACE PROCEDURE marts.sp_run_pipeline()
BEGIN
  CALL marts.sp_load_raw();
  CALL marts.sp_build_marts();
END;
