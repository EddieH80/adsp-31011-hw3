-- =====================================================================
-- Assignment 3 - Part 2b: Query profiling and optimization
-- Most expensive query (EXPLAIN ANALYZE on all 8 warehouse queries): S3 in 07_showcase_queries.sql,
-- "returns started per city-day by the weather on the return day" (~800 ms).
-- Why: for each of ~12k city-days it fetches every return on that date (~15) and then looks up each
-- customer's city - ~180k customer lookups, about 97% of them thrown away. An index on the fact
-- table cannot help, because the city filter lives on dim_customer.
-- Optimization: a materialized summary table (MySQL has no MATERIALIZED VIEW, so the ELT refreshes
-- this table after each fact load). It pre-aggregates returns to one row per city per return day,
-- keyed so the weather join becomes a primary-key lookup.
-- Profile with:  python pipeline/profile_queries.py sql/06_optimization.sql --plan
-- =====================================================================

-- BEFORE: the original query against the fact table.
EXPLAIN ANALYZE
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

-- OPTIMIZATION: materialized summary, refreshed by the ELT after each fact load.
DROP TABLE IF EXISTS mv_city_day_returns;
CREATE TABLE mv_city_day_returns (
    city             VARCHAR(64)   NOT NULL,
    state            CHAR(2)       NOT NULL,
    return_date      DATE          NOT NULL,
    returns_started  INT           NOT NULL,
    refund_amount    DECIMAL(12,2) NOT NULL,
    refreshed_at     DATETIME      NOT NULL,
    PRIMARY KEY (city, state, return_date)
);
INSERT INTO mv_city_day_returns
SELECT c.customer_city, c.customer_state, rd.full_date, COUNT(*), SUM(f.refund_amount), NOW()
FROM fact_order_line f
JOIN dim_customer c ON c.customer_sk = f.customer_sk
JOIN dim_date rd    ON rd.date_key = f.return_date_key
WHERE f.is_returned = 1
GROUP BY c.customer_city, c.customer_state, rd.full_date;

-- AFTER: same business question, same result, now one primary-key lookup per city-day.
EXPLAIN ANALYZE
SELECT
    w.weather_condition,
    COUNT(*)                                                         AS city_days,
    COALESCE(SUM(m.returns_started), 0)                              AS returns_started,
    ROUND(COALESCE(SUM(m.returns_started), 0) / COUNT(*), 2)         AS returns_per_city_day,
    ROUND(COALESCE(SUM(m.refund_amount), 0) / COUNT(*), 2)           AS refunds_per_city_day
FROM dim_weather w
LEFT JOIN mv_city_day_returns m
       ON m.city = w.city AND m.state = w.state AND m.return_date = w.obs_date
WHERE w.obs_date BETWEEN '2025-10-06' AND '2026-11-10'
GROUP BY w.weather_condition
ORDER BY returns_per_city_day DESC;
