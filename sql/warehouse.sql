-- Assignment 3 warehouse SQL (RDS MySQL 8.4, database returns_dw)
-- Concatenation of sql/01..07 in run order. Python steps between files: see README.md.

-- ##### sql/01_medallion_ddl.sql #####
-- =====================================================================
-- Assignment 3 - Part 1b: Bronze / Silver staging DDL (RDS MySQL 8.4, database returns_dw)
-- Bronze = raw, untyped, append-only copies plus audit columns.
-- Silver = typed, cleaned, PII-masked, weather-enriched.
-- =====================================================================

-- ---------- Bronze ----------
DROP TABLE IF EXISTS bronze_returns_lines;
CREATE TABLE bronze_returns_lines (
    bronze_row_id          INT          NOT NULL PRIMARY KEY,  -- line number in the source file
    order_number           VARCHAR(255), rma                   VARCHAR(255),
    user_id                VARCHAR(255), purchase_date         VARCHAR(255),
    return_date            VARCHAR(255), customer_name         VARCHAR(255),
    customer_email         VARCHAR(255), shipping_address      VARCHAR(255),
    customer_city          VARCHAR(255), customer_state        VARCHAR(255),
    customer_zip           VARCHAR(255), loyalty_tier          VARCHAR(255),
    customer_profile_size  VARCHAR(255), payment_method        VARCHAR(255),
    promo_code             VARCHAR(255), discount_pct          VARCHAR(255),
    shipping_method        VARCHAR(255), shipping_cost         VARCHAR(255),
    warehouse_id           VARCHAR(255), warehouse_city        VARCHAR(255),
    warehouse_state        VARCHAR(255), sku                   VARCHAR(255),
    item_name              VARCHAR(255), item_description      TEXT,
    category               VARCHAR(255), subcategory           VARCHAR(255),
    brand                  VARCHAR(255), color                 VARCHAR(255),
    size                   VARCHAR(255), item_fit              VARCHAR(255),
    item_material          VARCHAR(255), item_tags             VARCHAR(255),
    item_weight            VARCHAR(255), item_price            VARCHAR(255),
    item_quantity          VARCHAR(255), unit_price_paid       VARCHAR(255),
    size_chart_viewed      VARCHAR(255), size_switch_count     VARCHAR(255),
    item_rating            VARCHAR(255), return_quantity       VARCHAR(255),
    return_reason          VARCHAR(255), return_comments       TEXT,
    item_return_condition  VARCHAR(255), refund_method         VARCHAR(255),
    refund_amount          VARCHAR(255), inspection_disposition VARCHAR(255),
    lp_review_flag         VARCHAR(255),
    source_name            VARCHAR(64)  NOT NULL,
    source_file            VARCHAR(512) NOT NULL,
    ingested_at            DATETIME     NOT NULL
);

DROP TABLE IF EXISTS bronze_noaa_records;
CREATE TABLE bronze_noaa_records (
    bronze_id      INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    raw_record     JSON         NOT NULL,   -- one element of response.results, unchanged
    s3_key         VARCHAR(512) NOT NULL,   -- the Bronze page it came from
    source_name    VARCHAR(64)  NOT NULL,
    ingested_at    DATETIME     NOT NULL    -- when the API page was pulled (from the envelope)
);

-- ---------- Silver ----------
DROP TABLE IF EXISTS silver_station_map;
CREATE TABLE silver_station_map (
    city          VARCHAR(64)  NOT NULL,
    state         CHAR(2)      NOT NULL,
    role          VARCHAR(16)  NOT NULL,   -- customer | warehouse | both
    station_id    VARCHAR(32)  NOT NULL,
    station_name  VARCHAR(128) NOT NULL,
    PRIMARY KEY (city, state)
);

DROP TABLE IF EXISTS silver_weather_daily;
CREATE TABLE silver_weather_daily (
    station_id     VARCHAR(32)  NOT NULL,
    obs_date       DATE         NOT NULL,
    prcp_in        DECIMAL(5,2) NULL,      -- NULL = not reported (not the same as 0)
    snow_in        DECIMAL(5,1) NULL,
    tmax_f         SMALLINT     NULL,
    tmin_f         SMALLINT     NULL,
    prcp_is_trace  TINYINT(1)   NOT NULL DEFAULT 0,  -- GHCND measurement flag 'T'
    snow_is_trace  TINYINT(1)   NOT NULL DEFAULT 0,
    PRIMARY KEY (station_id, obs_date)
);

DROP TABLE IF EXISTS silver_order_lines;
CREATE TABLE silver_order_lines (
    order_number           VARCHAR(20)   NOT NULL,
    sku                    VARCHAR(40)   NOT NULL,
    user_id                VARCHAR(20)   NOT NULL,
    purchase_ts            DATETIME      NOT NULL,
    purchase_date          DATE          NOT NULL,
    return_ts              DATETIME      NULL,
    return_date            DATE          NULL,
    rma                    VARCHAR(20)   NULL,
    -- PII masked before Silver (see report): HMAC-SHA256 tokens + partial redaction
    customer_name_hash     CHAR(64)      NOT NULL,
    customer_email_hash    CHAR(64)      NOT NULL,
    customer_email_masked  VARCHAR(80)   NOT NULL,
    customer_city          VARCHAR(64)   NOT NULL,
    customer_state         CHAR(2)       NOT NULL,
    customer_zip3          CHAR(3)       NOT NULL,   -- street address dropped, ZIP truncated
    loyalty_tier           VARCHAR(16)   NOT NULL,
    customer_profile_size  VARCHAR(8)    NULL,
    payment_method         VARCHAR(32)   NULL,
    promo_code             VARCHAR(32)   NULL,
    discount_pct           TINYINT       NOT NULL,
    shipping_method        VARCHAR(32)   NULL,
    shipping_cost          DECIMAL(8,2)  NULL,
    warehouse_id           VARCHAR(10)   NOT NULL,
    warehouse_city         VARCHAR(64)   NOT NULL,
    warehouse_state        CHAR(2)       NOT NULL,
    style_code             VARCHAR(30)   NOT NULL,   -- SKU without its color and size parts
    item_name              VARCHAR(128)  NOT NULL,
    category               VARCHAR(32)   NOT NULL,
    subcategory            VARCHAR(32)   NOT NULL,
    brand                  VARCHAR(64)   NOT NULL,
    color                  VARCHAR(32)   NOT NULL,
    size                   VARCHAR(8)    NOT NULL,
    item_fit               VARCHAR(64)   NULL,
    item_material          VARCHAR(128)  NULL,
    item_tags              VARCHAR(255)  NULL,
    item_weight_lb         DECIMAL(6,2)  NULL,
    item_price             DECIMAL(8,2)  NOT NULL,   -- catalog price, conformed per SKU
    item_quantity          TINYINT       NOT NULL,
    unit_price_paid        DECIMAL(8,2)  NOT NULL,
    size_chart_viewed      TINYINT(1)    NOT NULL,
    size_switch_count      TINYINT       NOT NULL,
    item_rating            TINYINT       NULL,
    return_quantity        TINYINT       NOT NULL,
    return_reason          VARCHAR(64)   NULL,
    return_comments        TEXT          NULL,
    item_return_condition  VARCHAR(64)   NULL,
    refund_method          VARCHAR(32)   NULL,
    refund_amount          DECIMAL(8,2)  NOT NULL,
    inspection_disposition VARCHAR(64)   NULL,
    lp_review_flag         TINYINT(1)    NOT NULL,
    -- NOAA enrichment: weather at the customer's city on the purchase and return dates
    station_id             VARCHAR(32)   NULL,
    purchase_prcp_in       DECIMAL(5,2)  NULL,
    purchase_snow_in       DECIMAL(5,1)  NULL,
    purchase_tmax_f        SMALLINT      NULL,
    purchase_tmin_f        SMALLINT      NULL,
    return_prcp_in         DECIMAL(5,2)  NULL,
    return_snow_in         DECIMAL(5,1)  NULL,
    return_tmax_f          SMALLINT      NULL,
    return_tmin_f          SMALLINT      NULL,
    silver_loaded_at       DATETIME      NOT NULL,
    PRIMARY KEY (order_number, sku)
);

DROP TABLE IF EXISTS silver_quarantine;
CREATE TABLE silver_quarantine (
    quarantine_id   INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    source_name     VARCHAR(64)  NOT NULL,
    check_name      VARCHAR(32)  NOT NULL,
    reason          VARCHAR(255) NOT NULL,
    record_key      VARCHAR(255) NULL,
    raw_record      JSON         NOT NULL,   -- the Bronze row as it arrived (PII masked for domain rows)
    quarantined_at  DATETIME     NOT NULL
);

-- One row per check per run: the logged pass/fail counts.
CREATE TABLE IF NOT EXISTS etl_dq_log (
    log_id        INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    run_id        VARCHAR(32)  NOT NULL,
    layer         VARCHAR(16)  NOT NULL,
    source_name   VARCHAR(64)  NOT NULL,
    check_name    VARCHAR(32)  NOT NULL,
    passed        INT          NOT NULL,
    failed        INT          NOT NULL,
    skipped       INT          NOT NULL,
    logged_at     DATETIME     NOT NULL
);

-- ##### sql/02_gold.sql #####
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

-- ##### sql/03_star_schema.sql #####
-- =====================================================================
-- Assignment 3 - Part 2a/2b: Star schema DDL and ELT from Silver (RDS MySQL 8.4)
--
-- Grain of fact_order_line: ONE ROW PER ORDER LINE (one SKU within one order),
-- with that line's purchase and, if any, its return.
-- Dimensions: dim_customer (SCD Type 2 on loyalty_tier), dim_product, dim_date,
--             dim_warehouse, dim_weather (customer city x day), dim_return_reason.
-- =====================================================================

DROP TABLE IF EXISTS fact_order_line;
DROP TABLE IF EXISTS dim_customer;
DROP TABLE IF EXISTS dim_product;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_warehouse;
DROP TABLE IF EXISTS dim_weather;
DROP TABLE IF EXISTS dim_return_reason;

-- ---------- Dimensions ----------
CREATE TABLE dim_date (
    date_key        INT          NOT NULL PRIMARY KEY,     -- yyyymmdd
    full_date       DATE         NOT NULL UNIQUE,
    year            SMALLINT     NOT NULL,
    quarter         TINYINT      NOT NULL,
    month           TINYINT      NOT NULL,
    month_name      VARCHAR(9)   NOT NULL,
    month_label     CHAR(7)      NOT NULL,                 -- '2026-07'
    day_of_week     VARCHAR(9)   NOT NULL,
    is_weekend      TINYINT(1)   NOT NULL,
    is_holiday_peak TINYINT(1)   NOT NULL                  -- Nov 15 - Dec 31
);

CREATE TABLE dim_customer (                                -- SCD Type 2
    customer_sk            INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,  -- surrogate key
    user_id                VARCHAR(20)  NOT NULL,                             -- business key
    loyalty_tier           VARCHAR(16)  NOT NULL,                             -- tracked (Type 2)
    customer_profile_size  VARCHAR(8)   NULL,
    customer_city          VARCHAR(64)  NOT NULL,
    customer_state         CHAR(2)      NOT NULL,
    customer_zip3          CHAR(3)      NOT NULL,
    customer_email_hash    CHAR(64)     NOT NULL,                             -- masked in Silver
    valid_from             DATE         NOT NULL,
    valid_to               DATE         NOT NULL,                             -- 9999-12-31 = open
    is_current             TINYINT(1)   NOT NULL,
    UNIQUE KEY uq_customer_version (user_id, valid_from),
    KEY ix_customer_current (user_id, is_current)
);

CREATE TABLE dim_product (
    product_sk     INT           NOT NULL AUTO_INCREMENT PRIMARY KEY,
    sku            VARCHAR(40)   NOT NULL UNIQUE,
    style_code     VARCHAR(30)   NOT NULL,
    item_name      VARCHAR(128)  NOT NULL,
    category       VARCHAR(32)   NOT NULL,
    subcategory    VARCHAR(32)   NOT NULL,
    brand          VARCHAR(64)   NOT NULL,
    color          VARCHAR(32)   NOT NULL,
    size           VARCHAR(8)    NOT NULL,
    item_fit       VARCHAR(64)   NULL,
    item_material  VARCHAR(128)  NULL,
    list_price     DECIMAL(8,2)  NOT NULL
);

CREATE TABLE dim_warehouse (
    warehouse_sk     INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    warehouse_id     VARCHAR(10)  NOT NULL UNIQUE,
    warehouse_city   VARCHAR(64)  NOT NULL,
    warehouse_state  CHAR(2)      NOT NULL
);

CREATE TABLE dim_weather (                                 -- NOAA GHCND, one row per city per day
    weather_sk         INT           NOT NULL AUTO_INCREMENT PRIMARY KEY,
    city               VARCHAR(64)   NOT NULL,
    state              CHAR(2)       NOT NULL,
    obs_date           DATE          NOT NULL,
    station_id         VARCHAR(32)   NOT NULL,
    prcp_in            DECIMAL(5,2)  NULL,
    snow_in            DECIMAL(5,1)  NULL,
    tmax_f             SMALLINT      NULL,
    tmin_f             SMALLINT      NULL,
    weather_condition  VARCHAR(12)   NOT NULL,
    temp_band          VARCHAR(8)    NOT NULL,
    UNIQUE KEY uq_weather_city_day (city, state, obs_date)
);

CREATE TABLE dim_return_reason (
    return_reason_sk  INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    return_reason     VARCHAR(64)  NOT NULL UNIQUE,
    reason_group      VARCHAR(16)  NOT NULL                -- Fit | Product | Service | Preference | None
);

-- ---------- Fact ----------
CREATE TABLE fact_order_line (
    order_line_sk       INT           NOT NULL AUTO_INCREMENT PRIMARY KEY,
    order_number        VARCHAR(20)   NOT NULL,            -- degenerate dimension
    sku                 VARCHAR(40)   NOT NULL,            -- degenerate (also in dim_product)
    rma                 VARCHAR(20)   NULL,
    customer_sk         INT           NOT NULL,
    product_sk          INT           NOT NULL,
    warehouse_sk        INT           NOT NULL,
    purchase_date_key   INT           NOT NULL,
    return_date_key     INT           NULL,                -- NULL = not returned
    weather_sk          INT           NULL,                -- weather in the customer's city on purchase day
    return_reason_sk    INT           NOT NULL,
    item_quantity       TINYINT       NOT NULL,
    unit_price_paid     DECIMAL(8,2)  NOT NULL,
    gross_sales         DECIMAL(10,2) NOT NULL,            -- item_quantity * unit_price_paid
    discount_pct        TINYINT       NOT NULL,
    return_quantity     TINYINT       NOT NULL,
    refund_amount       DECIMAL(10,2) NOT NULL,
    is_returned         TINYINT(1)    NOT NULL,
    days_to_return      SMALLINT      NULL,
    lp_review_flag      TINYINT(1)    NOT NULL,
    size_chart_viewed   TINYINT(1)    NOT NULL,
    size_switch_count   TINYINT       NOT NULL,
    UNIQUE KEY uq_fact_grain (order_number, sku),
    CONSTRAINT fk_fact_customer  FOREIGN KEY (customer_sk)       REFERENCES dim_customer (customer_sk),
    CONSTRAINT fk_fact_product   FOREIGN KEY (product_sk)        REFERENCES dim_product (product_sk),
    CONSTRAINT fk_fact_warehouse FOREIGN KEY (warehouse_sk)      REFERENCES dim_warehouse (warehouse_sk),
    CONSTRAINT fk_fact_pdate     FOREIGN KEY (purchase_date_key) REFERENCES dim_date (date_key),
    CONSTRAINT fk_fact_rdate     FOREIGN KEY (return_date_key)   REFERENCES dim_date (date_key),
    CONSTRAINT fk_fact_weather   FOREIGN KEY (weather_sk)        REFERENCES dim_weather (weather_sk),
    CONSTRAINT fk_fact_reason    FOREIGN KEY (return_reason_sk)  REFERENCES dim_return_reason (return_reason_sk)
);

-- ---------- ELT: populate dimensions from Silver ----------
INSERT INTO dim_date
WITH RECURSIVE days (d) AS (
    SELECT DATE '2025-10-01'
    UNION ALL
    SELECT d + INTERVAL 1 DAY FROM days WHERE d < DATE '2026-12-31'
)
SELECT CAST(DATE_FORMAT(d, '%Y%m%d') AS UNSIGNED), d, YEAR(d), QUARTER(d), MONTH(d), MONTHNAME(d),
       DATE_FORMAT(d, '%Y-%m'), DAYNAME(d), DAYOFWEEK(d) IN (1, 7),
       (MONTH(d) = 11 AND DAY(d) >= 15) OR MONTH(d) = 12
FROM days;

-- Initial SCD2 load: every customer gets one open version, valid from the start of history.
INSERT INTO dim_customer (user_id, loyalty_tier, customer_profile_size, customer_city, customer_state,
                          customer_zip3, customer_email_hash, valid_from, valid_to, is_current)
SELECT user_id, MAX(loyalty_tier), MAX(customer_profile_size), MAX(customer_city), MAX(customer_state),
       MAX(customer_zip3), MAX(customer_email_hash), DATE '2025-10-01', DATE '9999-12-31', 1
FROM silver_order_lines
GROUP BY user_id;

INSERT INTO dim_product (sku, style_code, item_name, category, subcategory, brand, color, size,
                         item_fit, item_material, list_price)
SELECT sku, MAX(style_code), MAX(item_name), MAX(category), MAX(subcategory), MAX(brand), MAX(color),
       MAX(size), MAX(item_fit), MAX(item_material), MAX(item_price)
FROM silver_order_lines
GROUP BY sku;

INSERT INTO dim_warehouse (warehouse_id, warehouse_city, warehouse_state)
SELECT warehouse_id, MAX(warehouse_city), MAX(warehouse_state)
FROM silver_order_lines
GROUP BY warehouse_id;

INSERT INTO dim_weather (city, state, obs_date, station_id, prcp_in, snow_in, tmax_f, tmin_f,
                         weather_condition, temp_band)
SELECT city, state, obs_date, m.station_id, prcp_in, snow_in, tmax_f, tmin_f, weather_condition, temp_band
FROM gold_daily_city_weather_returns g
JOIN silver_station_map m USING (city, state);

INSERT INTO dim_return_reason (return_reason, reason_group) VALUES
    ('Not returned',                'None'),
    ('Too small',                   'Fit'),
    ('Too large',                   'Fit'),
    ('Fit not as expected',         'Fit'),
    ('Ordered multiple sizes',      'Fit'),
    ('Damaged or defective',        'Product'),
    ('Not as pictured / described', 'Product'),
    ('Wrong item received',         'Service'),
    ('Arrived too late',            'Service'),
    ('Changed my mind',             'Preference'),
    ('Didn''t like style or color', 'Preference'),
    ('Found a better price',        'Preference');

-- ---------- ELT: populate the fact (SCD2-aware customer lookup) ----------
INSERT INTO fact_order_line (order_number, sku, rma, customer_sk, product_sk, warehouse_sk,
                             purchase_date_key, return_date_key, weather_sk, return_reason_sk,
                             item_quantity, unit_price_paid, gross_sales, discount_pct, return_quantity,
                             refund_amount, is_returned, days_to_return, lp_review_flag,
                             size_chart_viewed, size_switch_count)
SELECT s.order_number, s.sku, s.rma,
       c.customer_sk, p.product_sk, w.warehouse_sk,
       CAST(DATE_FORMAT(s.purchase_date, '%Y%m%d') AS UNSIGNED),
       CAST(DATE_FORMAT(s.return_date, '%Y%m%d') AS UNSIGNED),
       x.weather_sk, rr.return_reason_sk,
       s.item_quantity, s.unit_price_paid, s.item_quantity * s.unit_price_paid, s.discount_pct,
       s.return_quantity, s.refund_amount, s.return_quantity > 0,
       DATEDIFF(s.return_date, s.purchase_date), s.lp_review_flag, s.size_chart_viewed, s.size_switch_count
FROM silver_order_lines s
JOIN dim_customer c       ON c.user_id = s.user_id
                         AND s.purchase_date BETWEEN c.valid_from AND c.valid_to   -- version in effect
JOIN dim_product p        ON p.sku = s.sku
JOIN dim_warehouse w      ON w.warehouse_id = s.warehouse_id
LEFT JOIN dim_weather x   ON x.city = s.customer_city AND x.state = s.customer_state
                         AND x.obs_date = s.purchase_date
JOIN dim_return_reason rr ON rr.return_reason = COALESCE(s.return_reason, 'Not returned');

-- ---------- Load check ----------
SELECT 'dim_date' AS table_name, COUNT(*) AS row_count FROM dim_date
UNION ALL SELECT 'dim_customer', COUNT(*) FROM dim_customer
UNION ALL SELECT 'dim_product', COUNT(*) FROM dim_product
UNION ALL SELECT 'dim_warehouse', COUNT(*) FROM dim_warehouse
UNION ALL SELECT 'dim_weather', COUNT(*) FROM dim_weather
UNION ALL SELECT 'dim_return_reason', COUNT(*) FROM dim_return_reason
UNION ALL SELECT 'fact_order_line', COUNT(*) FROM fact_order_line
UNION ALL SELECT 'silver_order_lines', COUNT(*) FROM silver_order_lines;

-- ##### sql/04_scd2_change.sql #####
-- =====================================================================
-- Assignment 3 - Part 2a: SCD Type 2 simulation on dim_customer.loyalty_tier
-- Scenario: a Silver-tier customer is upgraded to Gold on 2026-07-01.
-- Type 2 keeps history: the old version is expired (valid_to, is_current = 0) and a
-- new version is inserted. Fact rows bought on/after the change point to the new version,
-- so "return rate by tier at time of purchase" stays correct.
-- Run once, right after 03_star_schema.sql.
-- =====================================================================

SET @change_date := DATE '2026-07-01';
SET @new_tier    := 'Gold';

-- Pick a real Silver customer with purchases both before and after the change date.
SET @uid := (
    SELECT c.user_id
    FROM dim_customer c
    JOIN fact_order_line f ON f.customer_sk = c.customer_sk
    JOIN dim_date d        ON d.date_key = f.purchase_date_key
    WHERE c.loyalty_tier = 'Silver' AND c.is_current = 1
    GROUP BY c.user_id
    HAVING MIN(d.full_date) < @change_date AND MAX(d.full_date) >= @change_date
    ORDER BY COUNT(*) DESC, c.user_id
    LIMIT 1
);

-- 1. Insert the new version (copies every attribute except the tracked one).
INSERT INTO dim_customer (user_id, loyalty_tier, customer_profile_size, customer_city, customer_state,
                          customer_zip3, customer_email_hash, valid_from, valid_to, is_current)
SELECT user_id, @new_tier, customer_profile_size, customer_city, customer_state,
       customer_zip3, customer_email_hash, @change_date, DATE '9999-12-31', 1
FROM dim_customer
WHERE user_id = @uid AND is_current = 1 AND loyalty_tier <> @new_tier;

-- 2. Expire the old version: it ends the day before the change.
UPDATE dim_customer
SET valid_to = @change_date - INTERVAL 1 DAY, is_current = 0
WHERE user_id = @uid AND is_current = 1 AND valid_from < @change_date;

-- 3. Re-point facts bought on/after the change to the version in effect that day.
UPDATE fact_order_line f
JOIN dim_customer old_v ON old_v.customer_sk = f.customer_sk
JOIN dim_customer new_v ON new_v.user_id = old_v.user_id
                       AND f.purchase_date_key BETWEEN CAST(DATE_FORMAT(new_v.valid_from, '%Y%m%d') AS UNSIGNED)
                                                   AND CAST(DATE_FORMAT(new_v.valid_to, '%Y%m%d') AS UNSIGNED)
SET f.customer_sk = new_v.customer_sk
WHERE old_v.user_id = @uid AND new_v.customer_sk <> old_v.customer_sk;

-- Proof 1: both versions - the expired historical row and the new active row.
SELECT customer_sk, user_id, loyalty_tier, valid_from, valid_to, is_current
FROM dim_customer
WHERE user_id = @uid
ORDER BY valid_from;

-- Proof 2: the customer's order lines, each attached to the version in effect when bought.
SELECT c.customer_sk, c.loyalty_tier, MIN(d.full_date) AS first_purchase, MAX(d.full_date) AS last_purchase,
       COUNT(*) AS order_lines
FROM fact_order_line f
JOIN dim_customer c ON c.customer_sk = f.customer_sk
JOIN dim_date d     ON d.date_key = f.purchase_date_key
WHERE c.user_id = @uid
GROUP BY c.customer_sk, c.loyalty_tier
ORDER BY first_purchase;

-- ##### sql/05_analytical_queries.sql #####
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

-- ##### sql/06_optimization.sql #####
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

-- ##### sql/07_showcase_queries.sql #####
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
