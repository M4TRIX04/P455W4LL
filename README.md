# P455W4LL

PassWall 的私有构建源。把 LuCI 应用和它依赖的协议二进制打包成 OpenWrt 包，供自己的 ImmortalWrt 固件编译使用。

基于 PassWall 4.70-5 的代码快照，不再跟随上游。

## 目录

仓库根下每个目录就是一个 OpenWrt 包：

| 目录 | 说明 |
|---|---|
| `luci-app-passwall/` | LuCI 应用本体（4.70-5） |
| `shadowsocks-c/` | 产出 `shadowsocks-libev-ss-*` 五个包。ss-libev 的继任者，CLI 与 JSON 配置完全兼容 |
| `hysteria/` | v1.3.5。配置格式与 `util_hysteria.lua` 配套，不能用 feed 里的 v2 |
| `dns2tcp/` | 1.1.2。上游 feed 已删除，但它是 PassWall 的无条件依赖 |
| `.github/scripts/` | `build-ipk.sh`（用 SDK 单独编 ipk，可选）|

**接入用的配置片段、校验脚本、架构文档都在 [`meta`](../../tree/meta) 分支** —— 它们不参与编译，单独放一边，`main` 保持纯粹。

```sh
# 需要时单独拉一份
git clone -b meta https://github.com/M4TRIX04/P455W4LL /tmp/p455w4ll-meta
```

## 编进固件

在 ImmortalWrt 源码根目录：

```sh
./scripts/feeds update -a && ./scripts/feeds install -a

# ImmortalWrt 自带 PassWall 25.12.16 和 hysteria v2，不删会静默遮蔽本仓库的版本
rm -rf feeds/luci/applications/luci-app-passwall
rm -rf feeds/packages/net/hysteria feeds/packages/net/dns2tcp

git clone https://github.com/M4TRIX04/P455W4LL package/passwall-luci
```

然后 `make menuconfig` → `LuCI → 3. Applications → luci-app-passwall`。

编之前建议跑一次校验（脚本在 `meta` 分支）：

```sh
git show origin/meta:integration/verify.sh > /tmp/verify.sh
cd /path/to/immortalwrt && sh /tmp/verify.sh --strict
```

它会查同名遮蔽、hysteria 版本、`init.d` 换行符、dnsmasq 冲突这些**光看 menuconfig 看不出来**的问题。详见 [`meta` 分支的 integration/README.md](../../tree/meta/integration)。

## 单独编 ipk

```sh
./.github/scripts/build-ipk.sh
```

产物 12 个 ipk，装到已有系统上。详见 [`.github/scripts/README.md`](.github/scripts/README.md)。

## 为什么不用上游

上游 `openwrt-passwall-packages` 删掉了一批 PassWall 必需的包：

```
cf2e235  remove unused packages - shadowsocks-libev - trojan-plus - tuic-client
6d4bc0f  remove packages that are no longer needed for passwall
```

同时上游新版主动移除了 ss-libev 支持（`INCLUDE_Shadowsocks_Libev_Client` 已不存在）。所以「等上游加回来」不会发生，只能自己维护。

`shadowsocks-c` / `hysteria` / `dns2tcp` 三个包就是为此 vendor 进来的。
