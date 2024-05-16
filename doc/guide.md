# Getting Started with the timeseries Extension

In this guide, you will become familiar with the functions and features of the timeseries extension through a hands-on tutorial using public bikeshare trip data from the Chicago bike share system, Divvy.

## Preparing your database

You'll need a PostgreSQL instance running timeseries `0.1.4` or later. An easy way to have one set up for you is to deploy one from Tembo Cloud [here](https://cloud.tembo.io). The free tier will perform well enough for the data set we'll be using.

Once that's up and running, you'll need a client machine with `psql` (to connect to your database) and [the Divvy dataset](https://tembo-demo-bucket.s3.amazonaws.com/202004--202402-divvy-tripdata-slim.csv.gz), which will total about 50MiB of CSV after decompression.

_Note: If you'd like a larger data set, the above set is a downsampled version of [this file](https://tembo-demo-bucket.s3.amazonaws.com/202004--202402-divvy-tripdata-full.csv.gz), which covers the same time range but has 75 times as many trips._

### Getting `psql`

If you need help installing `psql`, finding instructions for you platform should be relatively straightforward:

  * Mac — Homebrew's `libpq` package includes `psql`
  * Ubuntu/Debian — the `postgresql-client` apt package provides `psql`
  * Windows — [EDB's installers](https://www.postgresql.org/download/windows/) can help

### Create the time-series table

Since we're starting from scratch, begin by making an empty table. We'll load the data into this shortly using a `\copy` command, after which point our application could continue to `INSERT` new trips in an ongoing fashion.

The `timeseries` extension requires three things of your table. It must:

  * Use PostgreSQL's `PARTITION BY RANGE` syntax to declare itself as partitioned
  * Specify a column with a time type as the partition key (`date`, `timestamp`, `timestamptz`)
  * Restrict the partition column to reject `NULL` values (i.e. include `NOT NULL`)

The data set we're using will fit naturally into the following schema:

```sql
CREATE TABLE IF NOT EXISTS
  divvy_trips (
    ride_id text NOT NULL,
    rideable_type text NULL,
    started_at timestamp NOT NULL,
    ended_at timestamp NOT NULL,
    start_station_name text,
    start_station_id text,
    end_station_name text,
    end_station_id text,
    start_lat float,
    start_lng float,
    end_lat float,
    end_lng float,
    member_casual text
  ) PARTITION BY RANGE (started_at);
```

After creating the table, enhancing it with time-series capabilities can be done with a call to `enable_ts_table`. The only required argument is the table name, but optional parameters are also available:

  * `partition_duration` — the size or "width" of each partition, expressed as an `INTERVAL`. Defaults to one week
  * `partition_lead_time` — how far into the future to "premake" new partitions, expressed as an `INTERVAL`. Defaults to one month
  * `initial_table_start` — a`timestamptz` used to determine the start of the table's first partition. Omit this except when backfilling data into a new table

We're doing a backfill, and aur data set goes back _almost_ to 2019, so `2020-01-01T00:00:00Z` will work as `initial_table_start`.

For our purposes, I can tell you that a partition width of `1 month` will perform well enough. `partition_duration` is probably the configuration option that will most affect performance: the next subsection will cover this briefly.

Knowing all this, we can engage time-series behavior for our table:

```sql
SELECT enable_ts_table(
  'divvy_trips',
  partition_duration := '1 month',
  initial_table_start := '2020-01-01');
```

#### Performance and Partition Size

It's a good rule of thumb that a partition fit in memory (indexes and all). In fact, for flexibility, it's best that something like three to five do, for each time-series table in the active workload.

This tutorial will not reflect real-world use (where our analytic queries must live alongside a stream of `INSERT`s), and there is a balance to be struck between having a partition small enough that it remains resident and having it so large the working set thrashes the page cache, so you will need to benchmark scenarios for your specific application.

### Add appropriate indexes

For the queries you'll perform during this tutorial, the following indexes are recommended.

```sql
CREATE INDEX ON divvy_trips (started_at DESC);
CREATE INDEX ON divvy_trips (start_station_id, started_at DESC);
CREATE INDEX ON divvy_trips (end_station_id, ended_at DESC);
CREATE INDEX ON divvy_trips (rideable_type, started_at DESC);
```

For a backfill like this it's probably going to save some time to create index _after_ data is loaded, but we'll eat that cost in order to discuss the convenience views provided by `timeseries`.

## Timeseries table information

Because viewing the sizes of the data and indexes of a partitioned table can be unwieldy in PostgreSQL (and often requires filtering out irrelevant other tables), `timeseries` provides three relations for viewing information about the tables it manages.

### `ts_config` — time-series config

This table stores information about how time-series tables were created and is queried or modified by `timeseries`' code any time its functions are called. Here's how it should look for us:

```sql
SELECT * FROM ts_config;
```
```
┌─[ RECORD 1 ]────────┬─────────────┐
│ table_id            │ divvy_trips │
│ partition_duration  │ 1 mon       │
│ partition_lead_time │ 1 mon       │
│ retention_duration  │ ∅           │
└─────────────────────┴─────────────┘
```

`retention_duration` specifies when to drop old data. We'll come to that later.

### `ts_table_info` — time-series table info

If you need a "big picture" of the data and index usage for your time-series table, check this view: it contains columns that sum across all partitions. Throw this value into a monitoring system to keep on top of your total disk usage for each time-series table.

```sql
SELECT * FROM ts_table_info;
```
```
┌─[ RECORD 1 ]─────┬─────────────┐
│ table_id         │ divvy_trips │
│ table_size_bytes │ 434176      │
│ index_size_bytes │ 1736704     │
│ total_size_bytes │ 2170880     │
└──────────────────┴─────────────┘
```

_Hint: these views keep the sizes as numeric types, which makes arithmetic and aggregation easier at the cost of human-readability. Rewrite the above query using [`pg_size_pretty`](https://www.postgresql.org/docs/current/functions-admin.html#id-1.5.8.33.9.3.2.2.7.1.1.1) to add e.g. `GB`, `MB` suffixes, if you wish_.

### `ts_part_info` — time-series partition info

When picking `partition_duration`, it is crucial to double-check your work using this view. It's essentially identical to the table-based view (in fact, it feeds it), but shows data on a per-partition basis.

```sql
SELECT * FROM ts_part_info;
```
```
┌─[ RECORD 1 ]─────┬────────────────────────────────────────────┐
│ table_id         │ divvy_trips                                │
│ part_id          │ divvy_trips_p20200101                      │
│ part_range       │ FOR VALUES FROM ('2020-01-01 00:00:00-07')…│
│                  │… TO ('2020-02-01 00:00:00-07')             │
│ table_size_bytes │ 8192                                       │
│ index_size_bytes │ 32768                                      │
│ total_size_bytes │ 40960                                      │
├─[ RECORD 2 ]─────┼────────────────────────────────────────────┤
│ table_id         │ divvy_trips                                │
│ part_id          │ divvy_trips_p20200201                      │
│ part_range       │ FOR VALUES FROM ('2020-02-01 00:00:00-07')…│
│                  │… TO ('2020-03-01 00:00:00-07')             │
│ table_size_bytes │ 8192                                       │
│ index_size_bytes │ 32768                                      │
│ total_size_bytes │ 40960                                      │
├─[ ...   ... ]────┼────────────────────────────────────────────┤
│ (add'l records)  │ (add'l records)                            │
├─[ RECORD XX ]────┼────────────────────────────────────────────┤
│ table_id         │ divvy_trips                                │
│ part_id          │ divvy_trips_default                        │
│ part_range       │ DEFAULT                                    │
│ table_size_bytes │ 8192                                       │
│ index_size_bytes │ 32768                                      │
│ total_size_bytes │ 40960                                      │
└──────────────────┴────────────────────────────────────────────┘
```

We'll return to these after loading our data.

## Load and inspect data

Decompress the data file if you have not already done so:

```shell
gzip -d 202004--202402-divvy-tripdata-slim.csv.gz
```

The CSV should load with a simple `\copy` command.

```sql
\copy divvy_trips from '202004--202402-divvy-tripdata-slim.csv' with (header on, format csv);
```
```
COPY 272873
```

### Bulk load considerations

There are important considerations in the bulk-loading of data which can improve both ingestion time and post-ingest query performance, but they apply equally to most PostgreSQL data loads and so are out of scope for this document. Search for information about how to best configure WAL, indexes, and how to order the data itself for more.

### Inspect informational views

Let's check the table size now:

```sql
SELECT
  table_id,
  pg_size_pretty(table_size_bytes) AS table_size,
  pg_size_pretty(index_size_bytes) AS index_size,
  pg_size_pretty(total_size_bytes) AS total_size
  FROM ts_table_info;
```
```
┌─────────────┬────────────┬────────────┬────────────┐
│  table_id   │ table_size │ index_size │ total_size │
├─────────────┼────────────┼────────────┼────────────┤
│ divvy_trips │ 59 MB      │ 49 MB      │ 108 MB     │
└─────────────┴────────────┴────────────┴────────────┘
```

All right, we're looking at about 100 megs, split somewhat evenly between indexes and data. But are the partitions similar sizes?

```sql
SELECT
  part_range,
  pg_size_pretty(total_size_bytes) AS part_size
  FROM ts_part_info
  ORDER BY total_size_bytes DESC
  LIMIT 5;
```
```
┌─────────────────────────────────────────────────────────┬───────────┐
│                             part_range                  │ part_size │
├─────────────────────────────────────────────────────────┼───────────┤
│ FROM ('2021-07-01 00:00:00') TO ('2021-08-01 00:00:00') │ 4056 kB   │
│ FROM ('2021-08-01 00:00:00') TO ('2021-09-01 00:00:00') │ 3904 kB   │
│ FROM ('2022-07-01 00:00:00') TO ('2022-08-01 00:00:00') │ 3896 kB   │
│ FROM ('2021-09-01 00:00:00') TO ('2021-10-01 00:00:00') │ 3808 kB   │
│ FROM ('2022-08-01 00:00:00') TO ('2022-09-01 00:00:00') │ 3768 kB   │
└─────────────────────────────────────────────────────────┴───────────┘
```

The largest appear to be roughly 4MiB and covering time ranges in the summer. But the smallest? Note the `WHERE` clause needed to filter out entirely empty partitions (which are related to the size of empty tables and indexes).

```sql
SELECT
  part_range,
  pg_size_pretty(total_size_bytes) AS part_size
  FROM ts_part_info
  WHERE total_size_bytes > pg_size_bytes('100kB')
  ORDER BY total_size_bytes ASC
  LIMIT 5;
```
```
┌─────────────────────────────────────────────────────────┬───────────┐
│                             part_range                  │ part_size │
├─────────────────────────────────────────────────────────┼───────────┤
│ FROM ('2021-02-01 00:00:00') TO ('2021-03-01 00:00:00') │ 384 kB    │
│ FROM ('2020-04-01 00:00:00') TO ('2020-05-01 00:00:00') │ 488 kB    │
│ FROM ('2021-01-01 00:00:00') TO ('2021-02-01 00:00:00') │ 592 kB    │
│ FROM ('2022-01-01 00:00:00') TO ('2022-02-01 00:00:00') │ 632 kB    │
│ FROM ('2022-02-01 00:00:00') TO ('2022-03-01 00:00:00') │ 664 kB    │
└─────────────────────────────────────────────────────────┴───────────┘
```

These are fully ten times smaller than the largest, in several cases. While not exactly surprising that a bike share in Chicago sees less utilization in January and February (and during the onset of the COVID-19 lockdown), it's neat to see the seasonality of this data in the partition sizes themselves.

### `EXPLAIN` partition pruning

Before we begin writing more complex theories, let's see what the planner comes up with for a count of queries during a certain quarter…

```sql
SELECT COUNT(*)
  FROM divvy_trips
  WHERE started_at > '2022-01-01'
  AND started_at < '2022-04-01';
```
```
┌───────┐
│ count │
├───────┤
│ 6712  │
└───────┘
```

This took less than 40ms on my install. How does that work?

```sql
EXPLAIN SELECT COUNT(*)
  FROM divvy_trips
  WHERE started_at > '2022-01-01'
  AND started_at < '2022-04-01';
```
```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                       QUERY PLAN                                       │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Aggregate  (cost=301.02..301.03 rows=1 width=8)                                        │
│   ->  Append  (cost=0.00..284.24 rows=6712 width=0)                                    │
│         ->  Seq Scan on divvy_trips_p20220101 divvy_trips_1  (cost=0.00..52.76 rows=13…│
│…84 width=0)                                                                            │
│               Filter: ((started_at > '2022-01-01 00:00:00'::timestamp without time zon…│
│…e) AND (started_at < '2022-04-01 00:00:00'::timestamp without time zone))              │
│         ->  Seq Scan on divvy_trips_p20220201 divvy_trips_2  (cost=0.00..57.11 rows=15…│
│…41 width=0)                                                                            │
│               Filter: ((started_at > '2022-01-01 00:00:00'::timestamp without time zon…│
│…e) AND (started_at < '2022-04-01 00:00:00'::timestamp without time zone))              │
│         ->  Seq Scan on divvy_trips_p20220301 divvy_trips_3  (cost=0.00..140.81 rows=3…│
│…787 width=0)                                                                           │
│               Filter: ((started_at > '2022-01-01 00:00:00'::timestamp without time zon…│
│…e) AND (started_at < '2022-04-01 00:00:00'::timestamp without time zone))              │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

There's a lot going on here, but the important thing to note is that only three partitions are referenced by this plan.

That's what we expect, but it's good to see.

## Digging into the data

With our data loaded up, we're ready for some more interesting queries. Start by figuring out which days of the week had the most rides in 2023. The `dow` option to `extract` starts the week at `0` on Sunday.

```sql
SELECT
  extract(dow from started_at) AS weekday_idx,
  COUNT(*) AS total_rides FROM divvy_trips
  WHERE started_at BETWEEN '2023-01-01' AND '2024-01-01'
  GROUP BY weekday_idx
  ORDER BY weekday_idx;
```
```
┌─────────────┬─────────────┐
│ weekday_idx │ total_rides │
├─────────────┼─────────────┤
│           0 │        9890 │
│           1 │        9820 │
│           2 │       11166 │
│           3 │       11099 │
│           4 │       11327 │
│           5 │       11283 │
│           6 │       11680 │
└─────────────┴─────────────┘
```

It's pretty clear ridership falls on Sundays and Mondays but really picks up going into the weekends. What about hourly trends? Which stations have the highest ridership during the mornings? Because of more modern stationless bikes, not all rides have an originating station, so we need to include a filter for that.

```sql
SELECT
  start_station_id,
  COUNT(*) as checkouts
  FROM divvy_trips
  WHERE start_station_id IS NOT NULL
  AND started_at BETWEEN '2023-01-01' AND '2024-01-01'
  AND date_part('hour', started_at) BETWEEN 6 AND 10
  GROUP BY start_station_id ORDER BY checkouts DESC limit 10;
```
```
┌──────────────────┬───────────┐
│ start_station_id │ checkouts │
├──────────────────┼───────────┤
│ TA1307000039     │       150 │
│ WL-012           │       143 │
│ KA1503000043     │       121 │
│ TA1305000032     │       115 │
│ 638              │       112 │
│ 13011            │       111 │
│ TA1306000003     │        92 │
│ SL-005           │        90 │
│ 13146            │        90 │
│ 13137            │        88 │
└──────────────────┴───────────┘
```

This could be useful information when deciding where to redeploy bikes from maintenance holds overnight going into the morning rush. Let's compare this to the most popular endpoints during evening hours…

```sql
SELECT
  end_station_id,
  COUNT(*) as checkins
  FROM divvy_trips
  WHERE end_station_id IS NOT NULL
  AND started_at BETWEEN '2023-01-01' AND '2024-01-01'
  AND date_part('hour', started_at) BETWEEN 17 AND 21
  GROUP BY end_station_id ORDER BY checkins DESC limit 10;
```
```
┌────────────────┬──────────┐
│ end_station_id │ checkins │
├────────────────┼──────────┤
│ LF-005         │      213 │
│ 13022          │      213 │
│ TA1308000050   │      176 │
│ KA1504000135   │      166 │
│ 13137          │      162 │
│ TA1307000039   │      153 │
│ 13300          │      134 │
│ 13146          │      132 │
│ 13179          │      131 │
│ TA1307000134   │      131 │
└────────────────┴──────────┘
```

While this list shares _some_ elements with the morning hot spots, there are several stations here to consider as sources for bicycles that will be needed elsewhere the next day.

What about the adoption and use of the different kinds of bicycles? This query is hand-written to perform a pivot for the sake of output readability:

```sql
SELECT
  date_trunc('month', started_at)::date AS month,
  SUM(CASE WHEN rideable_type = 'classic_bike' THEN 1 ELSE 0 END) AS classic,
  SUM(CASE WHEN rideable_type = 'docked_bike' THEN 1 ELSE 0 END) AS docked,
  SUM(CASE WHEN rideable_type = 'electric_bike' THEN 1 ELSE 0 END) AS electric
  FROM divvy_trips
  WHERE started_at BETWEEN '2022-01-01' AND '2023-01-01'
  GROUP BY month
  ORDER BY month ASC;
```
```
┌────────────┬─────────┬────────┬──────────┐
│   month    │ classic │ docked │ electric │
├────────────┼─────────┼────────┼──────────┤
│ 2022-01-01 │     750 │     15 │      619 │
│ 2022-02-01 │     770 │     34 │      737 │
│ 2022-03-01 │    1824 │    105 │     1858 │
│ 2022-04-01 │    2200 │    176 │     2574 │
│ 2022-05-01 │    4318 │    375 │     3772 │
│ 2022-06-01 │    5478 │    366 │     4412 │
│ 2022-07-01 │    4978 │    426 │     5576 │
│ 2022-08-01 │    4598 │    370 │     5511 │
│ 2022-09-01 │    4070 │    253 │     5028 │
│ 2022-10-01 │    2849 │    168 │     4432 │
│ 2022-11-01 │    1933 │     88 │     2482 │
│ 2022-12-01 │     987 │     30 │     1408 │
└────────────┴─────────┴────────┴──────────┘
```

We probably want some insight into the duration of rides. Let's generate a table of deciles…

```sql
WITH rides AS (
  SELECT (ended_at - started_at) AS duration
  FROM divvy_trips
  WHERE ended_at > started_at
  AND started_at BETWEEN '2023-01-01' AND '2024-01-01'
), deciles AS (
  SELECT rides.duration AS duration,
  ntile(10) OVER (ORDER BY rides.duration) AS decile FROM rides
) SELECT (10 * decile) AS "%ile",
  MAX(duration) AS duration
  FROM deciles
  GROUP BY decile
  ORDER BY decile ASC;
```
```
┌──────┬─────────────────┐
│ %ile │    duration     │
├──────┼─────────────────┤
│   10 │ 00:03:13        │
│   20 │ 00:04:42        │
│   30 │ 00:06:07        │
│   40 │ 00:07:40        │
│   50 │ 00:09:31        │
│   60 │ 00:11:45        │
│   70 │ 00:14:43        │
│   80 │ 00:19:32        │
│   90 │ 00:28:50        │
│  100 │ 8 days 21:20:39 │
└──────┴─────────────────┘
```

The 100th percentile is likely bad data, but the rest is interesting! Most rides are under ten minutes, but one in ten exceeds a half-hour. Putting this in to a `MATERIALIZED VIEW` and refreshing it weekly might make a nice source for an office dashboard or other visualization.

## Configuring retention

Up until now we've been exploring older data, but in a timeseries system it's usually the case that new data is always being appended to a main table and older data either rolls off to long-term storage or is dropped entirely.

Rolling off onto other storage methods is a feature on the roadmap for `timeseries`, but is not yet available; however, if simply dropping the data satisfies your use case, a retention policy can be easily configued with a single call:

```sql
SELECT set_ts_retention_policy('divvy_trips', '2 years');
```
```
┌─────────────────────────┐
│ set_ts_retention_policy │
├─────────────────────────┤
│ ∅                       │
└─────────────────────────┘
```

This function returns the retention policy for the specified table and returns the value of the old policy (here `NULL`, since by default none was set when we initially set up this table). Data is not dropped immediately, but every time the maintenance function runs (once an hour), any partitions entirely older than the cutoff will be dropped.

We can force a maintenance cycle and verify partitions were dropped like so:

```sql
SELECT run_maintenance();
```
```
┌─────────────────┐
│ run_maintenance │
├─────────────────┤
│                 │
└─────────────────┘
```
```sql
SELECT COUNT(*) = 0 AS data_gone
FROM divvy_trips
WHERE started_at < (now() - INTERVAL '25 months');
```
```
┌───────────┐
│ data_gone │
├───────────┤
│ t         │
└───────────┘
```

_Note: the above query uses `25 months` rather than `2 years` because it is likely that the moment exactly two years ago occurs somewhere in the middle of a partition, meaning that partition should not be dropped yet. The partition containing the point 25 months ago will definitely be dropped._
