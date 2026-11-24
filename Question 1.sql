-- Q1(a) Tables & Seed Data
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(120) NOT NULL,
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL,
    new_qty     INTEGER NOT NULL,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL DEFAULT 0 CHECK (total_qty >= 0),
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0)
);

-- Q1(b) Function: fn_sale_value
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive, got %', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN ROUND(v_price * p_quantity, 2);
END;
$$;

-- Q1(c) Procedure: pr_record_sale
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INT,
    p_quantity    INT,
    p_sold_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive, got %', p_quantity;
    END IF;

    SELECT unit_price, stock_qty
    INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: available %, requested %',
            p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- Q1(d) Trigger: AFTER UPDATE on medicines.stock_qty
CREATE OR REPLACE FUNCTION fn_trg_medicines_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, NOW());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION fn_trg_medicines_stock_audit();

-- Seed medicines & 6 valid sales via procedure
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Amoxicillin 500mg', 25.00, 18),
    ('Paracetamol 500mg', 10.00, 50),
    ('Ibuprofen 400mg', 15.50, 12);

CALL pr_record_sale(1, 5, CURRENT_DATE - 1);
CALL pr_record_sale(1, 4, CURRENT_DATE - 1);
CALL pr_record_sale(2, 10, CURRENT_DATE - 1);
CALL pr_record_sale(2, 8, CURRENT_DATE);
CALL pr_record_sale(3, 4, CURRENT_DATE);
CALL pr_record_sale(3, 2, CURRENT_DATE);

-- Q1(e) View & Query
CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;

-- Q1(f) Composite Index & EXPLAIN
-- Justifies filtering equality on medicine_id and range scan on sold_on
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
-- Expected plan node: Index Scan using idx_sales_medicine_sold_on on sales

-- Q1(g) Procedure & Scheduled Job (00:15 daily for previous day)
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_qty    INTEGER;
    v_amount NUMERIC(12, 2);
BEGIN
    SELECT
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(quantity * unit_price), 0.00)
    INTO v_qty, v_amount
    FROM sales
    WHERE sold_on = p_day;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_qty, v_amount)
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Requires pg_cron extension
SELECT cron.schedule(
    'refresh_daily_sales',
    '15 0 * * *',
    $$CALL pr_refresh_sales((CURRENT_TIMESTAMP AT TIME ZONE 'Africa/Lusaka')::date - 1);$$
);