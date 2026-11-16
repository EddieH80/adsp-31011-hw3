-- =====================================================================
-- Assignment 3 - Part 1b: Gold layer (curated analytics, rebuilt from Silver on each run)
-- Weather condition: Snow (>= 1 in snow), Heavy rain (>= 0.5 in), Rain (>= 0.1 in), else Dry.
-- Temperature band (daily high): Cold < 40 F, Cool 40-59, Mild 60-79, Hot >= 80.
-- =====================================================================

-- Gold 1: one row per customer city per day. Daily sales and returns next to that day's weather.
DROP TABLE IF EXISTS gold_daily_city_weather_returns;
CREATE TABLE gold_daily_city_weather_returns AS
SELECT
    m.city,
    m.state,
    w.obs_date,
    w.prcp_in,
    w.snow_in,
    w.tmax_f,
    w.tmin_f,
    CASE WHEN w.snow_in >= 1   THEN 'Snow'
         WHEN w.prcp_in >= 0.5 THEN 'Heavy rain'
         WHEN w.prcp_in >= 0.1 THEN 'Rain'
         ELSE 'Dry' END                                   AS weather_condition,
    CASE WHEN w.tmax_f IS NULL THEN 'Unknown'
         WHEN w.tmax_f < 40 THEN 'Cold'
         WHEN w.tmax_f < 60 THEN 'Cool'
         WHEN w.tmax_f < 80 THEN 'Mild'
         ELSE 'Hot' END                                   AS temp_band,
    COALESCE(p.lines_purchased, 0)                        AS lines_purchased,
    COALESCE(p.units_purchased, 0)                        AS units_purchased,
    COALESCE(p.gross_sales, 0)                            AS gross_sales,
    COALESCE(r.returns_initiated, 0)                      AS returns_initiated,
    COALESCE(r.units_returned, 0)                         AS units_returned,
    COALESCE(r.refund_amount, 0)                          AS refund_amount
FROM silver_station_map m
JOIN silver_weather_daily w
  ON w.station_id = m.station_id
LEFT JOIN (
    SELECT customer_city, customer_state, purchase_date,
           COUNT(*) AS lines_purchased, SUM(item_quantity) AS units_purchased,
           SUM(item_quantity * unit_price_paid) AS gross_sales
    FROM silver_order_lines
    GROUP BY customer_city, customer_state, purchase_date
) p ON p.customer_city = m.city AND p.customer_state = m.state AND p.purchase_date = w.obs_date
LEFT JOIN (
    SELECT customer_city, customer_state, return_date,
           COUNT(*) AS returns_initiated, SUM(return_quantity) AS units_returned,
           SUM(refund_amount) AS refund_amount
    FROM silver_order_lines
    WHERE return_quantity > 0
    GROUP BY customer_city, customer_state, return_date
) r ON r.customer_city = m.city AND r.customer_state = m.state AND r.return_date = w.obs_date
WHERE m.role IN ('customer', 'both');

ALTER TABLE gold_daily_city_weather_returns ADD PRIMARY KEY (city, state, obs_date);

-- Gold 2: return rate by product category and the weather on the day the item was bought.
-- Fit share = returns citing size or fit, out of all returns in the group.
DROP TABLE IF EXISTS gold_return_rate_by_category_weather;
CREATE TABLE gold_return_rate_by_category_weather AS
SELECT
    s.category,
    CASE WHEN s.purchase_tmax_f IS NULL THEN 'Unknown'
         WHEN s.purchase_tmax_f < 40 THEN 'Cold'
         WHEN s.purchase_tmax_f < 60 THEN 'Cool'
         WHEN s.purchase_tmax_f < 80 THEN 'Mild'
         ELSE 'Hot' END                                                       AS purchase_temp_band,
    CASE WHEN s.purchase_snow_in >= 1   THEN 'Snow'
         WHEN s.purchase_prcp_in >= 0.5 THEN 'Heavy rain'
         WHEN s.purchase_prcp_in >= 0.1 THEN 'Rain'
         ELSE 'Dry' END                                                       AS purchase_weather,
    COUNT(*)                                                                  AS lines_purchased,
    SUM(s.item_quantity)                                                      AS units_purchased,
    SUM(s.return_quantity)                                                    AS units_returned,
    ROUND(100 * SUM(s.return_quantity) / SUM(s.item_quantity), 2)             AS return_rate_pct,
    ROUND(100 * SUM(s.return_reason IN ('Too small', 'Too large', 'Fit not as expected',
                                        'Ordered multiple sizes'))
              / NULLIF(SUM(s.return_quantity > 0), 0), 1)                     AS fit_share_of_returns_pct,
    ROUND(SUM(s.refund_amount), 2)                                            AS refund_amount
FROM silver_order_lines s
GROUP BY s.category, purchase_temp_band, purchase_weather;

ALTER TABLE gold_return_rate_by_category_weather
    ADD PRIMARY KEY (category, purchase_temp_band, purchase_weather);
