# Local StarRocks Lakehouse Mock

This project provides a fully localized mock of a Modern Data Stack (Lakehouse setup), running on your local machine using Docker and Python.

It simulates a data engineering pipeline consisting of:
1. **Source System**: A Python script generating financial telemetry data (Parquet formats).
2. **Object Storage**: A local mock S3-compatible server via [Moto](https://github.com/getmoto/moto).
3. **Data Warehouse (MPP)**: A standalone [StarRocks](https://www.starrocks.io/) analytical database reading directly from the mock S3 via its External Table / `FILES()` capabilities.
4. **Transformations**: Pre-aggregating dashboard queries natively within StarRocks using Asynchronous Materialized Views.

## Prerequisites

To run this demo, ensure your machine has the following tools installed and accessible from your terminal path:
- **Docker**: (Docker Desktop, OrbStack, or Colima) natively running to host the StarRocks daemon.
- **Python 3**: To run the virtual environment and mock generation scripts.
- **MySQL Client (`mysql`)**: To natively execute the SQL scripts and connect to the StarRocks interactive shell.

## Running the Demo

A helper shell script has been provided to build and test the infrastructure end-to-end.

From your terminal, execute:

```bash
chmod +x run_demo.sh
./run_demo.sh
```

### What `run_demo.sh` Does Under the Hood:
1. Pulls and launches the official `starrocks/allin1-ubuntu` container locally.
2. Initializes a lightweight Python `venv` and runs `moto_server` on port `5001`.
3. Calls `generate_data.py` to create 1,000 realistic rows of financial Parquet data and safely writes them to the mocked S3 bucket.
4. Uses `mysql` to load `setup_starrocks.sql` into the StarRocks container, standing up the Lakehouse table mappings and the pre-computed Materialized View.
5. Manually triggers a Materialized View synchronise and queries a sample to validate data flow.

## Connecting Manually

You can interact with the mock data natively using any standard MySQL client or standard SQL interfaces:

```bash
mysql -h 127.0.0.1 -P 9030 -u root
```
```sql
USE lakehouse;
SELECT * FROM client_daily_metrics LIMIT 10;
```
