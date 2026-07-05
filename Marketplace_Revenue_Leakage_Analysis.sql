/* =========================================================================
   MARKETPLACE REVENUE LEAKAGE & GAP ANALYSIS
   GUVI x HCL - BADM Capstone
   Author: Maheswary
   ========================================================================= */

/* -------------------------------------------------------------------------
   1. SCHEMA (DDL)
   ------------------------------------------------------------------------- */
CREATE TABLE products (
    product_id     TEXT PRIMARY KEY,
    product_name   TEXT NOT NULL,
    category       TEXT NOT NULL,
    cost_price     REAL NOT NULL,
    selling_price  REAL NOT NULL
);

CREATE TABLE orders (
    order_id        TEXT PRIMARY KEY,
    customer_id     TEXT NOT NULL,
    product_id      TEXT NOT NULL REFERENCES products(product_id),
    order_date      DATE NOT NULL,
    quantity        INTEGER NOT NULL,
    order_value     REAL NOT NULL,      -- total sale value (selling_price * qty)
    cost_value      REAL NOT NULL,      -- total cost value (cost_price * qty)
    payment_method  TEXT NOT NULL
);

CREATE TABLE discounts (
    order_id         TEXT REFERENCES orders(order_id),
    discount_amount  REAL NOT NULL,
    discount_pct     REAL
);

CREATE TABLE returns (
    order_id       TEXT REFERENCES orders(order_id),
    return_reason  TEXT NOT NULL
);

CREATE TABLE logistics_cost (
    order_id                TEXT REFERENCES orders(order_id),
    shipping_cost           REAL NOT NULL,
    reverse_shipping_cost   REAL NOT NULL DEFAULT 0
);

CREATE TABLE payment_fees (
    payment_method   TEXT PRIMARY KEY,
    fee_percentage   REAL NOT NULL
);

/* -------------------------------------------------------------------------
   2. CONSOLIDATED PROFITABILITY VIEW
   Every leakage source is joined back to order_id, the atomic grain,
   so a single view can answer all downstream business questions.
   ------------------------------------------------------------------------- */
CREATE VIEW order_financials AS
SELECT
    o.order_id, o.customer_id, o.product_id, p.category, o.order_date,
    o.payment_method, o.order_value, o.cost_value,
    COALESCE(d.discount_amount, 0)        AS discount_amount,
    COALESCE(l.shipping_cost, 0)          AS shipping_cost,
    COALESCE(l.reverse_shipping_cost, 0)  AS reverse_shipping_cost,
    CASE WHEN r.order_id IS NOT NULL THEN 1 ELSE 0 END AS is_returned,
    r.return_reason,
    ROUND(o.order_value * pf.fee_percentage / 100.0, 2) AS payment_fee
FROM orders o
JOIN products p        ON o.product_id = p.product_id
LEFT JOIN discounts d   ON o.order_id  = d.order_id
LEFT JOIN logistics_cost l ON o.order_id = l.order_id
LEFT JOIN returns r     ON o.order_id  = r.order_id
LEFT JOIN payment_fees pf ON o.payment_method = pf.payment_method;

CREATE VIEW order_profit AS
SELECT *,
    CASE WHEN is_returned = 1
        THEN ROUND(-cost_value - discount_amount - shipping_cost - reverse_shipping_cost - payment_fee, 2)
        ELSE ROUND(order_value - cost_value - discount_amount - shipping_cost - reverse_shipping_cost - payment_fee, 2)
    END AS net_profit
FROM order_financials;

/* -------------------------------------------------------------------------
   TASK 1: Revenue vs Profit Reality
   ------------------------------------------------------------------------- */
SELECT
    ROUND(SUM(order_value), 2) AS total_sales,
    ROUND(SUM(cost_value + discount_amount + shipping_cost + reverse_shipping_cost + payment_fee), 2) AS total_cost,
    ROUND(SUM(net_profit), 2) AS total_profit,
    ROUND(100.0 * SUM(net_profit) / SUM(order_value), 2) AS net_margin_pct
FROM order_profit;

/* -------------------------------------------------------------------------
   TASK 2: Category-wise Sales & Profit
   ------------------------------------------------------------------------- */
SELECT category,
    ROUND(SUM(order_value), 2) AS total_sales,
    ROUND(SUM(cost_value + discount_amount + shipping_cost + reverse_shipping_cost + payment_fee), 2) AS total_cost,
    ROUND(SUM(net_profit), 2) AS total_profit,
    ROUND(100.0 * SUM(net_profit) / SUM(order_value), 2) AS margin_pct
FROM order_profit
GROUP BY category
ORDER BY total_profit DESC;

/* -------------------------------------------------------------------------
   TASK 3: Loss-Making Products
   ------------------------------------------------------------------------- */
SELECT op.product_id, p.product_name, p.category,
    ROUND(SUM(op.net_profit), 2) AS total_profit,
    COUNT(*) AS order_count
FROM order_profit op
JOIN products p ON op.product_id = p.product_id
GROUP BY op.product_id
HAVING total_profit < 0
ORDER BY total_profit ASC;

/* -------------------------------------------------------------------------
   TASK 4: Discount Usage Overview
   ------------------------------------------------------------------------- */
SELECT
    (SELECT COUNT(*) FROM orders) AS total_orders,
    COUNT(discount_amount) AS discounted_orders,
    ROUND(100.0 * COUNT(discount_amount) / (SELECT COUNT(*) FROM orders), 2) AS pct_discounted,
    ROUND(SUM(discount_amount), 2) AS total_discount_amount
FROM discounts;

/* -------------------------------------------------------------------------
   TASK 5: Payment Method Popularity
   ------------------------------------------------------------------------- */
SELECT payment_method, COUNT(*) AS order_count, ROUND(SUM(order_value), 2) AS total_sales
FROM orders
GROUP BY payment_method
ORDER BY total_sales DESC;

/* -------------------------------------------------------------------------
   TASK 6: Discount vs Profit Gap
   ------------------------------------------------------------------------- */
SELECT CASE WHEN discount_amount > 0 THEN 'Discounted' ELSE 'Non-Discounted' END AS order_type,
    COUNT(*) AS order_count,
    ROUND(AVG(net_profit), 2) AS avg_profit_per_order,
    ROUND(AVG(order_value), 2) AS avg_order_value
FROM order_profit
GROUP BY order_type;

/* -------------------------------------------------------------------------
   TASK 7: Return Impact on Revenue
   ------------------------------------------------------------------------- */
SELECT COUNT(*) AS returned_orders,
    ROUND(SUM(order_value), 2) AS revenue_lost,
    ROUND(SUM(net_profit), 2) AS profit_impact_of_returned_orders
FROM order_profit
WHERE is_returned = 1;

/* -------------------------------------------------------------------------
   TASK 8: Return Reason Analysis
   ------------------------------------------------------------------------- */
SELECT return_reason, COUNT(*) AS return_count, ROUND(SUM(order_value), 2) AS revenue_lost
FROM order_profit
WHERE is_returned = 1
GROUP BY return_reason
ORDER BY revenue_lost DESC;

/* -------------------------------------------------------------------------
   TASK 9: Logistics Cost Burden (orders where logistics > 20% of order value)
   ------------------------------------------------------------------------- */
SELECT order_id, category, order_value, (shipping_cost + reverse_shipping_cost) AS logistics_cost,
    ROUND(100.0 * (shipping_cost + reverse_shipping_cost) / order_value, 2) AS logistics_pct
FROM order_profit
WHERE (shipping_cost + reverse_shipping_cost) > 0.20 * order_value
ORDER BY logistics_pct DESC;

/* -------------------------------------------------------------------------
   TASK 10: Payment Fee Leakage
   ------------------------------------------------------------------------- */
SELECT payment_method,
    COUNT(*) AS order_count,
    ROUND(SUM(payment_fee), 2) AS total_payment_fee,
    ROUND(SUM(net_profit), 2) AS net_profit_after_fee
FROM order_profit
GROUP BY payment_method
ORDER BY total_payment_fee DESC;

/* -------------------------------------------------------------------------
   TASK 11: Revenue Leakage Breakdown (per order + overall totals)
   ------------------------------------------------------------------------- */
-- Per-order leakage breakdown with dominant leakage factor
SELECT order_id,
    discount_amount,
    CASE WHEN is_returned = 1 THEN order_value ELSE 0 END AS return_leakage,
    (shipping_cost + reverse_shipping_cost) AS logistics_leakage,
    payment_fee,
    CASE
        WHEN discount_amount >= GREATEST(CASE WHEN is_returned=1 THEN order_value ELSE 0 END,
                                          shipping_cost+reverse_shipping_cost, payment_fee) THEN 'Discount'
        WHEN CASE WHEN is_returned=1 THEN order_value ELSE 0 END >= GREATEST(discount_amount,
                                          shipping_cost+reverse_shipping_cost, payment_fee) THEN 'Return'
        WHEN (shipping_cost+reverse_shipping_cost) >= GREATEST(discount_amount,
                                          CASE WHEN is_returned=1 THEN order_value ELSE 0 END, payment_fee) THEN 'Logistics'
        ELSE 'Payment Fee'
    END AS dominant_leakage_factor
FROM order_profit;

-- Overall leakage totals by factor
SELECT
    ROUND(SUM(discount_amount), 2) AS total_discount_leakage,
    ROUND(SUM(CASE WHEN is_returned = 1 THEN order_value ELSE 0 END), 2) AS total_return_leakage,
    ROUND(SUM(shipping_cost + reverse_shipping_cost), 2) AS total_logistics_leakage,
    ROUND(SUM(payment_fee), 2) AS total_payment_fee_leakage
FROM order_profit;

/* -------------------------------------------------------------------------
   TASK 12: Product Profit Ranking
   ------------------------------------------------------------------------- */
SELECT op.product_id, p.product_name, p.category,
    ROUND(SUM(op.net_profit), 2) AS total_profit,
    RANK() OVER (ORDER BY SUM(op.net_profit) DESC) AS profit_rank
FROM order_profit op
JOIN products p ON op.product_id = p.product_id
GROUP BY op.product_id
ORDER BY total_profit DESC;

/* -------------------------------------------------------------------------
   TASK 13: Category Margin Stability
   ------------------------------------------------------------------------- */
WITH order_margin AS (
    SELECT category, 100.0 * net_profit / order_value AS margin_pct
    FROM order_profit
)
SELECT category,
    ROUND(AVG(margin_pct), 2) AS avg_margin_pct,
    ROUND(SQRT(AVG(margin_pct*margin_pct) - AVG(margin_pct)*AVG(margin_pct)), 2) AS stddev_margin_pct
FROM order_margin
GROUP BY category
ORDER BY stddev_margin_pct DESC;

/* -------------------------------------------------------------------------
   TASK 14: High-Risk Customers (return rate significantly above marketplace average)
   ------------------------------------------------------------------------- */
WITH marketplace_avg AS (
    SELECT 100.0 * SUM(is_returned) / COUNT(*) AS avg_return_rate FROM order_profit
),
customer_returns AS (
    SELECT customer_id, COUNT(*) AS total_orders, SUM(is_returned) AS returned_orders,
        ROUND(100.0 * SUM(is_returned) / COUNT(*), 2) AS return_rate_pct
    FROM order_profit
    GROUP BY customer_id
    HAVING total_orders >= 3
)
SELECT cr.*
FROM customer_returns cr, marketplace_avg ma
WHERE cr.return_rate_pct > ma.avg_return_rate + 20
ORDER BY return_rate_pct DESC;

/* -------------------------------------------------------------------------
   TASK 15: Executive Profitability Summary
   ------------------------------------------------------------------------- */
SELECT
    ROUND(SUM(order_value), 2) AS total_sales,
    ROUND(SUM(net_profit), 2) AS total_profit,
    ROUND(SUM(discount_amount), 2) AS total_discounts,
    ROUND(SUM(CASE WHEN is_returned = 1 THEN order_value ELSE 0 END), 2) AS total_returns_loss,
    ROUND(SUM(shipping_cost + reverse_shipping_cost), 2) AS total_logistics_cost,
    ROUND(SUM(payment_fee), 2) AS total_payment_fees
FROM order_profit;
