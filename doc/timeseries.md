# Tembo Time-Series API

The purpose of this extension is to provide a cohesive user experience around the creation, maintenance, and use of time-series tables.

## Getting Started

This extension relies on the presence and configuration of `pg_partman`. Once you have determined which table needs time-series enhancement, simply call the `enable_ts_table` function with your table name and the name of the column that stores the time for each row:

```sql
SELECT enable_ts_table('sensor_readings');
```

With this one call, several things will happen:

  * The table will be restructred as a series of partitions using PostgreSQL's [native PARTITION features](https://www.postgresql.org/docs/current/ddl-partitioning.html)
  * Each partition covers a particular range of time (one week by default)
  * New partitions will be created for some time in the future (one month by default)
  * Once an hour, a maintenance job will create any missing partitions as well as needed future ones

## Using your tables

So you've got a table. Now what?

### Indexes

The time-series tables you create start out life as little more than typical [partitioned PostgreSQL tables](https://www.postgresql.org/docs/current/ddl-partitioning.html). But this simplicity also means all of PostgreSQL's existing functionality will "just work" with them. A fairly important piece of a time-series table is an index along the time dimension.

[Traditional B-Tree indexes](https://www.postgresql.org/docs/current/btree-intro.html) work well for time-series data, but you may wish to benchmark [BRIN indexes](https://www.postgresql.org/docs/current/brin-intro.html) as well, as they may perform better in specific query scenarios (often queries with _many_ results). Start with B-Tree if you don't anticipate more than a million records in each partition (by default, partitions are one week long).

### Partition Sizing

Related to the above information on indexes is the question of partition size. Because calculating the total size of partitioned tables can be tedious, Tembo's extension provides several easy-to-use views surfacing this information.

To examine the table (data), index, and total size for each of your partitions, simple query the time-series partition information view, `ts_part_info`. A general rule of thumb is that each partition should be able to fit within roughly one quarter of your available memory. This assumes that not much apart from the time-series workload is going on, and things like parallel workers may complicate matters, but work on getting partition total size down to around a quarter of your memory and you're off to a good start.

### Retention

On the other hand, you may be worried about plugging a firehose of data into your storage layer to begin with… While the `ts_table_info` view may allay your fears, at some point you _will_ want to remove some of your time-series data.

Fortunately, it's incredibly easy to simply drop time-series partitions on a schedule. Call `set_ts_retention_policy` with your time-series table and an interval (say, `'90 days'`) to establish such a policy. Once an hour, any partitions falling entirely outside the retention window will be dropped. Use `clear_ts_retention_policy` to revert to the default behavior (infinite retention). Each of these functions will return the previous retention policy when called.
