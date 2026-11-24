# RACE / SepHash experiment reproduction (memserver16 + bfhost_72)

Reproduce **RACE** (USENIX ATC'21 / TOS) style figures using the RACE implementation in this SepHash tree on a two-node InfiniBand cluster.

Pilaf / FaRM / DrTM / CLevel / Plush are not runnable here; plots show RACE curves only. Axis titles and layout follow the paper for side-by-side comparison.

## Cluster topology

| Role | Host | Mgmt | IB | Device | GID |
|------|------|------|-----|--------|-----|
| Memory / server | memserver16 | local | 10.10.1.16 | mlx5_2 | 0 |
| Client | bfhost_72 | SSH | 10.10.1.72 | mlx5_0 | 0 |

On memserver16, `mlx5_0` is often Down — do not use `dev(nullptr)`. Repro scripts pin Active devices.

## Quick start

```bash
# On memserver16
cd repro
./check_env.sh
SCALE=medium ./run_all.sh          # default, hours
SCALE=paper  ./run_all.sh          # load 1e8 / op 1e7, may take >10h
EXPTS="race_tput race_ycsb" ./run_all.sh
./run_all.sh --plot-only
```

| Path | Content |
|------|---------|
| `results/*.csv` | Metrics |
| `results/figures/*.pdf` / `*.png` | Plots |

Client sources sync to `bfhost_72:/tmp/dongshuqi/SepHash` (home often full).

See `env.sh` for `SRV_IP`, `CLT_HOST`, `GID_IDX`, `SRV_IBDEV`, `CLT_IBDEV`, `MEM_SIZE`, `CLT_SRC`.

## Experiments vs paper figures

| `EXPTS` | Script | Target | Notes |
|---------|--------|--------|-------|
| `race_tput` | `experiments/race_tput.sh` | RACE Fig.11 throughput vs #clients | `SCALE=paper` up to 128 (slight oversubscribe on 96 cores) |
| `race_hybrid` | `race_hybrid.sh` | RACE Fig.12 search/insert mix | Sweep ratios at max clients |
| `race_latency` | `race_latency.sh` | RACE Fig.10 latency vs load | 1 client; x-axis `entry_utilization`; also `fig_race_latency_by_load` |
| `race_varlen` | `race_varlen.sh` | RACE Fig.13 variable value size | `ser_cli_var_kv`; `RESUME=1` fills missing points |
| `race_ycsb` | `race_ycsb.sh` | SepHash Fig.17 YCSB A–D | RACE bars only |
| `sephash_insert` | `sephash_insert.sh` | SepHash Fig.12 insert scale | Optional; not in default `EXPTS` |
| `sephash_hybrid` | `sephash_hybrid.sh` | SepHash Fig.14 insert:search | Optional |

Not reproducible here: associativity sweep, Pilaf/FaRM/DrTM curves, multi-machine 128 physical clients, SRCD cache ablation.

## SCALE

| SCALE | load / op | clients | Use |
|-------|-----------|---------|-----|
| `smoke` | 1e5 / 2e4 | 1,2,4 | Script check |
| `medium` | 1e7 / 1e6 | 1…64 | Daily repro |
| `paper` | 1e8 / 1e7 | 1…128 | Paper-aligned load/op/client axis |

## Known fix (already in `test/ser_cli*.cc`)

Original `run()` sampled insert keys with `gen()`, so multi-client runs collided and RACE concurrent split could hit `Exceed MAX_DEPTH`. Insert keys in the run phase are partitioned by `(machine,cli,coro)`.

## Plotting

`plot_all.py` reads CSV (white background, grid, RACE single series). Absolute Mops need not match the paper (IB vs RoCE, 2 nodes vs many); compare trends.
