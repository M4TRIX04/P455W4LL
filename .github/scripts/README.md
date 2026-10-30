# .github/scripts — ipk 构建脚本

`build-ipk.sh` 用 OpenWrt SDK 把仓库里的四个包编成 12 个 ipk，装到已有系统上。

这是**可选项**。主路径是把包编进固件（`git clone` 到 ImmortalWrt 源码树，跟着 img 一起出），见 [`../../integration/`](../../integration/README.md)。

放在 `.github/` 下是因为它只被 CI 调用，不该占根目录。

## 用法

```sh
./.github/scripts/build-ipk.sh                  # 默认工作目录 /build
./.github/scripts/build-ipk.sh /path/to/wd      # 指定工作目录
```

首次约 15 分钟（下 SDK + feeds），之后增量几秒。产物在 `$WORK/out/`。

需要 Docker + Ubuntu 24.04 环境。脚本自己处理：

- 补 `base` feed（SDK 的基础包在 feed 里，不在 `package/`）
- 去掉 routing/telephony（少编几十个包）
- Windows 工作区的 CRLF 与执行位
- 绕开 `INCLUDE_Shadowsocks_Libev_*` 的 kconfig 循环依赖，直接选包
- 末尾断言产物数 = 12，不对直接退出 1

环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `SDK_VERSION` | `24.10.8` | OpenWrt SDK 版本 |
| `SDK_TARGET` | `x86/64` | 目标平台 |
| `PASSWALL_SRC` | 仓库根的 `luci-app-passwall/` | 换源码目录 |
| `JOBS` | `nproc` | 并行度 |
| `BUILD_VERBOSE` | `0` | 设 1 打开 `V=s` |

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

**翻译包是空的**

`po/zh_Hans` 在仓库里被压成了一个 5 字节文本文件（Windows 提交导致），所以编出来的 `luci-i18n-passwall-zh-cn` 不含任何 `.lmo`。界面是英文。纯 Lua/shell 项目，英文够用。

**上游 kconfig 循环依赖**

```
PACKAGE_luci-app-passwall → sing-box-tiny → sing-box → (selected by) luci-app-passwall
```

会让 `make defconfig` 丢选项，导致 `INCLUDE_Shadowsocks_Libev_Client` 怎么设都变 `not set`。脚本绕开的方式是不用这个开关，直接 `CONFIG_PACKAGE_shadowsocks-libev-ss-*=m`。

## CI

[`../workflows/build.yml`](../workflows/build.yml) 在改动 `luci-app-passwall/` `shadowsocks-c/` `hysteria/` `dns2tcp/` 或本目录时自动构建，产物上传为 artifact。

**核心设计：CI 不重写构建逻辑，只调 `build-ipk.sh`。** 本地和线上跑的是同一份脚本。

实测耗时（x86/64）：

| 环境 | 场景 | 耗时 |
|---|---|---|
| 本地容器 14 核 | 冷启动（无缓存） | 12 分 28 秒 |
| 本地容器 14 核 | feeds 缓存命中 | 9 分 11 秒 |
| GitHub runner 2 核 | 冷启动 | 18 分钟 |

缓存只存 `sdk/feeds` + `sdk/dl` + `sdk/package`（约 1.5G）。全量 sdk 实测 7.8G，超 GitHub 单仓库 10G 上限，多架构矩阵会直接失效。

本地复现 CI：

```sh
WORK=/tmp/ci-work SDK_VERSION=24.10.8 SDK_TARGET=x86/64 ./.github/scripts/build-ipk.sh /tmp/ci-work
```
