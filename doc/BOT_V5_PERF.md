# Bot v5 hub performance

`Bot5Hub._physics_process` wall time per physics frame (µs), 12v12 all-v5 (`lineup_12v12_t10`), `--fixed-fps 16`.
Run: `tools/botmatch/bot5_perf.sh <label> [seed]` (appends a row). Same seed across rows; one match at a time on an idle machine.

| date | rev | change | seed | mean | p50 | p90 | p99 | p99.9 | max | frames | match s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-13 | b0cd2512+ | baseline: station shot search | 1 | 903 | 705 | 1817 | 3261 | 4511 | 116332 | 14458 | 1200 |
| 2026-11-13 | b0cd2512+ | bot5 registration + terrain at match setup | 1 | 755 | 573 | 1534 | 2958 | 4174 | 8934 | 14459 | 1200 |
