-- =====================================================================
-- 06_tests.sql
-- Native data-quality checks using BigQuery's ASSERT statement. Each ASSERT
-- fails the script (non-zero) if the condition is violated, so this is the
-- no-dbt equivalent of dbt tests. Run after 04_marts.sql.
-- =====================================================================

-- 1. Fact grain is unique: one row per (date, platform, campaign_id).
ASSERT (
  SELECT COUNT(*) FROM (
    SELECT date_day, platform, campaign_id
    FROM marts.fct_ad_performance_daily
    GROUP BY date_day, platform, campaign_id
    HAVING COUNT(*) > 1
  )
) = 0 AS 'FAIL: fct_ad_performance_daily grain is not unique';

-- 2. Surrogate key is unique and non-null.
ASSERT (
  SELECT COUNTIF(ad_performance_sk IS NULL)
       + (COUNT(*) - COUNT(DISTINCT ad_performance_sk))
  FROM marts.fct_ad_performance_daily
) = 0 AS 'FAIL: ad_performance_sk not unique/non-null';

-- 3. Dimension key is unique.
ASSERT (
  SELECT COUNT(*) - COUNT(DISTINCT campaign_id) FROM marts.dim_campaign
) = 0 AS 'FAIL: dim_campaign.campaign_id not unique';

-- 4. Referential integrity: every fact campaign exists in the dimension.
ASSERT (
  SELECT COUNT(*)
  FROM marts.fct_ad_performance_daily f
  LEFT JOIN marts.dim_campaign c USING (campaign_id)
  WHERE c.campaign_id IS NULL
) = 0 AS 'FAIL: fact has campaign_id missing from dim_campaign';

-- 5. Google dedup worked: staging has one row per (campaign, date).
ASSERT (
  SELECT COUNT(*) FROM (
    SELECT campaign_id, date_day
    FROM staging.stg_google_ads
    GROUP BY campaign_id, date_day
    HAVING COUNT(*) > 1
  )
) = 0 AS 'FAIL: stg_google_ads still has duplicate (campaign, date) rows';

-- 6. No negative spend after currency conversion.
ASSERT (
  SELECT COUNTIF(spend_usd < 0) FROM marts.fct_ad_performance_daily
) = 0 AS 'FAIL: negative spend_usd present';

SELECT 'ALL DATA QUALITY CHECKS PASSED' AS status;
