# Agent 额度悬浮球

一个原生 macOS 悬浮球，显示 Codex、Gemini、Claude Code、OpenCode Go 或 Kimi Code 额度的剩余百分比和下一次重置时间。

## 运行

需要 macOS 13 或更高版本和 Xcode Command Line Tools。查看 Codex 额度需要已安装并登录的 Codex CLI，查看 Gemini 额度需要已安装并登录的 Antigravity CLI。

```bash
python3 main.py
```

也可以直接运行：

```bash
swift run PetQuotaDisplay
```

首次运行会编译原生程序，后续启动会快很多。悬浮球不会出现在 Dock 中，并会始终置顶：

- 拖动：移动悬浮球，松开后会自动收回当前屏幕的可见区域并保存位置；拔掉显示器或调整屏幕布局后也会自动校正。
- 单击立即刷新当前额度。
- 右键可查看当前来源所有可用周期的剩余额度和精确重置时间，也可切换来源、选择悬浮球展示的周期，或退出。每个来源会记住自己选择的额度周期，查看 Codex 时也可切换 ChatGPT 账号。
- 悬浮球每 30 秒刷新当前来源，并记住上次选择的来源。Claude Code 的刷新会重新读取本地状态栏快照。
- 右键选择“复制额度摘要”可将当前来源的各周期额度、重置时间和更新时间复制为纯文本。若刷新失败，摘要也会注明数据状态。

刷新时会继续显示上次成功获取的额度。刷新失败时，悬浮球会变灰并标注为上次结果；悬停提示和右键菜单可查看错误原因及最后更新时间，避免把旧数据当作实时额度。切换账号或确认账号已退出登录后会清除旧额度。

Codex 服务初始化和普通额度请求超过 20 秒未响应时，会终止当前连接并在 5 秒后自动重连；初始化失败或服务意外退出也会自动恢复。

如果 Codex CLI 不在常见位置，可在启动前设置：

```bash
CODEX_CLI_PATH=/你的路径/codex python3 main.py
```

## Codex 额度

悬浮球显示 `100 - usedPercent`。程序读取 300 分钟（5 小时）和 10,080 分钟（7 天）两个额度窗口，右键可切换显示哪一个。两个窗口都是可选的：ChatGPT Pro 之类的套餐只会下发周窗口，此时 5 小时额度会自动隐藏并回退显示周额度。

如果 Codex 同时返回模型的独立额度，右键菜单的“其他 Codex 额度”会列出这些额度的可用周期和重置时间。

## Gemini 额度

在终端运行 `agy` 登录 Google 账号，然后在悬浮球右键菜单选择 **切换额度来源 → Gemini**。悬浮球通过 `agy -p /usage --output-format json` 读取该账号的共享 Gemini 模型额度，显示 CLI 提供的 5 小时和每周剩余额度及重置时间。该指令需要 Antigravity CLI 1.1.11 或更高版本。 [安装和登录](https://antigravity.google/docs/cli/install/) · [额度说明](https://antigravity.google/docs/cli/commands/usage)

程序从 `PATH`、`~/.local/bin` 和常见 Homebrew 目录查找 `agy`。也可以指定可执行文件的绝对路径：

```bash
ANTIGRAVITY_CLI_PATH=/你的路径/agy python3 main.py
```

## Claude Code 额度

在 Claude Code 的用户设置 `~/.claude/settings.json` 中加入下面的 `statusLine` 配置，把命令里的脚本路径替换为当前仓库中的绝对路径。保留已有的其他设置。

```json
{
  "statusLine": {
    "type": "command",
    "command": "/usr/bin/env python3 '/你的路径/petQuotaDisplay/scripts/capture_claude_usage.py'"
  }
}
```

如果已有自定义状态栏，可以在现有脚本读取 stdin 后，把同一份 JSON 传给采集脚本，再继续原有的显示逻辑。采集脚本无需输出到状态栏。

```bash
payload=$(cat)
printf '%s\n' "$payload" | /usr/bin/env python3 '/你的路径/petQuotaDisplay/scripts/capture_claude_usage.py'
# 继续使用 "$payload" 生成原有的状态栏输出
```

右键切换到 **Claude Code**。使用 Claude 订阅账号进行一次正常对话后，状态栏会提供 5 小时和 7 天额度。悬浮球显示最近采集的数据及采集时间。某个周期过期时会优先显示仍有效的周期。如果都已过期，会把结果标为上次缓存，等 Claude Code 写入新数据。采集脚本只保存用量百分比、重置时间和采集时间。[Claude Code 状态栏文档](https://code.claude.com/docs/en/statusline#rate-limits)

## OpenCode Go 额度

右键切换到 **OpenCode Go**，再点 **设置 OpenCode Go API 密钥…**，输入订阅对应的 API 密钥。密钥保存在 macOS 钥匙串中，可从同一菜单替换或清除。悬浮球通过 OpenCode Go 的官方用量接口查询 5 小时、每周和每月额度，右键可选择显示周期。该来源适用于 OpenCode Go、Go Plus 和 Go Teams。[OpenCode Go 用量接口](https://opencode.ai/docs/console/go/#usage)

## Kimi Code 额度

安装新版 Kimi Code CLI，运行 `kimi login` 登录订阅账号，然后右键切换到 **Kimi Code**。悬浮球使用 `kimi web --json` 启动仅本机可访问的服务并读取官方额度接口，切换到其他来源或退出时会停止该服务。按账号实际返回的字段显示 5 小时、每周和每月额度。若同时返回编码月额度和会员总月额度，优先显示编码月额度。[Kimi Code 命令参考](https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/reference/kimi-command.md) · [Kimi Code 本地接口](https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/reference/server-api.md)

如果程序找不到 `kimi`，可在独立启动时指定它的绝对路径。

```bash
KIMI_CLI_PATH=/你的路径/kimi python3 main.py
```

## 多账号切换

右键悬浮球，打开“切换额度账号”：

- 选择“新加额度账号…”，浏览器会打开 Codex 官方登录页；完成授权后，该账号会保留在切换列表中。
- 可以按需添加多个额度账号，每个账号都会保持自己的刷新令牌，之后可在右键菜单中即时切换额度视图。
- 在“删除额度账号”子菜单中可以删除不再需要的账号；如果删除的是当前选中账号，悬浮球会自动选择列表中的下一个账号。
- 如果新增账号的登录被取消，可以选中它，再使用“登录当前额度账号…”继续登录。

新增账号各自使用独立的 `CODEX_HOME`，凭据保存在 `~/Library/Application Support/PetQuotaDisplay/CodexAccounts/<账号 ID>/auth.json`。目录权限会被限制为仅当前 macOS 用户可访问；该文件包含登录令牌，请勿复制、提交到 Git 或分享。删除额度账号会同时删除其独立目录和登录凭据。切换或删除这里只影响额度悬浮球，不会强制登出或切换正在运行的 Codex 桌面端。旧版本保存的“备用账号”会自动出现在新列表中，无需重新登录。

## 登录时自动启动

运行安装脚本后，macOS 登录时会启动一个无窗口监听器。它通过系统应用启动事件监听 `com.openai.codex`，并通过 macOS 原生进程接口检测独立 Codex CLI：桌面 Codex 或 Codex CLI 任一运行时显示悬浮球；两者都退出后隐藏悬浮球并停止额度读取。跟随模式菜单中的“本次隐藏悬浮球”只隐藏当前 Codex 会话，监听器仍会留驻，并在 Codex 完整退出后的下一次启动时重新显示；监听器异常退出时 LaunchAgent 也会自动恢复。

```bash
zsh scripts/install_autostart.sh
```

首次安装默认跟随 Codex。主要使用其他 agent 时，可以选择登录后直接显示悬浮球。安装后也可显式切回跟随模式。

```bash
zsh scripts/install_autostart.sh --always-show
zsh scripts/install_autostart.sh --follow-codex
```

更新时直接重新运行安装脚本即可。脚本会编译 Release 版本、替换程序并重启 LaunchAgent，保留已选的自启动模式、账号和悬浮球设置。独立运行 `python3 main.py` 会打开另一个实例。

这个方案不会修改或注入 Codex 应用，不受 Codex 代码签名影响。若要停用：

```bash
zsh scripts/uninstall_autostart.sh
```

卸载脚本会停止后台监听并删除 LaunchAgent 自启动配置，保留程序、已登录账号和悬浮球设置。

## 开发验证

```bash
swift test
swift build -c release
```

测试覆盖额度解析、刷新状态、屏幕位置校正和本地服务的故障恢复。连接测试使用本地模拟进程或模拟 HTTP 响应，无需账号凭据和网络。
