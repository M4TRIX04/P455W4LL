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
