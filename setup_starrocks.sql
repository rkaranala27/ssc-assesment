CREATE DATABASE IF NOT EXISTS lakehouse;
USE lakehouse;

DROP MATERIALIZED VIEW IF EXISTS client_daily_metrics;
DROP TABLE IF EXISTS base_events;

CREATE TABLE IF NOT EXISTS base_events (
    client_id VARCHAR(65533),
    fund_id VARCHAR(65533),
    as_of_date DATE,
    metric_name VARCHAR(65533),
    metric_value DOUBLE
) 
ENGINE=OLAP
DUPLICATE KEY(client_id, fund_id, as_of_date)
PARTITION BY date_trunc('day', as_of_date)
DISTRIBUTED BY HASH(client_id) BUCKETS 3
PROPERTIES (
    "replication_num" = "1"
);

CREATE MATERIALIZED VIEW client_daily_metrics
DISTRIBUTED BY HASH(client_id) BUCKETS 3
PROPERTIES(
    "replication_num" = "1"
)
AS
SELECT 
    client_id, 
    as_of_date, 
    metric_name, 
    SUM(metric_value) as total_value
FROM base_events
GROUP BY client_id, as_of_date, metric_name;

-- Insert data
INSERT INTO base_events (client_id, fund_id, as_of_date, metric_name, metric_value)
SELECT 
    client_id, 
    fund_id, 
    CAST(as_of_date AS DATE), 
    metric_name, 
    CAST(metric_value AS DOUBLE)
FROM FILES(
    "path" = "s3a://lakehouse-data-v2/data/*.parquet",
    "format" = "parquet",
    "aws.s3.endpoint" = "http://host.docker.internal:5001",
    "aws.s3.access_key" = "test",
    "aws.s3.secret_key" = "test",
    "aws.s3.enable_path_style_access" = "true"
);
