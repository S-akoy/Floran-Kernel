# ZRAM LZ4KD 16GB + swappiness 200 (KernelSU module)

把 zram0 的默认压缩算法设为 `lz4kd`、大小设为 16384 MiB（16 GiB），并把
`vm.swappiness` 拉到内核允许的最大值 200，让系统尽量优先使用 zram 而不是丢页缓存。

## 为什么需要模块

- 本 ROM 的 `zram.ko` 来自 `system_dlkm`（GKI 预编译模块），内核默认算法为 `lzo-rle`，改内核 Image 的 Kconfig 不会影响它。
- `/vendor/bin/init.kernel.post_boot.sh`（以及 `init.qcom.post_boot.sh`）在 `sys.boot_completed=1` 时把 zram 大小限制为 6144 / 4096 MiB、swappiness 设为 100，且只在 `ro.config.low_ram=true` 时写 `comp_algorithm`。

因此由 KernelSU 模块在开机完成后接管 zram0 和 swap 相关的 sysctl。

## 参数

| 项目 | 值 |
| --- | --- |
| 压缩算法 | `lz4kd` |
| 大小 | 16384 MiB（`17179869184` 字节） |
| swap 优先级 | 32758 |
| `vm.swappiness` | 200（6.1 内核上限） |
| `vm.page-cluster` | 0（每次 swap I/O 一页，对 zram 最合适） |

## 安装

1. 先刷入带 `CRYPTO_LZ4KD` 的内核（`FrierenKernel-A17-BakaSU-SUSFS-LZ4KD-Oct27.zip`）。
2. KernelSU 管理器 → 模块 → 从本地安装 → 选择本 zip（模块 id 未变，会直接覆盖旧版）。
3. 重启。

## 验证

```sh
su -c 'cat /sys/block/zram0/comp_algorithm'   # 当前算法带方括号：[lz4kd]
su -c 'cat /sys/block/zram0/disksize'         # 应为 17179869184
su -c 'cat /proc/swaps'                       # 必须要有 /dev/block/zram0 一行，优先级 32758
su -c 'cat /proc/sys/vm/swappiness'           # 应为 200
su -c 'cat /proc/sys/vm/page-cluster'         # 应为 0
su -c 'cat /data/local/tmp/zram_lz4kd.log'
```

注意：只看 `disksize` 不够。算法和大小都正确，但 `/proc/swaps` 里没有 zram0，说明 swap 没启用。

`comp_algorithm` 的列表来自 ROM 的 zram.ko，可能不含 `lz4kd`，但当前算法会以 `[lz4kd]` 追加显示。

## 手动重新执行

```sh
su -c 'sh /data/adb/modules/zram_lz4kd_8192/boot-completed.sh'
```

脚本是幂等的：如果大小/算法已经正确且 swap 已启用，会直接退出（sysctl 每次都会重新写）；如果只差 swap，会重建 swap 头部再启用。

## 卸载

在 KernelSU 管理器里禁用或删除模块，重启即可恢复 ROM 默认设置（大小、swappiness 都会回到 vendor 脚本的值）。

## 注意

- 脚本在开机完成约 10 秒后执行，会先 `swapoff` 再重建 zram；此时 swap 中的数据很少，但会有一次短暂的内存回收。
- 16 GiB 的 zram 只是逻辑容量，实际内存占用取决于压缩后的数据量（`/sys/block/zram0/mm_stat` 的第二列是压缩后占用）。
- 要求内核注册了 `lz4kd`（`grep -q lz4kd /proc/crypto`）。
- 如果 ROM 以后改了 vendor 开机脚本，本模块仍然有效，因为它是在开机后强制覆盖设置。

## 更新记录

- **v1.2 (2026-10-27)**：zram 大小 8192 → 16384 MiB；新增 `vm.swappiness=200`（vendor 默认 100）和显式 `vm.page-cluster=0`，每次运行都会重新应用，早退路径也不例外。
- **v1.1 (2026-10-27)**：修复 swapon 失败导致“算法正确、大小正确、但没有 swap”的问题。
  KernelSU 用自带 busybox 执行模块脚本，busybox ash 会内建执行 `swapon` applet（`PATH` 里写 `/system/bin` 也没用），而 busybox 的 `swapon` 不支持 `-p`，于是 `swapon ... -p 32758` 报 `invalid option -- p`，脚本退出且不回滚。
  现在 `mkswap`/`swapon`/`swapoff` 全部用绝对路径调用 ROM 的 toybox（`/system/bin/...`，支持 `-p`），并加上：
  - 写 `disksize` 后回读校验；
  - “已配置但 swap 未启用”时只重建 swap 而不重新 reset；
  - `swapon` 带优先级失败时退回不带优先级的 `swapon`；
  - 恢复路径不再静默吞错误。
- v1.0 (2026-10-27)：初始版本（8192 MiB）。
