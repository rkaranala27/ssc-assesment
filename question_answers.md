# Data Pipeline System Design Answers

## 1. Object Storage Layout

### Directory / Prefix Structure
I would organize the data using Hive-style partitions based on the transaction date:
`s3://lakehouse/data/as_of_date=<YYYY-MM-DD>/`
Since the data is appending at a rate of ~500 million rows per year (about 1.3 million rows per day), keeping the prefix structure limited to just the date ensures we don't end up with thousands of tiny, heavily-nested directories.

### Partitioning Strategy
Partitioning by `as_of_date` is the most effective strategy here because almost all queries filter by a date range. This allows the query engine (StarRocks) to immediately prune the files it needs to scan at the S3 level without reading unnecessary data. 

Inside the partition, I would sort/cluster the files by `client_id` (and optionally `fund_id`) as the secondary access pattern.

### File formats
I would strictly use **Parquet**. It provides columnar storage which is critical for MPP analytical queries, allowing the engine to only project the specific columns requested (e.g. `metric_value`) instead of reading entire rows.

### Handling late or reprocessed data
Because the dataset is append-only with no updates or deletes, the easiest way to handle late data is to overwrite the entire daily partition. If an upstream system sends delayed data, simply drop the existing `s3://.../as_of_date=X/` prefix and re-write the Parquet file with the corrected complete day of data. Alternatively, using an open table format like **Apache Iceberg** would allow atomic snapshot commits for late data inserts without locking readers.

---

## 2. MPP Table Design

### Partition keys
The StarRocks table should mirror the S3 layout and partition by `date_trunc('day', as_of_date)`. This enables StarRocks to instantly eliminate entire partition tablets during range queries.

### Distribution / bucketing strategy
The table should be Hash Distributed by `client_id` into a fixed number of buckets (e.g., `DISTRIBUTED BY HASH(client_id) BUCKETS 32`). 
Because almost all queries filter by `client_id`, StarRocks can route the query directly to the physical node that holds that client's bucket (Local Colocation), bypassing the need to broadcast large datasets across the network.

### Sort or clustering choices
The primary sort key (or `DUPLICATE KEY` in StarRocks) should be `(client_id, fund_id, as_of_date)`.
Since the queries filter by `client_id` and `fund_id`, placing them first in the sort tree allows StarRocks to use its sparse index to rapidly seek to the exact block of rows for a given client within a given date partition.

### Duplicate vs primary key-style designs
I would use the **Duplicate Key** model. The requirements state the data is "Append-only (no updates or deletes)". Primary Key models incur significant background overhead to maintain the primary key index and handle upserts. The Duplicate Key model is the most performant for raw, immutable event ledgers.

---

## 3. API & Query Design

### Safe vs unsafe query patterns
- **Safe:** Queries that mandate a specific `client_id` and a bounded `as_of_date` range (e.g. maximum 30 days).
- **Unsafe:** `SELECT *` without filters, queries over multi-year date ranges without aggregation, or omitting the `client_id` which forces a full cluster broadcast. The API layer should reject unsafe patterns.

### Pagination strategies
Offset-based pagination (`OFFSET X LIMIT Y`) becomes extremely slow on large datasets because the MPP engine still has to compute the sorted offset. 
Instead, the API should use **Cursor-based pagination** (e.g., passing a `last_seen_date` and `last_seen_id` back in the API response and querying `WHERE as_of_date >= last_seen_date AND ... LIMIT 100`).

### Avoiding full table scans
Ensure the API never issues queries without partition bounds. Additionally, for repeating aggregates (e.g., "Total AUM per client"), the API shouldn't query the base table. It should query a pre-computed **Asynchronous Materialized View** inside StarRocks.

### Handling large aggregations
Large aggregations (e.g., `SUM(metric_value)` across 5 years of data) will bottleneck CPU and memory. 
I would offload this by creating a **Materialized View** that rolls up the metrics to a daily or monthly level per `client_id` and `metric_name`. The API then simply queries the pre-computed summary table, responding in milliseconds.

---

## 4. Failure Modes & Operations

### Data skew
If a single massive "Whale" client produces 80% of the data, hashing by `client_id` will send all the data to a single server, causing OOM errors. 
**Mitigation:** Add `fund_id` to the distribution key `HASH(client_id, fund_id)`, or use a composite hash by combining `client_id` with `metric_name` to spread the whale across nodes.

### Partition explosion
If partitioning by hour or minute, S3 will hit a rate limit trying to list directories, and StarRocks metadata planning will choke.
**Mitigation:** Stick to daily or monthly partitions. Combine smaller granularities into larger chunks.

### Small file problems
Streaming append-only data every 5 minutes will result in millions of kilobyte-sized Parquet files, ruining S3 read performance and exhausting StarRocks inodes. 
**Mitigation:** Run a background compaction job (or use Iceberg's compaction) to periodically merge tiny 5-minute files into large 256MB+ blocks.

### Query latency regression
As the `base_events` table grows, API latencies will naturally creep up. 
**Mitigation:** Heavily lean on Materialized Views for the API, and monitor the cache hit rates. Use Bitmap indexes on low-cardinality flags if they exist.

### Cost growth
Storing years of raw Parquet data in S3 Standard will get expensive. 
**Mitigation:** Implement an S3 Lifecycle policy to move partitions older than 1 year to S3 Glacier/Deep Archive. We can remove these older partitions from StarRocks dynamically when they age out, keeping only the aggregated Materialized View data hot.

---

## 5. Scale Thought Experiment

Assume data volume grows **10× over two years** (from 500 million to 5 billion rows/year).

### What breaks first?
1. **Metadata Overhead:** If we are generating thousands of tiny files a day, scaling 10x will absolutely destroy S3 directory listing speeds and the StarRocks Query Planner, leading to multi-second pure compilation delays.
2. **Materialized View Refresh Times:** If the MV is a full rewrite instead of incremental, a 10x growth will make it impossible to refresh the metrics asynchronously within a reasonable SLA.

### What would you change?
1. **Aggressive Compaction:** I would implement a strict daily compaction job that guarantees only 1 large Parquet file exists per partition per bucket.
2. **Monthly Partitions:** I would migrate the partition scheme from Daily (`YYYY-MM-DD`) to Monthly (`YYYY-MM`) if the file sizes justify it.
3. **Incremental Materialized Views:** I would transition the Materialized Views to be strictly incremental (e.g., using Iceberg/StarRocks native incremental refreshes) so they only process new data. 
4. **Data Tiering:** I would enforce strict cold-data eviction rules so the APIs primarily serve data from the last 12-24 months out of hot local storage.
