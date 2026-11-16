# ADSP 31011 Assignment 3: Data Warehouse & Polyglot Persistence

Code for Assignment 3. The domain is Northloom, an online apparel retailer's returns data from Assignment 2, enriched with live NOAA weather data. The warehouse runs on AWS RDS MySQL 8.4 and the NoSQL store is AWS DynamoDB (Option A).

The written report (submitted separately) has the results and screenshots. This repo holds the code behind them.

## Where to find each deliverable

| Assignment part | Where it lives |
|---|---|
| 1a. Live API ingestion (pagination, rate limiting, error handling, quality checks) | `ingestion/` |
| 1b. Medallion pipeline: Bronze, Silver (cleaning, quarantine, PII masking, weather join), Gold | `pipeline/` and `sql/01_medallion_ddl.sql`, `sql/02_gold.sql` |
| 2a. Star schema and SCD Type 2 | `sql/03_star_schema.sql`, `sql/04_scd2_change.sql` |
| 2b. Five analytical queries (Q1 uses WITH ROLLUP) | `sql/05_analytical_queries.sql` |
| 2b. Query profiling and optimization (before/after) | `sql/06_optimization.sql`, `pipeline/profile_queries.py` |
| 3. DynamoDB table, GSI, item load, three access patterns | `dynamodb/` |
| 4a. Three relational showcase queries | `sql/07_showcase_queries.sql` |
| 4b. Three DynamoDB showcase queries | `dynamodb/queries.py` (B1-B3) |
| Single warehouse SQL script | `sql/warehouse.sql` (files 01-07 combined in run order) |

## What each folder contains

### `ingestion/`: Part 1a, NOAA Climate Data Online v2 to S3 Bronze

| File | What it does |
|---|---|
| `run_ingest.py` | Entry point. Pulls daily weather for 32 stations over two date windows and writes each raw page to S3. |
| `noaa_client.py` | API client: offset pagination, a 5-requests-per-second limiter, exponential backoff with Retry-After, and handling for timeouts, bad status codes, empty payloads and missing keys. |
| `quality_checks.py` | The three pre-transformation checks (nulls, duplicates, ranges) with row-level pass/fail counts. |
| `bronze_writer.py` | Writes each page unchanged inside an envelope with `source_name`, `ingested_at` and the request parameters. |
| `find_stations.py`, `stations.csv` | One-time helper that matched each customer city to a NOAA station, and its output. |
| `config.yaml` | Stations, date windows, rate limits and the S3 bucket. No token is stored here. |
| `tests/test_quality_checks.py` | 14 unit tests for the quality checks (`pytest`). |
| `logs/` | Output of the graded run: `ingest.log` (shows a real 429 retry), `dq_report.json` (pass/fail counts) and `run_summary.json` (96 pages, 49,908 records). |
| `.env.example` | Shows the one variable to set (`NOAA_TOKEN`). The real token is never committed. |

### `pipeline/`: Part 1b Bronze and Silver, plus SQL helpers

| File | What it does |
|---|---|
| `bronze_load.py` | Lands the Assignment 2 CSV in S3 byte for byte, then copies both sources into the MySQL `bronze_*` tables with audit columns. |
| `silver_transform.py` | Runs the quality checks, quarantines failing rows with a reason, cleans and types the data, masks PII (HMAC-SHA256 tokens, email redaction, ZIP3) and joins weather on city and date. |
| `run_sql.py` | Runs a `.sql` file against the warehouse and prints every result set. |
| `profile_queries.py` | Runs `EXPLAIN ANALYZE` 3 times per query and reports the median of the warm runs. Used to find the most expensive query. |
| `common.py` | Shared helpers: database connection, SQL file splitting, logging. Reads the RDS password from AWS Secrets Manager at run time. |

### `sql/`: Parts 1b, 2 and 4a, in run order

| File | What it does |
|---|---|
| `01_medallion_ddl.sql` | Bronze and Silver staging tables, the quarantine table and the DQ log table. |
| `02_gold.sql` | Two Gold summary tables: daily returns by city and weather, and return rate by category, temperature band and weather. |
| `03_star_schema.sql` | Star schema DDL (1 fact, 6 dimensions) and the ELT that loads it from Silver. Grain: one row per order line. |
| `04_scd2_change.sql` | Simulates a loyalty tier upgrade (Silver to Gold) and shows the expired and active rows. |
| `05_analytical_queries.sql` | Part 2b queries Q1-Q5. |
| `06_optimization.sql` | The slowest query before, the summary table `mv_city_day_returns` that fixes it, and the same query after. |
| `07_showcase_queries.sql` | Part 4a queries S1-S3. |
| `warehouse.sql` | All of the above in one file. |

### `dynamodb/`: Parts 3 and 4b

| File | What it does |
|---|---|
| `create_table.py` | Creates `hw3-returns-lines` (on-demand) with PK `CUST#<user_id>`, SK `PURCHASE#<timestamp>#<order>#<sku>` and GSI1 keyed on `STYLE#<style_code>`. |
| `load_items.py` | Loads all 29,838 Silver order lines with `batch_writer`. |
| `queries.py` | Access patterns P1-P3 (Part 3) and showcase queries B1-B3 (Part 4b). Each one is a single Query or GetItem call, and the script prints the read units used. |

## Run order

Everything runs from the repo root except step 1. Install dependencies with `pip install -r ingestion/requirements.txt` plus `pandas`, `pymysql` and `sqlalchemy`. The Assignment 2 dataset is not in this repo: `bronze_load.py` expects it at `../HW2/apparel_returns_flat.csv` (set in `pipeline/common.py`).

1. `cd ingestion && python run_ingest.py` (needs `NOAA_TOKEN`)
2. `python pipeline/bronze_load.py`
3. `export PII_HASH_KEY=$(openssl rand -hex 32)`, then `python pipeline/silver_transform.py`
4. `python pipeline/run_sql.py sql/02_gold.sql sql/03_star_schema.sql sql/04_scd2_change.sql`
5. `python pipeline/run_sql.py sql/05_analytical_queries.sql`
6. `python pipeline/profile_queries.py sql/06_optimization.sql --plan`
7. `python dynamodb/create_table.py && python dynamodb/load_items.py`
8. `python dynamodb/queries.py`
9. `python pipeline/run_sql.py sql/07_showcase_queries.sql`

## Credentials

This repo contains no credentials. The NOAA token and the PII hashing key are read from environment variables. The RDS password is read from the RDS-managed secret in AWS Secrets Manager when the scripts connect, and it is never printed or saved. AWS access uses the local AWS CLI login.
