-- =====================================================================
-- 05_analytics.sql
-- The four business questions, materialized as views so they are queryable
-- objects (great for Looker Studio and for the reviewer to inspect).
-- =====================================================================

-- ---------- Q1: Blended CPA by brand & month ----------
-- CPA is non-additive: sum spend and conversions first, then divide.
CREATE OR REPLACE VIEW marts.q1_blended_cpa_by_brand_month AS
SELECT
  brand,
  month_start,
  ROUND(SUM(spend_usd), 2)                                 AS total_spend_usd,
  ROUND(SUM(conversions), 2)                               AS total_conversions,
  ROUND(SUM(spend_usd) / NULLIF(SUM(conversions), 0), 2)   AS blended_cpa_usd
FROM marts.mart_campaign_performance
GROUP BY brand, month_start
ORDER BY brand, month_start;

-- ---------- Q2: Top 10 WoW spend growth, most recent 4 complete weeks ----------
-- Complete weeks only (7 days) so the trailing partial week is excluded.
CREATE OR REPLACE VIEW marts.q2_top10_wow_spend_growth AS
WITH weekly AS (
  SELECT
    campaign_id, campaign_name, week_start,
    SUM(spend_usd)          AS weekly_spend_usd,
    COUNT(DISTINCT date_day) AS days_in_week
  FROM marts.mart_campaign_performance
  GROUP BY campaign_id, campaign_name, week_start
),
complete_weeks AS (
  SELECT week_start
  FROM weekly
  GROUP BY week_start
  HAVING SUM(days_in_week) >= 7
),
recent_4 AS (
  SELECT week_start, ROW_NUMBER() OVER (ORDER BY week_start DESC) AS wk_rank
  FROM complete_weeks
),
wow AS (
  SELECT
    campaign_id, campaign_name, week_start, weekly_spend_usd,
    LAG(weekly_spend_usd) OVER (
      PARTITION BY campaign_id ORDER BY week_start
    ) AS prev_week_spend_usd
  FROM weekly
  WHERE days_in_week >= 7
)
SELECT
  wow.campaign_id,
  wow.campaign_name,
  wow.week_start,
  ROUND(wow.prev_week_spend_usd, 2) AS prev_week_spend_usd,
  ROUND(wow.weekly_spend_usd, 2)    AS this_week_spend_usd,
  ROUND(100.0 * (wow.weekly_spend_usd - wow.prev_week_spend_usd)
        / NULLIF(wow.prev_week_spend_usd, 0), 1) AS wow_growth_pct
FROM wow
JOIN recent_4 r ON wow.week_start = r.week_start AND r.wk_rank <= 4
WHERE wow.prev_week_spend_usd > 0
ORDER BY wow_growth_pct DESC
LIMIT 10;

-- ---------- Q3: Weekly spend vs attributed store visits (region x week) ----------
-- No DMA->campaign crosswalk exists; relate at region x week.
-- National campaigns fan out to both measured regions.
CREATE OR REPLACE VIEW marts.q3_spend_vs_store_visits AS
WITH spend_by_region_week AS (
  SELECT
    CASE WHEN m.region = 'National' THEN reg.region ELSE m.region END AS region,
    m.week_start,
    SUM(m.spend_usd) AS weekly_spend_usd
  FROM marts.mart_campaign_performance m
  LEFT JOIN (SELECT DISTINCT region FROM raw.dma_region_map) reg
    ON m.region = 'National'
  WHERE m.region IN ('National', 'East', 'West')
  GROUP BY 1, 2
),
visits_by_region_week AS (
  SELECT
    region,
    DATE_TRUNC(date_day, WEEK(MONDAY)) AS week_start,
    SUM(attributed_visits)             AS weekly_visits
  FROM marts.fct_store_visits_daily
  WHERE region IS NOT NULL
  GROUP BY 1, 2
)
SELECT
  s.region,
  s.week_start,
  ROUND(s.weekly_spend_usd, 2) AS weekly_spend_usd,
  v.weekly_visits,
  ROUND(s.weekly_spend_usd / NULLIF(v.weekly_visits, 0), 2) AS spend_per_visit_usd
FROM spend_by_region_week s
JOIN visits_by_region_week v
  ON s.region = v.region AND s.week_start = v.week_start
ORDER BY s.region, s.week_start;

-- ---------- Q4: Budget overspend flags ----------
-- Missing budget -> explicit NO_BUDGET_ON_RECORD (not 0, not infinity).
CREATE OR REPLACE VIEW marts.q4_budget_overspend_flags AS
WITH campaign_spend AS (
  SELECT campaign_id, SUM(spend_usd) AS total_spend_usd
  FROM marts.fct_ad_performance_daily
  GROUP BY campaign_id
)
SELECT
  c.campaign_id,
  c.campaign_name,
  c.product_line,
  c.region,
  c.budget_usd,
  ROUND(COALESCE(s.total_spend_usd, 0), 2)                   AS total_spend_usd,
  ROUND(COALESCE(s.total_spend_usd, 0) - c.budget_usd, 2)    AS spend_over_budget_usd,
  ROUND(100.0 * COALESCE(s.total_spend_usd, 0)
        / NULLIF(c.budget_usd, 0), 1)                        AS pct_of_budget,
  CASE
    WHEN c.budget_usd IS NULL THEN 'NO_BUDGET_ON_RECORD'
    WHEN COALESCE(s.total_spend_usd, 0) > c.budget_usd THEN 'OVER_BUDGET'
    ELSE 'WITHIN_BUDGET'
  END AS budget_status
FROM marts.dim_campaign c
LEFT JOIN campaign_spend s USING (campaign_id)
ORDER BY
  CASE
    WHEN c.budget_usd IS NULL THEN 2
    WHEN COALESCE(s.total_spend_usd, 0) > c.budget_usd THEN 0
    ELSE 1
  END,
  spend_over_budget_usd DESC;
