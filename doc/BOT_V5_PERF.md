# Bot v5 hub performance

`Bot5Hub._physics_process` wall time per physics frame (µs), 12v12 all-v5 (`lineup_12v12_t10`), `--fixed-fps 16`.
Run: `tools/botmatch/bot5_perf.sh <label> [seed]` (appends a row). Same seed across rows; one match at a time on an idle machine. Loads gun matrices from the disk cache (`--gun-matrix-cache`) from 2026-11-14 on. The "station scan" and "matrices built from target cells" rows built them at runtime, so bots fought sooner on wall time against unbuilt matrices; not comparable.

| date | rev | change | seed | mean | p50 | p90 | p99 | p99.9 | max | frames | match s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-13 | b0cd2512+ | baseline: station shot search | 1 | 903 | 705 | 1817 | 3261 | 4511 | 116332 | 14458 | 1200 |
| 2026-11-13 | b0cd2512+ | bot5 registration + terrain at match setup | 1 | 755 | 573 | 1534 | 2958 | 4174 | 8934 | 14459 | 1200 |
| 2026-11-13 | c305c03c+ | flank groups + presumed contacts (spike: v4 calibration priced salvos on the fire path once its warm was skipped) | 1 | 1023 | 835 | 1652 | 2900 | 15537 | 137158 | 9975 | 826 |
| 2026-11-13 | c305c03c+ | flank groups + presumed contacts; calibration off without v4 | 1 | 1076 | 905 | 1923 | 3348 | 4171 | 9703 | 7806 | 646 |
| 2026-11-13 | c305c03c+ | flank merge/split | 1 | 1102 | 964 | 1961 | 3184 | 4390 | 8756 | 8664 | 717 |
| 2026-11-13 | c305c03c+ | team field: seen/shot bitsets from LOS + gun-matrix rows | 1 | 805 | 650 | 1537 | 2935 | 4570 | 10029 | 14459 | 1200 |
| 2026-11-14 | c305c03c+ | station scan: cell scan + point-table curves (runtime gun matrices) | 1 | 1171 | 1027 | 2028 | 3529 | 4973 | 14331 | 14459 | 1200 |
| 2026-11-14 | 41fa5176+ | matrices built from target cells outward (rows + columns) | 1 | 975 | 773 | 1839 | 3776 | 6002 | 14204 | 14459 | 1200 |
| 2026-11-14 | 41fa5176+ | matrices from target cells, matrix cache loaded | 1 | 1257 | 1067 | 2131 | 3910 | 5956 | 14845 | 9260 | 767 |
| 2026-11-14 | 41fa5176+ | spike fixes: pair fill spread, one hive pass per frame, 4 station jumps per frame | 1 | 1147 | 992 | 1952 | 3554 | 4691 | 5733 | 14459 | 1200 |
| 2026-11-14 | 6f707461+ | staggered re-plans: 2 per frame, pass resumes in order | 1 | 1073 | 906 | 1879 | 3294 | 4582 | 5196 | 14459 | 1200 |
