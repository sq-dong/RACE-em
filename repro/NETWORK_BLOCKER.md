# RoCE 阻断说明（2026-11-21）

## 现象

- 管理网正常：`server02` ↔ `server03`（`192.168.100.12` ↔ `.13`）SSH/ping 正常。
- RoCE 口物理 Up、100Gb/s LinkUp，但 **`10.0.0.20` ↔ `10.0.0.21` 双向 ping/ARP 全失败**。
- `server02` 能 ping 通同网段其它节点（如 `10.0.0.11`）；`server03` 的 `enp24s0f0np0` **对 `.20` / `.11` 均不通** → 判定为 **server03 RoCE 口未进入同一 L2 域**（交换机 VLAN/端口/线缆），不是应用或 GID 配置问题。
- 静态 ARP（MAC 已核对正确）仍不通 → 帧在交换机侧被丢。
- MTU：`server02=9000`，`server03=1500`（次要；小包 ping 已失败，先修 L2）。
- 同机 `ser_cli` client↔server 会在 `rdma_conn::do_send` 段错误，**不能**用本机回环代替双机。

## 对照

| 项 | server02 | server03 |
|----|----------|----------|
| RoCE if | `enp59s0f0np0` / `mlx5_0` | `enp24s0f0np0` / `mlx5_3` |
| IP | `10.0.0.20/24` | `10.0.0.21/24` |
| MAC | `10:70:fd:01:d2:50` | `04:3f:72:dd:3a:0c` |
| GID | index **3** (RoCEv2) | index **3** |
| 到 `10.0.0.11` | 通 | 不通 |

今日下午 paper 重跑日志：`connect: -1 != ::connect`（TCP 交换 QP 也走 RoCE IP，必然失败）。

## 需要有 sudo/交换机权限的人做

```bash
# 1) 两端 MTU 对齐（例：都 9000 或都 1500）
sudo ip link set enp59s0f0np0 mtu 9000          # server02
sudo ip link set enp24s0f0np0 mtu 9000          # server03

# 2) 交换机：确认 server03 的 100G RoCE 口与 server02 / 10.0.0.11 同一 VLAN，无 port isolation
# 3) 验证
ping -c 3 -I enp59s0f0np0 10.0.0.21
# on server03:
ping -c 3 -I enp24s0f0np0 10.0.0.20
```

通过后再跑：

```bash
cd /home/dsq/SepHash/repro
SCALE=paper MEM_SIZE=$((80*1024*1024*1024)) ./run_all.sh
```

`run_all.sh` 已加 `check_roce_fabric`，不通会立刻 exit 2。

## 应用侧已修（与本次阻断无关，修好网后直接受益）

- `config.h`：`server_ip_str` 自持有，消除悬空指针
- `aiordma.cc`：listen backlog 512
- harness：等真正 listen + connect 失败重试
- insert key 分区：避免 MAX_DEPTH
