# RACE / SepHash 实验复现（server02 + server03）

用 SepHash 仓库里的 **RACE** 实现，在双机 RoCEv2 上尽量对齐：

- **RACE**（USENIX ATC’21 / TOS）：Fig.10–13 一类（时延、吞吐扩展、hybrid、变长 KV）
- **SepHash**（VLDB’24）论文中 **RACE 作为基线** 的 Fig.12 / 14 / 17

Pilaf / FaRM / DrTM / CLevel / Plush **本仓没有可跑实现**，图里只画 RACE 曲线；版式（轴标题、多子图布局、横轴刻度）按论文来，方便并排对比。

## 快速开始

```bash
# 在 server02 上
cd /home/dsq/SepHash/repro

# 1) 冒烟（分钟～十几分钟）
SCALE=smoke MEM_SIZE=$((32*1024*1024*1024)) ./run_all.sh

# 2) 默认中等规模（小时级，推荐先跑这个）
SCALE=medium ./run_all.sh

# 3) 尽量对齐论文量级（load 1e8 / op 1e7，可能十余小时）
SCALE=paper MEM_SIZE=$((80*1024*1024*1024)) ./run_all.sh

# 只跑子集
EXPTS="race_tput race_ycsb" SCALE=medium ./run_all.sh

# 已有 CSV，只出图
./run_all.sh --plot-only
```

结果：

| 路径 | 内容 |
|------|------|
| `results/*.csv` | 原始指标 |
| `results/logs/` | 每次 client 完整日志 |
| `results/figures/*.pdf` / `*.png` | 自动出图 |

client 代码同步到 **`server03:/tmp/dsq/SepHash`**（`/home` 常满，见 `docs/SEPHASH_RACE_SERVER02_03.md`）。

## 实验与论文图对应

| `EXPTS` 名 | 脚本 | 对齐目标 | 本双机能做什么 | 做不到 / 近似 |
|------------|------|----------|----------------|---------------|
| `race_tput` | `experiments/race_tput.sh` | RACE **Fig.11** 四分图：insert/search/update/delete 吞吐 vs #clients | 扫线程数；`SCALE=paper` 到 **64**（论文到 128） | 无 4 台 client 机；无对比基线 |
| `race_hybrid` | `race_hybrid.sh` | RACE **Fig.12** search/insert 比 | 最大线程数下扫 10/90…90/10 | 论文 load 9e7+128 clients → 用 SCALE 的 LOAD_NUM + max clients |
| `race_latency` | `race_latency.sh` | RACE **Fig.10** 时延 vs load factor | 1 线程；x 轴优先 **entry_utilization**（load 后 `cal_utilization`） | 无逐请求 `USE_PERF` 分布，用 wall-clock 平均 µs |
| `race_varlen` | `race_varlen.sh` | RACE **Fig.13** 变长 value | `ser_cli_var_kv`，16B key，扫 value 64…8K | 大 value 自动降 load，防 OOM |
| `race_ycsb` | `race_ycsb.sh` | SepHash **Fig.17** YCSB A–D | A/B/C zipfian；D latest | 仅 RACE 柱 |
| `sephash_insert` | `sephash_insert.sh` | SepHash **Fig.12** insert 扩展 | 用 **load 阶段** Mops 作从空表写入吞吐 | 无 SepHash/CLevel/Plush 同图对比 |
| `sephash_hybrid` | `sephash_hybrid.sh` | SepHash **Fig.14** insert:search | 1:9…9:1 | 同上 |

### 明确不可复现（缺代码或缺硬件）

- RACE **最大 load factor vs associativity**（需改 `SLOT_PER_BUCKET` 并改插入失败语义；现实现会 split）
- RACE 与 Pilaf / FaRM hopscotch / DrTM 的对比曲线
- SepHash 本体 / CLevel / Plush 同图（把 `ClientType` 切回去可另跑，但不在本默认流水线）
- SRCD cache on/off 消融（无编译开关）
- 论文 5/8 机 IB、128 物理 client 进程满配

## SCALE 参数

| SCALE | load / op（主实验） | client 扫 | 用途 |
|-------|---------------------|-----------|------|
| `smoke` | 1e5 / 2e4 | 1,2,4 | 验证脚本 |
| `medium` | 1e7 / 1e6 | 1…32 | 日常复现 |
| `paper` | 1e8 / 1e7 | 1…64 | 尽量贴论文 |

环境变量见 `env.sh`：`SRV_IP`、`CLT_HOST`、`GID_IDX`、`MEM_SIZE`、`CLT_SRC` 等。

## 已知问题（已修 / 需环境）

1. **insert key 重叠 → MAX_DEPTH**（已修）：run 阶段 insert 按 `(machine,cli,coro)` 划分互不重叠新 key。  
2. **`server_ip` 悬空指针**（已修）：`config.h` 改为自持有 `server_ip_str`，否则 `connect` 会随机失败。  
3. **`init` 早于 `listen`**（已修）：`start_server` 等到 `:10001` 真正在听并用 TCP probe；connect 失败会重启 server 重试。  
4. **listen backlog**（已修）：`aiordma.cc` 由 5 改为 512。  
5. **RoCE L2 中断**（环境）：口 Up 但 `10.0.0.20↔10.0.0.21` ping/ARP 失败时，任何双机实验都会在 TCP/RDMA 建连阶段挂掉。先 `ping` 通再 `./run_all.sh`。

---

## 出图说明

`plot_all.py` 读 CSV，风格为白底 + 网格 + RACE 单曲线（蓝、圆点），轴标题尽量用论文用语（如 `Throughput (M reqs/s)`、`Search/Insertion Ratio (%)`）。

绝对 Mops **不必**与论文重合（RoCE vs IB、双机 vs 多机、CPU/DRAM 不同）；看趋势与相对形状。

## 目录

```
repro/
  env.sh lib.sh run_all.sh plot_all.py README.md
  experiments/*.sh
  results/{*.csv,logs/,figures/}
```
