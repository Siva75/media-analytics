-- =====================================================================
-- 02_load_raw.sql
-- Loads the four extracts from Cloud Storage straight into BigQuery using the
-- native LOAD DATA statement (no Python, no external loader).
-- OVERWRITE makes each load idempotent (safe to re-run).
--
-- The token __RAW_BUCKET__ is replaced with your gs:// bucket by deploy.sh
-- (or sed it yourself before running).
-- =====================================================================

-- ---------- Meta (CSV, explicit schema so types never drift) ----------
LOAD DATA OVERWRITE raw.meta_ads_daily (
  `date`               DATE,
  timestamp_pst        TIMESTAMP,
  campaign_id          INT64,
  campaign_name        STRING,
  adset_id             STRING,
  ad_id                STRING,
  objective            STRING,
  placement            STRING,
  impressions          INT64,
  clicks               INT64,
  spend_usd            FLOAT64,
  currency             STRING,
  conversions          FLOAT64,
  conversion_value_usd FLOAT64
)
FROM FILES (
  format = 'CSV',
  uris = ['__RAW_BUCKET__/meta_ads_daily.csv'],
  skip_leading_rows = 1
);

-- ---------- Store visits (CSV) ----------
LOAD DATA OVERWRITE raw.store_visits (
  `date`                   DATE,
  dma_code                 INT64,
  dma_name                 STRING,
  attributed_visits        INT64,
  attribution_window_days  INT64
)
FROM FILES (
  format = 'CSV',
  uris = ['__RAW_BUCKET__/store_visits.csv'],
  skip_leading_rows = 1
);

-- ---------- Campaign metadata (CSV; budget_usd is sparsely populated) ----------
LOAD DATA OVERWRITE raw.campaign_metadata (
  campaign_id         INT64,
  brand               STRING,
  product_line        STRING,
  region              STRING,
  campaign_start_date DATE,
  campaign_end_date   DATE,
  budget_usd          FLOAT64
)
FROM FILES (
  format = 'CSV',
  uris = ['__RAW_BUCKET__/campaign_metadata.csv'],
  skip_leading_rows = 1
);

-- ---------- Google (newline-delimited JSON, nested) ----------
-- Load nested first (schema auto-detected), then flatten to flat columns so the
-- staging layer is simple.
LOAD DATA OVERWRITE raw.google_ads_daily_nested
FROM FILES (
  format = 'JSON',
  uris = ['__RAW_BUCKET__/google_ads_daily.json']
);

CREATE OR REPLACE TABLE raw.google_ads_daily AS
SELECT
  `date`,
  timestamp_utc,
  campaign.id                        AS campaign_id,
  campaign.name                      AS campaign_name,
  campaign.advertising_channel_type  AS advertising_channel_type,
  metrics.impressions                AS impressions,
  metrics.clicks                     AS clicks,
  metrics.cost_micros                AS cost_micros,
  metrics.conversions                AS conversions,
  metrics.conversions_value_micros   AS conversions_value_micros
FROM raw.google_ads_daily_nested;
