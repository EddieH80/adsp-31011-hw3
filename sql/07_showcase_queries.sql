-- =====================================================================
-- Assignment 3 - Part 4a: Relational warehouse showcase (3 queries)
-- Each needs joins across several dimensions, history, or multi-level totals -
-- work a key-value lookup cannot do without reading the whole table.
-- =====================================================================

-- S1 (SCD2 point-in-time). Did return behavior change after customers moved tiers? Compare the
-- return rate by the tier a customer had WHEN they bought versus the tier they have TODAY.
SELECT
    v.loyalty_tier                                            AS tier_at_purchase,
    cur.loyalty_tier                                          AS tier_today,
    COUNT(DISTINCT v.user_id)                                 AS customers,
    SUM(f.item_quantity)                                      AS units_bought,
    ROUND(100 * SUM(f.return_quantity) / SUM(f.item_quantity), 1) AS return_rate_pct
FROM fact_order_line f
JOIN dim_customer v   ON v.customer_sk = f.customer_sk                  -- version in effect at purchase
JOIN dim_customer cur ON cur.user_id = v.user_id AND cur.is_current = 1 -- version in effect today
GROUP BY v.loyalty_tier, cur.loyalty_tier
ORDER BY tier_at_purchase, tier_today;

-- S2 (multi-level ROLLUP over time). How do refunds trend by quarter, split by return reason
-- group, with a subtotal per quarter, per year, and a grand total (by return date)?
SELECT
    IF(GROUPING(d.year), 'ALL YEARS', d.year)                        AS return_year,
    CASE WHEN GROUPING(d.year)    THEN 'ALL'
         WHEN GROUPING(d.quarter) THEN 'YEAR TOTAL'
         ELSE CONCAT('Q', d.quarter) END                             AS return_quarter,
    IF(GROUPING(r.reason_group), 'ALL REASONS', r.reason_group)      AS reason_group,
    SUM(f.return_quantity)                                           AS units_returned,
    ROUND(SUM(f.refund_amount), 2)                                   AS refunds,
    ROUND(AVG(f.days_to_return), 1)                                  AS avg_days_to_return
FROM fact_order_line f
JOIN dim_date d          ON d.date_key = f.return_date_key
JOIN dim_return_reason r ON r.return_reason_sk = f.return_reason_sk
WHERE f.is_returned = 1
GROUP BY d.year, d.quarter, r.reason_group WITH ROLLUP;

-- S3 (four-way join, weather on the RETURN day). Do customers start more returns on rainy or
-- snowy days? Returns started per city-day, by the weather in the customer's city that day.
-- Every city-day counts, including days with zero returns (the LEFT JOIN keeps them).
SELECT
    w.weather_condition,
    COUNT(DISTINCT w.weather_sk)                                     AS city_days,
    COUNT(f.order_line_sk)                                           AS returns_started,
    ROUND(COUNT(f.order_line_sk) / COUNT(DISTINCT w.weather_sk), 2)  AS returns_per_city_day,
    ROUND(SUM(f.refund_amount) / COUNT(DISTINCT w.weather_sk), 2)    AS refunds_per_city_day
FROM dim_weather w
LEFT JOIN (
    fact_order_line f
    JOIN dim_customer c ON c.customer_sk = f.customer_sk
    JOIN dim_date rd    ON rd.date_key = f.return_date_key
) ON c.customer_city = w.city AND c.customer_state = w.state AND rd.full_date = w.obs_date
WHERE w.obs_date BETWEEN '2025-10-06' AND '2026-11-10'
GROUP BY w.weather_condition
ORDER BY returns_per_city_day DESC;
