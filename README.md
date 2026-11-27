# Agent 额度悬浮球

原生 macOS 额度悬浮球和工作台。悬浮球显示 Codex、Gemini、Claude Code、OpenCode Go 或 Kimi Code 的余量和重置时间。工作台管理 Codex、CodeBuddy、Gemini 的账号和客户端实例，并可启动 Codex 本机 API 网关。

## 运行

需要 macOS 13 或更高版本和 Xcode Command Line Tools。查看 Codex 额度需要已安装并登录的 Codex CLI，查看 Gemini 额度需要已安装并登录的 Antigravity CLI。

```bash
python3 main.py
```

也可以直接运行：

```bash
swift run PetQuotaDisplay
```

独立运行会立即显示额度，并沿用上次选择的显示方式。运行 `python3 main.py --always-show` 可在本次启动强制显示悬浮球，使用 `--follow-codex` 可在 Codex 运行时显示额度。用 `python3 main.py --help` 查看启动选项。

如果只想跟随一种 Codex 使用方式，可用 `--follow-codex-desktop` 或 `--follow-codex-cli`，分别跟随桌面端或独立终端 CLI。

可用 `python3 main.py --provider gemini` 指定本次启动时的来源。切换来源会照常保存，而仅使用启动参数会保留已有设置。

可以组合 `--provider openCodeGo --period monthly` 指定初次展示的周期。`--period lowestRemaining` 会自动选择剩余最少的周期。切换来源、账号或手动选择周期后，会使用对应的保存设置。

`--refresh-interval 120` 可临时指定每 120 秒刷新，`--refresh-interval 0` 则关闭本次运行的定时刷新。

### 额度工作台

从悬浮球或菜单栏选择“打开额度工作台”，也可以单独运行窗口。

```bash
python3 main.py --workspace
```

| 平台 | 账号和额度 | 客户端实例 |
| --- | --- | --- |
| Codex | 浏览器登录、导入 `auth.json` 或保存 OpenAI API Key。ChatGPT 登录可查看主要额度和独立模型额度。 | Codex CLI。已安装 Codex 桌面端时，可为 ChatGPT 登录账号单独打开桌面实例。 |
| CodeBuddy | 导入含 `access_token` 的账号 JSON，或输入访问令牌、API Key。账号登录可查询平台返回的个人或企业 Credits。 | CodeBuddy CLI，每个实例使用独立配置目录。 |
| Gemini | 导入 Gemini CLI 的 `oauth_creds.json`，填写适用的 Google Cloud 项目，或保存 API Key。工作台也可读取当前 Antigravity 登录的额度。 | Gemini CLI 为每个账号使用独立登录目录。Antigravity 实例使用本机当前登录。 |

在“账号与额度”选择账号并刷新额度。在账号菜单选择“为此账号新建实例”，或到“客户端实例”指定账号和项目目录。实例启动时使用绑定的账号以及所选项目，几个不同账号可同时运行。API Key 账号的计费与用量由各平台控制台提供。

在“API 网关”添加一个独立 OpenAI API Key，或选用工作台里已保存的 Codex API Key。启动后，客户端的 Base URL 填 `http://127.0.0.1:14550/v1`（端口可改），API Key 填对应成员的“本机 Key”。在 Codex CLI 实例中选择该成员，工作台会自动填好两项。绑定 ChatGPT 登录账号的网关成员也需要提供 OpenAI API Key。

网关监听 IPv4 回环地址，支持 HTTP 方式访问模型列表、Responses（含流式与 compact）和 Chat Completions。每个本机 Key 对应一个成员。工作台保留最近 200 条转发记录，包含时间、成员、模型、路径、状态与耗时。OpenAI API Key 保存在 macOS 钥匙串，请求正文和凭据不会写入网关记录。

### 终端查询

运行 `python3 main.py --diagnose` 可在终端检查 Codex、Gemini、Kimi 的命令是否可用，以及 Claude Code 是否采集过额度，同时查看构建版本、刷新周期和悬浮球外观设置。检查在本机完成，无需登录或读取钥匙串。脚本可通过 `--diagnose --json` 读取结构化结果。

诊断也会报告本机历史存档是否启用或无法读取，以及共保存了多少条记录。

加上 `--diagnose --provider gemini` 可指定只检查一个来源，也可与 `--json` 一起使用。

脚本可加 `--require-ready`。配置缺失、缓存过期或需要在应用内检查时，诊断会照常输出，退出码为 `1`。诊断只检查本机配置，验证登录和实际额度请运行实时查询。

用 `python3 main.py --query --provider gemini` 可在终端读取一次额度并输出 JSON，无需打开悬浮球。省略 `--provider` 时使用保存的来源。该命令沿用各来源原有的登录和密钥配置，Claude Code 会读取本机状态栏快照。运行 `python3 main.py --query --help` 可查看所有查询参数。

用 `python3 main.py --query --all --format text` 可并行查询所有来源，共用同一个等待期限。某个来源缺少配置或查询失败时，命令仍会输出其他来源的结果并返回 `1`。CSV 会用 `error` 列标记失败来源。

用 `--query --providers gemini,kimiCode` 可只查询指定来源，结果按输入顺序排列。

加上 `--period weekly` 只输出周额度，`--period lowestRemaining` 则选择剩余百分比最低的周期。指定的周期没有数据时，命令会返回错误。

用 `--timeout 10` 可将网络来源的单次查询等待时间缩短为 10 秒。支持 1 到 3600 秒，各来源本身也有超时限制。

查询期间按 Ctrl+C 会停止查询并回收子进程，退出码为 `130`。

加上 `--format text` 可直接在终端查看余额与重置时间。该格式会标记历史结果，时间使用 UTC。

`--format csv` 会为每个返回的周期输出一行，适合导入已有报表或与其他命令组合处理。

CSV 会给以公式符号开头的文本添加单引号，便于以文本导入表格。JSON 保留原始模型标识。

脚本可加 `--fail-below 20`。任一输出周期的余量低于 20% 时，结果仍会照常输出，命令返回退出码 `2`。查询失败时返回 `1`。

如果脚本要求有效快照，可加 `--require-fresh`。过期结果仍会输出，退出码为 `3`，优先于低额度退出码。

Codex 查询可加 `--model <额度标识>` 获取独立模型额度。省略 `--model` 或用 `--model codex` 时读取主要额度。

用 `python3 main.py --query --list-models --format text` 可查看账号当前可用的额度标识及其周期。

多个 Codex 账号共用这台 Mac 时，可用 `--account '工作账号'` 指定本次查询的账号名，也可使用账号标识。此次选择只用于当前命令。

用 `python3 main.py --list-codex-accounts` 可查看已配置的标识、本地名称、选中项和凭据是否已保存。该列表只读取本机配置，不包含凭据内容。

如果 OpenCode Go 的钥匙串密钥需要交互授权，终端查询会提示先在悬浮球授权。

### 终端历史查询

启用“跨启动保留采集记录”后，用 `python3 main.py --history --provider gemini` 可直接输出本机存档的 JSON。省略 `--provider` 时读取保存的来源，Codex 支持 `--account` 切换读取的账号。读取历史无需网络。运行 `python3 main.py --history --help` 可查看所有历史查询参数。

用 `--history --all` 可一次读取所有来源的历史，也可用 `--history --providers gemini,kimiCode` 指定来源。Codex 默认读取选定账号的主要额度，`--limit` 分别应用到每个来源。

批量历史查询包含 Codex 时可加 `--include-models`，在主要额度之后输出该账号保存的独立模型。`--limit` 分别应用到主要额度和每个模型。

用 `--history --provider codex --model <额度标识>` 查询独立模型的采集记录。省略模型或指定 `--model codex` 时读取主要额度。

用 `--history --list-models --format text` 离线列出 Codex 账号已存档的额度标识，以及每个标识采集过的周期。

历史查询可加 `--period weekly` 只保留周额度记录，也可用 `--period lowestRemaining` 为每次采集选择当时余量最低的周期。

使用 `--since`、`--until` 可限定采集时间，边界也包含在结果中，例如 `--since 2026-11-26T09:00:00+08:00`。

也可用 `--last 6h` 等相对范围。每个来源或模型以其最新采集为基准，指定 `--until` 时使用该时间之前的最近一条记录。

历史查询也支持 `--format text` 和 `--format csv`，CSV 与趋势窗口的导出使用相同字段。

用 `--limit 5` 可只输出筛选后最新的 5 次采集，行仍按采集时间排序。

用 `--history --all --summary --format text` 可查看筛选后各周期的采集条数、最低与最高余量和最新余量。统计也支持 JSON 和 CSV。

用 `python3 main.py --inspect-history quota-history.json` 可检查一个导出的历史 JSON 并查看统计。这个命令直接读取指定文件，无需启用本机存档。

### 悬浮球和菜单栏

首次运行会编译原生程序，后续启动会快很多。悬浮球默认置顶，程序不会出现在 Dock 中：

- 拖动：移动悬浮球，松开后会自动收回屏幕的可见区域并保存位置。拔掉显示器时会临时移到可见区域，原来保存的位置重新可见时会自动移回。
- 右键“外观”可把悬浮球移到所在显示器的任一角落、重置到主显示器右下角、切换尺寸，或将底部时间改为重置倒计时或最近采集时间。隐藏底部时间可以放大百分比。右键菜单会保留精确的重置时间。
- 可在“外观”关闭置顶。启用菜单栏额度后，可从菜单栏选择“将悬浮球移到前台”。
- 悬浮球默认可以出现在所有桌面和全屏空间。在“外观”关闭该选项后，窗口遵循 macOS 的桌面归属。
- 可在“外观”锁定悬浮球位置以避免误拖，单击刷新和手动重置位置仍可使用。
- 连接多台显示器时，“外观 → 移到其他显示器”可将悬浮球移到指定屏幕，并保留相对位置。
- 在“外观”可把悬浮球不透明度设为 100%、85% 或 70%，设置会保留到下次启动。
- macOS 开启“降低透明度”时，悬浮球会使用全不透明显示。关闭该系统选项后会恢复选定的不透明度。
- macOS 开启“增强对比度”时，悬浮球会加深背景并加强进度环与文字的对比。
- “百分比显示方式”可将悬浮球和菜单栏切换为已用百分比。低额度警戒线仍按余量计算。
- 从悬浮球或菜单栏的菜单选择“关于额度悬浮球”可查看版本。打包版还会在“关于”窗口及诊断中显示构建号和可用的 Git 提交标识。
- 在“外观”勾选“在菜单栏显示额度”，可在 macOS 菜单栏同步查看所选周期。尾部省略号表示正在刷新，百分比前的 `~` 表示上次数据。点击菜单栏额度可打开操作菜单。选择“仅在菜单栏显示”后，额度会继续更新，可在菜单栏选择“显示悬浮球”恢复窗口。
- 单击立即刷新当前额度。
- 右键可查看当前来源所有可用周期的剩余额度和精确重置时间，也可切换来源、选择悬浮球展示的周期，或退出。每个来源会记住自己选择的额度周期，查看 Codex 时也可切换 ChatGPT 账号。
- 选择“自动展示剩余最少的周期”后，悬浮球和菜单栏会随每次采集切换到剩余百分比最低的可用周期。
- 在“外观”开启“在菜单栏显示来源名称”后，菜单栏会同时显示来源与额度，例如 `Gemini 80%`。
- 屏幕共享或录制时，可在“外观”隐藏 Codex 账号邮箱。账号菜单和趋势窗口仍会显示本地别名或编号。
- 悬浮球默认每 30 秒刷新当前来源，并记住上次选择的来源。启用定时刷新时，从睡眠唤醒也会刷新。右键“定时刷新”可调整间隔或关闭定时刷新，单击仍可手动刷新。Claude Code 的刷新会重新读取本地状态栏快照。
- 右键选择“复制额度摘要”可将当前来源的各周期额度、重置时间和更新时间复制为纯文本。若刷新失败，摘要也会注明数据状态。
- 选择“复制额度 JSON”可复制结构化数据，时间使用 UTC 格式，便于脚本处理。

### 低额度提醒

- “外观”里的“低额度警戒线”可调整悬浮球显示红色的百分比，默认是 20%。可从预设选择，也可输入 0 到 100 的整数。余量等于警戒线时也会标红。
- 菜单栏用警告图标标出当前所选周期达到警戒线，悬停和旁白也能读取这一状态。
- 可在“低额度提醒”开启声音。新采集到某个周期触及警戒线时会响一声，余量持续偏低时不会每次刷新都响。
- 使用打包的 `.app` 时，“低额度提醒”还可开启系统通知。第一次开启会请求 macOS 通知权限，通知会列出本次触及警戒线的周期。
- 如果 macOS 的通知权限随后被关闭，应用会取消勾选系统通知并在“低额度提醒”显示状态。
- 点击系统通知可打开触发提醒的来源、账号或独立模型的趋势窗口。
- “低额度提醒周期”可分别勾选 5 小时、周和月周期。此设置同时适用于声音和系统通知。
- 声音或系统通知开启时，可在“低额度提醒”暂停 1 小时，也可提前恢复。

### 采集记录和趋势

- 右键“最近读取的额度”可查看或复制本次运行中各来源上一次成功读取的数据和采集时间。Codex 的结果按当前选择的账号显示。
- 连续两次采集同一来源后，总览会标注变化的剩余额度或重置时间。清空总览记录后，下次刷新会重新记录，当前正在展示的额度仍可查看。
- 每个来源、Codex 账号的主要额度和独立模型分别默认保留最新 120 条采集记录，可在“最近读取的额度”将上限增加到 480 或 1440 条。调低上限会清除超出的旧记录。在“最近采集记录”里可查看最新 8 条时间和余量。
- 在“最近读取的额度”勾选“跨启动保留采集记录”，可将余量与时间保存在本机的 `Library/Application Support/PetQuotaDisplay/QuotaHistory`。关闭此选项会清除磁盘记录，本次已显示的采集记录仍在内存中。存档不包含登录凭据或账号邮箱。
- 存档无法读取时，菜单会显示“重置本机存档”，可在确认后清除存档并重新启用保存。
- “在访达打开存档目录”可从菜单查看本机存档文件。
- 打开“查看额度趋势”后可按周期查看余量变化。缺少周期或模型数据时，或重置时间发生变化时，折线会断开。
- 已采集到当前额度时，右键菜单顶部的“查看当前额度趋势”可直接打开所选来源、账号或模型。
- 将鼠标移到趋势图上可查看最近数据点的采集时间、余量和已知的重置时间。单击可固定该记录，再次单击或按 Esc 可取消固定。
- 趋势图的橙色虚线表示该次采集报告了不同的重置时间。
- 趋势图的水平虚线标出当前设置的低额度警戒线。
- 趋势图下方显示所选时间范围内的采集条数和最低、最高余量。
- 也可使用趋势图下方的前后按钮逐条查看记录，按钮支持键盘焦点和旁白。
- 趋势窗口可选择最近 15 分钟、1 小时、6 小时、24 小时、7 天或全部保留记录，时间范围以最新采集为准。“导出”菜单可复制或保存 JSON 和 CSV。导出仅包含所选周期和范围，时间使用 UTC。
- 可同时打开多个来源、账号和模型的趋势窗口做对照，各窗口会随对应的新采集更新。清空对应记录会关闭该窗口。
- 从“最近读取的额度 → 其他 Codex 账号”可以查看其他账号已有的采集记录和趋势，无需切换正在刷新的账号。
- 在某个来源的子菜单中可单独清除它的采集记录。Codex 只清除当前选中账号的记录。
- “独立模型”子菜单可单独清除某个模型的记录，账号的主要额度和其他模型可继续查看。
- 替换某个 Codex 账号的登录时，会清除该账号槽位已有的采集记录。
- 同一子菜单可将该来源保留的所有周期和采集记录复制为 JSON。
- “复制全部来源的采集记录 JSON”会一并复制各来源的可见记录。Codex 只包含当前账号的主要额度和独立模型。
- 同一菜单也可将全部来源的记录保存为 JSON 或 CSV 文件。
- “导入采集记录 JSON”可合并应用导出的历史。导入 Codex 记录前会显示接收账号。采集时间相同的记录会保留本机版本，晚于本机时间的记录会跳过。导入后仍按设置的条数上限保留最近记录。

### 刷新与连接

刷新时会继续显示上次成功获取的额度。切回已读过的 Gemini、OpenCode Go 或 Kimi Code 时，等待新结果期间也会标注并显示上次读取的数据。刷新失败时，悬浮球会变灰并标注为上次结果；悬停提示和右键菜单可查看错误原因及最后更新时间，避免把旧数据当作实时额度。切换账号或确认账号已退出登录后会清除旧额度。

Codex 服务初始化和普通额度请求超过 20 秒未响应时，会终止当前连接并在 5 秒后自动重连；初始化失败或服务意外退出也会自动恢复。

如果 Codex CLI 不在常见位置，可在启动前设置：

```bash
CODEX_CLI_PATH=/你的路径/codex python3 main.py
```

## Codex 额度

悬浮球显示 `100 - usedPercent`。程序读取 300 分钟（5 小时）和 10,080 分钟（7 天）两个额度窗口，右键可切换显示哪一个。两个窗口都是可选的：ChatGPT Pro 之类的套餐只会下发周窗口，此时 5 小时额度会自动隐藏并回退显示周额度。

如果 Codex 同时返回模型的独立额度，右键“选择 Codex 额度”可查看并切换到该模型。每个账号会保存选择，所选模型暂时没有数据时会回退到主要额度。“最近读取的额度 → Codex → 独立模型”可逐个查看趋势、导出 CSV 或复制 JSON。主要额度和独立模型按账号分别保存。

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

右键切换到 **Claude Code**。使用 Claude 订阅账号进行一次正常对话后，状态栏会提供 5 小时和 7 天额度。启用自动刷新时，悬浮球会在状态栏写入新快照后更新。某个周期过期时会优先显示仍有效的周期。缺少重置时间时，从采集时刻起满一个周期即视为过期。如果都已过期，会把结果标为上次缓存，等 Claude Code 写入新数据。采集脚本只保存用量百分比、重置时间和采集时间。[Claude Code 状态栏文档](https://code.claude.com/docs/en/statusline#rate-limits)

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
- Codex 会为每个额度账号分别记住悬浮球展示的周期。
- 选择“重命名当前额度账号…”可为账号设置本机名称，留空恢复默认名称。
- 在“删除额度账号”子菜单中可以删除不再需要的账号；如果删除的是当前选中账号，悬浮球会自动选择列表中的下一个账号。
- 如果新增账号的登录被取消，可以选中它，再使用“登录当前额度账号…”继续登录。
- 登录时悬浮球会提示到浏览器继续，也可以在账号菜单点“取消当前登录”。

新增账号各自使用独立的 `CODEX_HOME`，凭据保存在 `~/Library/Application Support/PetQuotaDisplay/CodexAccounts/<账号 ID>/auth.json`。目录权限会被限制为仅当前 macOS 用户可访问；该文件包含登录令牌，请勿复制、提交到 Git 或分享。删除额度账号会同时删除其独立目录和登录凭据。切换或删除这里只影响额度悬浮球，不会强制登出或切换正在运行的 Codex 桌面端。旧版本保存的“备用账号”会自动出现在新列表中，无需重新登录。

## 登录时自动启动

运行安装脚本后，macOS 登录时会启动一个无窗口监听器。它通过系统应用启动事件监听 `com.openai.codex`，并检测当前 macOS 用户运行的独立 Codex CLI。桌面 Codex 或 Codex CLI 任一运行时显示额度，两者都退出后隐藏额度并停止读取。跟随模式菜单中的“本次隐藏额度显示”会在当前 Codex 会话内隐藏悬浮球和菜单栏额度，监听器会在 Codex 完整退出后的下一次启动时重新显示额度。监听器异常退出时 LaunchAgent 会自动恢复。

```bash
zsh scripts/install_autostart.sh
```

首次安装默认跟随 Codex。主要使用其他 agent 时，可以选择登录后直接显示悬浮球。安装后也可显式切回跟随模式。

使用 `--always-show` 安装时，LaunchAgent 会显式强制显示悬浮球，包括此前启用过仅菜单栏显示的情况。窗口层级采用“外观”中保存的置顶设置。

```bash
zsh scripts/install_autostart.sh --always-show
zsh scripts/install_autostart.sh --follow-codex
```

安装脚本也接受 `--follow-codex-desktop` 和 `--follow-codex-cli`。以后直接运行安装脚本更新时，会保留选定的跟随方式。

运行 `zsh scripts/install_autostart.sh --status` 可查看安装状态、模式，以及 LaunchAgent 是否已加载。

在 `--status` 后加 `--json` 可读取结构化状态。输出包括二进制是否可执行、配置文件状态、已配置的模式和当前会话是否已加载。

运行 `zsh scripts/install_autostart.sh --dry-run` 可只预览将使用的路径和模式，也可同时传入一个模式参数。

可加 `--at-next-login` 为下一次图形登录准备自启动配置。此选项适合通过终端远程操作，当前会话的 LaunchAgent 会继续按已有配置运行。

运行 `zsh scripts/install_autostart.sh --always-show --print-plist` 可在终端检查实际生成的 LaunchAgent 配置。预览不会编译程序或安装自启动项。

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

## 构建 macOS 应用

运行 `zsh scripts/package_app.sh` 会在 `.build/distribution` 下生成一个本机签名、带原生应用图标的 `PetQuotaDisplay.app`，并打印路径。也可传入其他输出目录。双击打开时会沿用本机已有的悬浮球设置和 Codex 额度账号。

需要压缩包时，可运行 `zsh scripts/package_app.sh --zip`，同一目录会同时生成 `PetQuotaDisplay.zip`。

使用 `zsh scripts/package_app.sh --universal --zip` 可将 Apple 芯片和 Intel Mac 所需的两种架构打包到同一个应用中。

加上 `--checksum` 会同时生成 ZIP 和 `PetQuotaDisplay.zip.sha256`。收到这两个文件后，可在同一目录运行 `shasum -a 256 -c PetQuotaDisplay.zip.sha256` 核对压缩包。

加上 `--json` 可让脚本直接读取生成的应用、压缩包、校验文件路径、构建提交标识，以及实际包含的架构和最低 macOS 版本。

发布时可用 `--version 1.2.3 --build-number 42` 设置本次应用的版本和构建号。打包结果的 JSON 会报告这两个值。

用 `python3 main.py --version` 查看版本。通过 Git 工作区打包的 `.app` 会记录构建时的提交标识，包含未提交改动时会带 `+dirty`。

脚本可用 `--version --json` 读取版本、可用的构建号与提交标识。
