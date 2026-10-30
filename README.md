# meta — 与编译无关的配套内容

这是 `meta` 分支。**主分支 `main` 只有四个 OpenWrt 包**，这里放不参与编译的东西。

## 为什么单独放一个分支

`main` 的唯一用途是当 feed：

```sh
git clone https://github.com/M4TRIX04/P455W4LL package/passwall-luci
```

扫描器只看目录里有没有 `Makefile`，多几个文件其实不影响功能 —— 但 `main` 保持纯粹，clone 进去的目录就只有包，不用每次看到一堆无关文件。

## 这里有什么

| 目录 | 说明 |
|---|---|
| `integration/` | 接进 ImmortalWrt 源码树用的：`.config` 片段、`verify.sh`（30 项检查）、接入文档 |
| `tools/` | 设备端脚本：`device-check.sh`（装包前查 soname/依赖）、`install-ipk.sh`（装 ipk，带备份回滚）|
| `docs/` | PassWall 架构解析，Markdown 原版 + doocs/md 版 |

## 怎么用

单独克隆：

```sh
git clone -b meta https://github.com/M4TRIX04/P455W4LL /tmp/p455w4ll-meta
```

或者只取一个文件，不切分支：

```sh
git show origin/meta:integration/verify.sh > /tmp/verify.sh
cd /path/to/immortalwrt && sh /tmp/verify.sh
```

注意 `verify.sh` 要在**你的 ImmortalWrt 源码根目录**里跑，不是在本仓库里跑 —— 它检查的是你源码树里的 `package/`、`.config`、`tmp/.packageinfo`。

## 分支关系

`meta` 是孤儿分支，和 `main` 没有共同历史。两边各自演进，互不影响：

- 改包 → `main`
- 改文档、改校验脚本 → `meta`
