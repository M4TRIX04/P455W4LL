# vendor — PassWall 私有构建

这套东西解决一个问题：**上游 `openwrt-passwall-packages` 把 PassWall 必需的几个包删了**，直接用官方 feed 编出来的 ipk 装不上、装上也跑不起来。

## 为什么需要 vendor

上游 feed 的两个删除提交：

```
cf2e235  remove unused packages - shadowsocks-libev - trojan-plus - tuic-client
6d4bc0f  remove packages that are no longer needed for passwall
```

后果是 `luci-app-passwall` 的 `Depends` 里有一批包在 feed 中已不存在。更关键的是上游新版 **主动移除了 ss-libev 支持**（`INCLUDE_Shadowsocks_Libev_Client` 已删，只剩 rust 和 SSR），所以"等上游加回来"不会发生。

| 包 | 来源 | 为什么要自己维护 |
|---|---|---|
| `shadowsocks-c` | 上游 master `50f1ae5` | ss-libev 的继任者。包名仍产出 `shadowsocks-libev-ss-*`，PassWall 源码零改动 |
| `hysteria` | feed 历史 `a50cdb9`（v1.3.5） | feed 里已是 v2，配置格式与 `util_hysteria.lua` 不兼容 |
| `dns2tcp` | feed 历史 `06ab538`（1.1.2） | PassWall 的无条件依赖，feed 里已删 |

其余依赖（`chinadns-ng` `dns2socks` `microsocks` `tcping`）直接用 feed 里的，不 vendor。

## 构建

```sh
cd vendor
./build.sh                  # 默认工作目录 /build
./build.sh /path/to/wd      # 指定工作目录
```

首次约 15 分钟（下 SDK + feeds），之后增量几秒。产物在 `$WORK/out/`。

需要 Docker + Ubuntu 24.04 环境。脚本自己处理：
- 补 `base` feed（基础包在 feed 里，不在 `package/`）
- 去掉 routing/telephony（少编几十个包）
- Windows 工作区的 CRLF 与执行位
- 绕开 `INCLUDE_Shadowsocks_Libev_*` 的 kconfig 循环依赖，直接选包

## 部署

### 1. 上传

```sh
scp passwall-x86_64.tar.gz device-check.sh install.sh root@<路由器>:/tmp/
```

### 2. 体检（只读，不改任何东西）

```sh
ssh root@<路由器>
mkdir -p /tmp/pw-ipk && tar xzf /tmp/passwall-x86_64.tar.gz -C /tmp/pw-ipk
sh /tmp/device-check.sh
```

必须确认三件事，否则装了也白装：

| 检查项 | 要求 | 不满足的后果 |
|---|---|---|
| 第 2 节 | 出现 `x86_64` | opkg 拒绝安装 |
| 第 3 节 | 6 个 soname 全 `OK` | `ss-local` 加载失败（缺 `.so`）|
| 第 4 节 | 无 `!! 源里没有` | 依赖装不上 |

其中最容易踩的是 `libsodium.so.26` 和 `libmbedcrypto.so.16` —— 这两个 soname 来自 **mbedtls 3.6 / libsodium 1.0.19**，只有 24.10 及以上的系统才有。23.05 上是 `libmbedcrypto.so.7` 和 `libsodium.so.23`，二进制直接跑不起来。

### 3. 安装

```sh
sh /tmp/install.sh --dry-run   # 先看它要做什么
sh /tmp/install.sh             # 正式执行
```

脚本会：备份配置 → 停服务 → 卸载旧版 → 装 12 个包 → 校验二进制与权限。

**注意 `/etc/config/passwall` 不在 ipk 里**（由 `uci-defaults` 从 `0_default_config` 生成，且仅在文件不存在时生成）。所以安装**不会覆盖你现有的节点配置**。这是好事也是风险：如果现有配置来自更新版本的 PassWall，里面可能有 4.70-5 不认识的 section。

### 4. 回滚

```sh
opkg remove luci-app-passwall --force-depends
cp /root/passwall-backup-<时间戳>/passwall.config /etc/config/passwall
```

## 已知问题

**1. 老节点会变孤儿**

`nodes` 是 UCI 具名 section，卸载重装不会清理。type 为 `xray` / `sing-box` / `brook` 等的老节点仍会出现在列表里（显示成 `xray：节点名`），但点编辑会白屏——因为对应的 `type/*.lua` 已经不在包里了。手动删掉即可。

**2. 翻译包是空的**

`po/zh_Hans` 在仓库里被压成了一个 5 字节文本文件（Windows 提交导致），所以编出来的 `luci-i18n-passwall-zh-cn` 不含任何 `.lmo`。**界面是英文**。这是已知且可接受的（纯 Lua/shell 项目，英文够用）。

**3. 上游 kconfig 循环依赖**

```
PACKAGE_luci-app-passwall → sing-box-tiny → sing-box → (selected by) luci-app-passwall
```

会让 `make defconfig` 丢选项，导致 `INCLUDE_Shadowsocks_Libev_Client` 怎么设都变 `not set`。`build.sh` 绕开的方式是不用这个开关，直接 `CONFIG_PACKAGE_shadowsocks-libev-ss-*=m`。

## 各包的坑（改之前先读）

**shadowsocks-c**
- 固定到 commit `50f1ae5`，不能用 `v3.3.6` tag —— 那个 tag 还残留 libcork/libev 代码，且 libcork 是 git 子模块，tarball 不含，编不过
- 必须用 `SS_DEPENDENCY_MODE=system`（bundled 模式 924K，system 模式 202K）
- 关掉 `SS_ENABLE_REGEX`（省掉 PCRE2，PassWall 不用 ACL 正则）

**hysteria v1**
- 依赖的 `quic-go` 有编译期断言，**拒绝 Go ≥ 1.21**
- 解法是覆盖 `GO_PKG_BUILD_VARS`（不是 `TARGET_VARS`，`GOTOOLCHAIN=local` 在 BUILD_VARS 里）：
  ```make
  GO_PKG_BUILD_VARS:=$(filter-out GOTOOLCHAIN=local,$(GO_PKG_BUILD_VARS)) GOTOOLCHAIN=go1.20.14
  ```

**microsocks**
- 官方 packages feed 里也有同名包，`feeds install -a` 装的是官方那个
- **不要**照搬官方说明里"先 rm 掉 feed 里的同名包"——那是为整仓导入服务的，我们只 vendor 三个包，删了反而破坏符号链接

## 产物清单（12 个）

| 包 | 大小 | 架构 |
|---|---|---|
| `luci-app-passwall_4.70-5_all` | 958K | all |
| `hysteria_1.3.5-r1` | 6.6M | x86_64 |
| `shadowsocks-libev-ss-local` / `-server` | 90K 各 | x86_64 |
| `shadowsocks-libev-ss-redir` / `-tunnel` | 84K 各 | x86_64 |
| `shadowsocks-libev-ss-manager` | 34K | x86_64 |
| `dns2tcp_1.1.2-r1` | 11K | x86_64 |
| `chinadns-ng_2025.08.09-r1` | — | x86_64 |
| `dns2socks_2.1-r3` | — | x86_64 |
| `microsocks_1.0.5-r2` | — | x86_64 |
| `tcping_0.3-r1` | — | x86_64 |

## GitHub Actions

`.github/workflows/build.yml`，三个 job：

| job | 作用 |
|---|---|
| `prepare` | 把 `targets` 输入（空格分隔）转成矩阵 JSON，顺带生成不带斜杠的 `slug` 给 artifact 命名 |
| `build` | 矩阵构建，每个 target 一个 runner |
| `release` | 打 `v*` tag 时汇总所有 ipk 发 Release |

**核心设计：CI 不重写构建逻辑，只调 `vendor/build.sh`。** 本地和线上跑的是同一份脚本，不会出现「本地能编、CI 编不过」。

### 触发条件

| 事件 | 行为 |
|---|---|
| push 到 `main`（改 `luci-app-passwall/` `vendor/` 或本工作流） | 构建默认架构 |
| pull_request（同上路径） | 构建默认架构 |
| 手动 `workflow_dispatch` | 可指定 SDK 版本和任意 target 列表 |
| 每周一 02:00 CST（cron `0 18 * * 0`） | 构建默认架构 |

那条 cron **不是为了出包，是为了发现 feed 漂移**。上游 `openwrt-passwall-packages` 随时可能删包或改版本（hysteria v1 → v2 就是活例子），定时跑能在你升级设备之前就报警。

### 加一个架构

手动触发时在 `targets` 里填，空格分隔：

```
x86/64 ramips/mt7621 mediatek/filogic
```

要改成每次默认都编多个，就动工作流里 `prepare` job 的 `list="${INPUT_TARGETS:-x86/64}"`，把 `x86/64` 换成列表。

已验证的 target 与对应架构：

| target | 架构 | 典型设备 |
|---|---|---|
| `x86/64` | `x86_64` | 软路由 |
| `ramips/mt7621` | `mipsel_24kc` | 小米/红米 AX、K2P |
| `mediatek/filogic` | `aarch64_cortex-a53` | MT7981/7986 软路由 |
| `ipq806x/generic` | `arm_cortex-a15_neon-vfpv4` | 网件 R7800 |
| `mvebu/cortexa53` | `aarch64_cortex-a53` | 部分 ARM 路由 |
| `bcm27xx/bcm2711` | `aarch64_cortex-a72` | 树莓派 4 |
| `rockchip/armv8` | `aarch64_generic` | RK3399 盒子 |
| `ath79/generic` | `mips_24kc` | 老款 AR 芯片 |

SDK 文件名由 `build.sh` 自动从目录列表里抓，不用手填。注意 ARM 32 位平台的包名带 `_eabi`、其余不带，这个差异脚本自己处理。

### 缓存

只缓存三块，共约 **1.5G**：

```yaml
path: |
  ${{ env.WORK }}/sdk/feeds     # 409M  feed 克隆结果
  ${{ env.WORK }}/sdk/dl        # 1.1G  源码包与 Go 工具链
  ${{ env.WORK }}/sdk/package   # 3.7M  feeds install 生成的符号链接
key: feeds-${{ env.SDK_VERSION }}-${{ matrix.slug }}-v1
```

**为什么不缓存整个 sdk**：实测全量（含 `build_dir` 4.3G + `staging_dir` 1.7G）是 **7.8G**，而 GitHub 单仓库缓存上限 10G，多架构矩阵必然超限、且超限是**静默不保存**（不报错，只是每次都全量重建）。`build_dir` 也只省几分钟编译，不值这个体积。

这三块省掉的是最慢的两个**非编译**步骤：feed 克隆（~4 分钟）和 `feeds install` 的索引生成（~3 分钟）。编译本身仍然每次重做。

实测耗时：

| 环境 | 场景 | 耗时 |
|---|---|---|
| 本地容器 14 核 | 冷启动（无缓存） | 12 分 28 秒 |
| 本地容器 14 核 | feeds 缓存命中 | 9 分 11 秒 |
| GitHub runner 2 核 | 冷启动（首次运行） | 18.0 分钟 |
| GitHub runner 2 核 | 缓存命中（第二次） | 21.0 分钟 |
| GitHub runner 2 核 | 缓存命中（第三次） | 20.5 分钟 |

**一个反直觉的结果，别被总时长误导**：GitHub 上缓存命中的两次反而比冷启动慢。

缓存确实是命中的 —— `恢复 feeds 缓存` 步骤三次分别耗时 **0 秒 / 8 秒 / 8 秒**，8 秒是在解压 893 MB。构建步骤内部也确认跳过了 feed 克隆。

慢的原因在别处：**2 核 runner 的性能波动比缓存省下的时间还大**。三次构建步骤分别是 922 / 1130 / 1007 秒，同样的活儿差出 3.5 分钟。缓存省下的 feed 克隆约 4 分钟，正好被波动吃掉。

结论：缓存对**减少外部依赖**（不重复克隆几百 MB）是有意义的，但别指望它显著缩短墙钟时间。要真的快，得换 larger runner 或者干脆只跑必要的包。

GitHub 的 `ubuntu-24.04` runner 只有 2 核，比本地 14 核慢一半左右。缓存条目实测 **892 MB**（1.5G 内容压缩后），单架构远低于 10G 上限。

每次构建结束后 `build.sh` 会打 8 行阶段耗时，形如：

```
==> 编译主包与 vendor 包
    ↳ 本阶段 6 分 42 秒（累计 8 分 16 秒）
```

日志里 `feeds 缓存命中: true/false` 由工作流打印，一眼看出缓存是否退化。

**想强制全量重建**：把 key 末尾的 `v1` 改成 `v2`。

缓存命中时 `build.sh` 的行为（靠三个哨兵判断，都不需要额外参数）：

| 哨兵 | 存在则跳过 |
|---|---|
| `sdk/scripts/feeds` | SDK 下载与解压 |
| `sdk/feeds/luci` | `feeds update -a` |
| `sdk/package/feeds/luci` | `feeds install -a` |

所以哪怕只恢复了 `feeds/` 而没恢复 `package/`，脚本也会正确地只跑 `install`，不会重复克隆。这也是为什么 `build.sh` 用 `sdk/scripts/feeds` 而不是 `sdk` 目录本身当哨兵。

### 产物校验

`build.sh` 末尾会断言包数等于 `EXPECT_PKGS`（当前 12），不对就退出 1。**加包时记得改这个常量**，否则 CI 会一直报数量不符。

工作流里还有一道架构检查：所有非 `all` 的包必须是同一个架构，出现两种就说明缓存串了架构（比如 x86 的 build_dir 被 ARM 的 job 复用），会直接 fail 而不是产出一个装不上的包。

### 本地复现 CI

CI 的每一步都能在本地跑：

```sh
# 完全等价于 CI
WORK=/tmp/ci-work SDK_VERSION=24.10.8 SDK_TARGET=x86/64 ./vendor/build.sh /tmp/ci-work
```

如果 CI 挂了但本地不挂，八成是这两件事之一：

1. **缓存脏了** —— 换 cache key 重跑
2. **runner 磁盘满了** —— 工作流里有一步删 `/usr/local/lib/android` 等预装 SDK，本地没有这一步

### 失败时看什么

工作流在失败时会额外上传 `buildlog-<slug>` artifact，里面有 `sdk/logs/` 和 `sdk/.config`。

`sdk/logs/` 下每个包一个目录，里面是 `configure`、`compile.txt` 这些，比 CI 控制台输出完整得多。

