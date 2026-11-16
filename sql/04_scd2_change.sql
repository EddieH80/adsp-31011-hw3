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
