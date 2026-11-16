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
