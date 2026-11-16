-- =====================================================================
-- Assignment 3 - Part 2b: Five analytical queries on the star schema
-- Return rate = units returned / units bought (sum, then divide).
-- =====================================================================

-- Q1 (WITH ROLLUP). What is the return rate by product category and by the customer's loyalty
-- tier at the time of purchase, with subtotals per category and a grand total?
SELECT
    IF(GROUPING(p.category), 'ALL CATEGORIES', p.category)   AS category,
    IF(GROUPING(c.loyalty_tier), 'ALL TIERS', c.loyalty_tier) AS loyalty_tier,
    SUM(f.item_quantity)                                      AS units_bought,
    SUM(f.return_quantity)                                    AS units_returned,
    ROUND(100 * SUM(f.return_quantity) / SUM(f.item_quantity), 1) AS return_rate_pct,
    ROUND(SUM(f.refund_amount), 2)                            AS refunds
FROM fact_order_line f
JOIN dim_product p  ON p.product_sk = f.product_sk
JOIN dim_customer c ON c.customer_sk = f.customer_sk
GROUP BY p.category, c.loyalty_tier WITH ROLLUP;

-- Q2. How does the monthly return rate trend at each warehouse (by purchase month)?
SELECT
    d.month_label                                             AS purchase_month,
    w.warehouse_id,
    w.warehouse_city,
    SUM(f.item_quantity)                                      AS units_bought,
    SUM(f.return_quantity)                                    AS units_returned,
    ROUND(100 * SUM(f.return_quantity) / SUM(f.item_quantity), 1) AS return_rate_pct
FROM fact_order_line f
JOIN dim_date d      ON d.date_key = f.purchase_date_key
JOIN dim_warehouse w ON w.warehouse_sk = f.warehouse_sk
GROUP BY d.month_label, w.warehouse_id, w.warehouse_city
ORDER BY d.month_label, w.warehouse_id;

-- Q3. Do items bought on cold or wet days come back more often? Return rate by the weather in
-- the customer's city on the purchase day, for the two most weather-sensitive categories.
SELECT
    p.category,
    x.temp_band,
    x.weather_condition,
    COUNT(*)                                                  AS order_lines,
    SUM(f.item_quantity)                                      AS units_bought,
    ROUND(100 * SUM(f.return_quantity) / SUM(f.item_quantity), 1) AS return_rate_pct
FROM fact_order_line f
JOIN dim_product p ON p.product_sk = f.product_sk
JOIN dim_weather x ON x.weather_sk = f.weather_sk
WHERE p.category IN ('Outerwear', 'Activewear')
GROUP BY p.category, x.temp_band, x.weather_condition
HAVING COUNT(*) >= 30
ORDER BY p.category, return_rate_pct DESC;

-- Q4. Which styles have the worst fit problems? Top 10 styles by the share of units returned for a
-- size or fit reason (styles with at least 100 units sold), with the size that fails most.
WITH style_sizes AS (
    SELECT p.style_code, MAX(p.item_name) AS item_name, MAX(p.category) AS category, p.size,
           SUM(f.item_quantity) AS units_bought,
           SUM(CASE WHEN r.reason_group = 'Fit' THEN f.return_quantity ELSE 0 END) AS fit_units_returned
    FROM fact_order_line f
    JOIN dim_product p       ON p.product_sk = f.product_sk
    JOIN dim_return_reason r ON r.return_reason_sk = f.return_reason_sk
    GROUP BY p.style_code, p.size
),
ranked AS (
    SELECT s.*,
           SUM(units_bought)       OVER (PARTITION BY style_code) AS style_units,
           SUM(fit_units_returned) OVER (PARTITION BY style_code) AS style_fit_returns,
           ROW_NUMBER() OVER (PARTITION BY style_code
                              ORDER BY fit_units_returned / units_bought DESC, size) AS size_rank
    FROM style_sizes s
)
SELECT style_code, item_name, category, style_units AS units_bought, style_fit_returns AS fit_units_returned,
       ROUND(100 * style_fit_returns / style_units, 1)  AS fit_return_rate_pct,
       size                                              AS worst_size,
       ROUND(100 * fit_units_returned / units_bought, 1) AS worst_size_fit_rate_pct
FROM ranked
WHERE size_rank = 1 AND style_units >= 100
ORDER BY fit_return_rate_pct DESC
LIMIT 10;

-- Q5. Which customers should loss prevention review first? Customers with 5+ returned lines,
-- ranked by refund dollars, with their unit return rate and how many returns were already flagged.
SELECT
    c.user_id,
    MAX(CASE WHEN c.is_current = 1 THEN c.loyalty_tier END)   AS current_tier,
    COUNT(*)                                                  AS order_lines,
    SUM(f.is_returned)                                        AS returned_lines,
    ROUND(100 * SUM(f.return_quantity) / SUM(f.item_quantity), 1) AS return_rate_pct,
    ROUND(SUM(f.refund_amount), 2)                            AS refunds,
    SUM(f.lp_review_flag)                                     AS lp_flags,
    ROUND(AVG(CASE WHEN f.is_returned = 1 THEN f.days_to_return END), 1) AS avg_days_to_return
FROM fact_order_line f
JOIN dim_customer c ON c.customer_sk = f.customer_sk
GROUP BY c.user_id
HAVING returned_lines >= 5
ORDER BY refunds DESC
LIMIT 15;
