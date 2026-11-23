# GTop — macOS 原生 SSH GPU 实时监控应用

一款基于 **SwiftUI + Swift Charts** 打造的轻量级 macOS 原生应用，自动解析 `~/.ssh/config`，通过系统 `ssh`（`ControlMaster` 多路复用长连接）并发采集多台服务器的 `nvidia-smi` 状态，并汇总到一个统一界面。

## 核心特性

- **完整解析 `~/.ssh/config`**：支持 `Include` 递归加载（含通配符如 `conf.d/*.conf`）、多别名 `Host`、过滤通配符/排除项、自动识别注释分组（`# @group: 分组名`），文件修改后自动热重载。
- **严格按需选中 + 自定义过滤规则与分组**：首次启动**默认不连接任何主机**，只会连接你主动勾选的主机或你手动开启的包含规则所匹配的主机；支持通配符 Glob、包含、前缀、后缀、正则匹配（按 `Host 别名 / HostName / User / ProxyJump / 配置文件名`），并可随时取消勾选立即断开 SSH 复用连接。
- **低开销并发采集**：复用系统 `/usr/bin/ssh` + `ControlMaster` 长连接，完美兼容 `ProxyJump`、跳板机、`IdentityFile`、`ssh-agent`，单次往返同时拉取 GPU 指标、Compute/Graphics 进程及 `ps` 用户和完整命令行。
- **统一实时看板 + 历史趋势图**：
  - **集群总览**：支持「主机卡片」和「高密度 GPU 矩阵」双视图、汇总 KPI 与迷你趋势曲线。
  - **主机详情**：每卡实时利用率、显存、温度、功耗、风扇转速、P-State，原生 Swift Charts 四图联动与单卡聚焦。
  - **空闲 GPU 发现**：自定义算力/显存阈值，按主机或型号快速找出空闲卡，一键复制 `CUDA_VISIBLE_DEVICES=...` 或直接终端连接。
  - **集群进程汇总**：跨节点查看所有 GPU 进程，按用户统计显存占用并快速筛选。
- **macOS 顶部菜单栏常驻**：顶部状态栏实时显示 `空闲卡数/总卡数`，下拉即可预览各节点 GPU 负载热力条。
- **内置演示模式**：无需真实服务器即可一键预览多节点实时曲线与交互。

## 构建与运行

### 1. 打包为 macOS `.app`（推荐）

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open dist/GTop.app
```

也可以将 `dist/GTop.app` 拖入 `/Applications` 文件夹常驻使用。

### 2. 开发模式运行

```bash
swift run GTop
```

### 3. 运行单元测试

```bash
./scripts/test.sh
```

## 快捷键

- `⌘R`：立即刷新全部监控主机
- `⇧⌘R`：重新解析 `~/.ssh/config`
- `⌘P`：暂停 / 恢复自动轮询
- `⌘,`：打开过滤规则、分组与偏好设置
