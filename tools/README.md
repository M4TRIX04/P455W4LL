# tools — ipk 构建与设备端脚本

这个目录是**工具**，不是包。包在仓库根下：`luci-app-passwall/`、`shadowsocks-c/`、`hysteria/`、`dns2tcp/`。

| 文件 | 用途 |
|---|---|
| `build-ipk.sh` | 用 OpenWrt SDK 编出 12 个 ipk（约 12 分钟），装到已有系统 |
| `device-check.sh` | 装包前的只读体检（soname、依赖、现有配置）|
| `install-ipk.sh` | 设备上的安装脚本，带备份与回滚 |

> 要把包**编进固件**（跟着 ImmortalWrt 一起出 img），看 [`../integration/`](../integration/README.md)，那是另一条路。

## 目录布局

仓库根下每个目录就是一个 OpenWrt 包，和官方 `openwrt-passwall` / `openwrt-passwall-packages` 的形状一致：

```
luci-app-passwall/     LuCI 应用本体（4.70-5）
shadowsocks-c/         产出 shadowsocks-libev-ss-* 五个包（ss-libev 继任者）
hysteria/              v1.3.5（与 util_hysteria.lua 的配置格式配套）
dns2tcp/               1.1.2（上游 feed 已删）
```

所以可以直接 `git clone <本仓库> package/passwall-luci`，四个包一起进去。

## 为什么这几个包要自己维护

上游 feed 的两个删除提交：

```
cf2e235  remove unused packages - shadowsocks-libev - trojan-plus - tuic-client
6d4bc0f  remove packages that are no longer needed for passwall
```

后果是 `luci-app-passwall` 的 `Depends` 里有一批包在 feed 中已不存在。更关键的是上游新版**主动移除了 ss-libev 支持**（`INCLUDE_Shadowsocks_Libev_Client` 已删，只剩 rust 和 SSR），所以「等上游加回来」不会发生。

| 包 | 来源 | 为什么要自己维护 |
|---|---|---|
| `shadowsocks-c` | 上游 master `50f1ae5` | ss-libev 的继任者。包名仍产出 `shadowsocks-libev-ss-*`，PassWall 源码零改动 |
| `hysteria` | feed 历史 `a50cdb9`（v1.3.5） | feed 里已是 v2，配置格式与 `util_hysteria.lua` 不兼容 |
| `dns2tcp` | feed 历史 `06ab538`（1.1.2） | PassWall 的无条件依赖，feed 里已删 |

其余依赖（`chinadns-ng` `dns2socks` `microsocks` `tcping` `ipt2socks`）直接用 feed 里的。

## 编 ipk

```sh
cd tools
./build-ipk.sh                  # 默认工作目录 /build
./build-ipk.sh /path/to/wd      # 指定工作目录
```

首次约 15 分钟（下 SDK + feeds），之后增量几秒。产物在 `$WORK/out/`。

需要 Docker + Ubuntu 24.04 环境。脚本自己处理：
- 补 `base` feed（SDK 的基础包在 feed 里，不在 `package/`）
- 去掉 routing/telephony（少编几十个包）
- Windows 工作区的 CRLF 与执行位
- 绕开 `INCLUDE_Shadowsocks_Libev_*` 的 kconfig 循环依赖，直接选包
- 末尾断言产物数 = 12，不对直接退出 1

## 装到设备

```sh
# 上传
scp passwall-x86_64.tar.gz device-check.sh install-ipk.sh root@<路由器>:/tmp/

# 体检（只读，不改任何东西）
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

最容易踩的是 `libsodium.so.26` 和 `libmbedcrypto.so.16` —— 这两个 soname 来自 **libsodium 1.0.19 + mbedtls 3.6**，只有 24.10 及以上才有。23.05 上是 `.23` 和 `.7`，二进制直接跑不起来。

```sh
sh /tmp/install-ipk.sh --dry-run   # 先看它要做什么
sh /tmp/install-ipk.sh             # 正式执行
```

脚本会：备份配置 → 停服务 → 卸载旧版 → 装 12 个包 → 校验二进制与权限。

**`/etc/config/passwall` 不在 ipk 里**（由 `uci-defaults` 从 `0_default_config` 生成，且仅在文件不存在时生成）。所以安装**不会覆盖你现有的节点配置**。

回滚：

```sh
opkg remove luci-app-passwall --force-depends
cp /root/passwall-backup-<时间戳>/passwall.config /etc/config/passwall
```

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
- 官方 packages feed 里也有同名包，`feeds install -a` 装的是官方那个，编译路径是 `package/feeds/packages/microsocks` 而不是 `passwall_packages`

## 已知问题

**1. 翻译包是空的**

`po/zh_Hans` 在仓库里被压成了一个 5 字节文本文件（Windows 提交导致），所以编出来的 `luci-i18n-passwall-zh-cn` 不含任何 `.lmo`。**界面是英文**。纯 Lua/shell 项目，英文够用。

**2. 上游 kconfig 循环依赖**

```
PACKAGE_luci-app-passwall → sing-box-tiny → sing-box → (selected by) luci-app-passwall
```

会让 `make defconfig` 丢选项，导致 `INCLUDE_Shadowsocks_Libev_Client` 怎么设都变 `not set`。`build-ipk.sh` 绕开的方式是不用这个开关，直接 `CONFIG_PACKAGE_shadowsocks-libev-ss-*=m`。

**3. 老节点会变孤儿**

`nodes` 是 UCI 具名 section，卸载重装不会清理。type 为 `xray` / `sing-box` / `brook` 等的老节点仍会出现在列表里（显示成 `xray：节点名`），但点编辑会白屏。手动删掉即可。

## CI

`.github/workflows/build.yml` 每次改动 `luci-app-passwall/` `shadowsocks-c/` `hysteria/` `dns2tcp/` 或本脚本时自动构建，产物上传为 artifact。

**核心设计：CI 不重写构建逻辑，只调 `tools/build-ipk.sh`。** 本地和线上跑的是同一份脚本。

实测耗时（x86/64）：

| 环境 | 场景 | 耗时 |
|---|---|---|
| 本地容器 14 核 | 冷启动（无缓存） | 12 分 28 秒 |
| 本地容器 14 核 | feeds 缓存命中 | 9 分 11 秒 |
| GitHub runner 2 核 | 冷启动 | 18 分钟 |

缓存只存 `sdk/feeds` + `sdk/dl` + `sdk/package`（约 1.5G）。全量 sdk 实测 7.8G，超 GitHub 单仓库 10G 上限，多架构矩阵会直接失效。

本地复现 CI：

```sh
WORK=/tmp/ci-work SDK_VERSION=24.10.8 SDK_TARGET=x86/64 ./tools/build-ipk.sh /tmp/ci-work
```
