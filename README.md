# Codex 周额度悬浮球

一个原生 macOS 悬浮球，用来替代占空间的宠物展示，实时显示当前 Codex 周额度的剩余百分比和下一次自动重置时间。

## 运行

需要 macOS 13 或更高版本、已安装并登录 Codex CLI，以及 Xcode Command Line Tools。

```bash
python3 main.py
```

也可以直接运行：

```bash
swift run PetQuotaDisplay
```

首次运行会编译原生程序，后续启动会快很多。悬浮球不会出现在 Dock 中，并会始终置顶：

- 拖动：移动悬浮球，位置会自动保存。
- 单击：立即刷新周额度。
- 右键：切换额度周期、切换 ChatGPT 账号、查看精确重置时间，或退出。
- 自动刷新：每 5 分钟从本机 Codex `app-server` 读取一次。

如果 Codex CLI 不在常见位置，可在启动前设置：

```bash
CODEX_CLI_PATH=/你的路径/codex python3 main.py
```

## 数据口径

Codex 返回的是周窗口 `usedPercent`，悬浮球显示 `100 - usedPercent`。程序只匹配 10,080 分钟（7 天）的周额度窗口，不会展示其他周期。

数据只通过本机 Codex CLI 获取，不会上传到第三方。

## 双账号切换

右键悬浮球，打开“切换额度账号”：

- “当前 Codex 账号”直接复用 Codex CLI/桌面端的当前登录态。
- 首次使用“备用账号”时，选择“登录备用账号…”，浏览器会打开 Codex 官方登录页；使用“通过 Apple 登录”完成授权即可。
- 登录一次后，两个账号会保持各自的刷新令牌，之后可在右键菜单中即时切换额度视图。

备用账号使用独立的 `CODEX_HOME`，凭据保存在 `~/Library/Application Support/PetQuotaDisplay/CodexAccounts/secondary/auth.json`。目录权限会被限制为仅当前 macOS 用户可访问；该文件包含登录令牌，请勿复制、提交到 Git 或分享。切换这里只影响额度悬浮球，不会强制登出或切换正在运行的 Codex 桌面端。

## 跟随 Codex 自动启动

运行安装脚本后，macOS 登录时会启动一个无窗口监听器。它通过系统应用启动事件监听 `com.openai.codex`，并通过 macOS 原生进程接口检测独立 Codex CLI：桌面 Codex 或 Codex CLI 任一运行时显示悬浮球；两者都退出后隐藏悬浮球并停止额度读取。

```bash
zsh scripts/install_autostart.sh
```

这个方案不会修改或注入 Codex 应用，不受 Codex 代码签名影响。若要停用：

```bash
zsh scripts/uninstall_autostart.sh
```
