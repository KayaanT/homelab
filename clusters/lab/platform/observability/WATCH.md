# What to actually watch

Beyond the dashboards, one metric matters more than the rest on this hardware:

```promql
histogram_quantile(0.99,
  rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))
```

etcd fsyncs every write to disk before acknowledging it. If the p99 goes above
~25ms, the API server starts timing out, and the symptom is a cluster that feels
"randomly slow" with nothing obviously broken. It is the single most common way
a single-node cluster on consumer storage degrades, and knowing to look here is
most of the value of running one.

Also worth a panel each:
- `ceph_osd_op_latency` — storage backpressure
- `container_memory_working_set_bytes` by namespace — who is eating the 16GB
- `cilium_drop_count_total` by reason — policy or datapath drops
