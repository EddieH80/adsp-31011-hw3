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
