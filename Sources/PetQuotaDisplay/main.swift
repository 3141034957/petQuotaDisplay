import AppKit
import QuotaCore

let sourceHelp = QuotaProvider.allCases.map(\.rawValue).joined(separator: ", ")
let periodHelp = (QuotaPeriod.allCases.map(\.rawValue) + [QuotaWindowPreference.lowestRemaining]).joined(separator: ", ")
let formatHelp = QuotaExport.Format.allCases.map(\.rawValue).joined(separator: ", ")
let usage = """
用法：PetQuotaDisplay [显示模式] [--provider 来源] [--period 周期] [--refresh-interval 秒数]
      PetQuotaDisplay --diagnose [--provider 来源] [--json] [--require-ready]
      PetQuotaDisplay --query [查询选项]
      PetQuotaDisplay --list-codex-accounts
      PetQuotaDisplay --history [历史选项]
  --always-show   本次启动强制显示悬浮球
  --follow-codex  仅在 Codex 运行时显示额度悬浮球
  --follow-codex-desktop  仅跟随 Codex 桌面端
  --follow-codex-cli      仅跟随独立 Codex CLI
  --provider      本次启动的来源：\(sourceHelp)
  --period        初次展示的周期：\(periodHelp)
  --refresh-interval  定时刷新间隔：\(QuotaRefreshCadence.allCases.map { String($0.rawValue) }.joined(separator: ", "))，0 表示关闭
  --diagnose      在终端检查各额度来源的本机配置
  --query         在终端读取一次额度，详见 --query --help
  --list-codex-accounts  输出已配置的 Codex 账号标识及本地名称
  --history       读取本机保存的采集记录，详见 --history --help
  --json          将诊断输出为 JSON，供脚本读取
  --version       输出版本和可用的构建提交标识
  -h, --help      显示帮助
"""
let queryUsage = """
用法：PetQuotaDisplay --query [查询选项]
  --provider      来源：\(sourceHelp)，默认使用保存的来源
  --all           并行查询所有来源，输出成功结果和各来源的失败信息
  --providers     并行查询逗号分隔的来源，按输入顺序输出
  --period        只输出指定周期：\(periodHelp)
  --account       Codex 账号本地名称或标识
  --model         查询指定标识的 Codex 模型额度
  --list-models   列出 Codex 返回的额度标识和周期
  --timeout       等待秒数（1–3600），默认 65
  --format        输出格式：\(formatHelp)，默认 json
  --fail-below    输出周期的余量低于指定百分比（0–100）时返回 2
  --require-fresh  结果已过期时返回 3，优先于退出码 2
  -h, --help      显示查询帮助
"""
let historyUsage = """
用法：PetQuotaDisplay --history [历史选项]
  --provider      来源：\(sourceHelp)，默认使用保存的来源
  --all           输出所有来源的历史
  --providers     输出逗号分隔的来源历史，按输入顺序输出
  --period        只输出指定周期：\(periodHelp)
  --account       Codex 账号本地名称或标识
  --model         读取指定标识的 Codex 模型记录，codex 表示主要额度
  --list-models   列出此 Codex 账号已保存的额度标识和周期
  --include-models  批量历史查询同时输出选定账号的独立模型
  --summary       输出各周期的最小、最大和最新余量
  --since         起始采集时间（含边界，带时区的 ISO 8601）
  --until         结束采集时间（含边界，带时区的 ISO 8601）
  --last          相对范围：\(QuotaHistorySeries.TimeRange.allCases.filter { $0.duration != nil }.map(\.rawValue).joined(separator: ", "))
  --limit         最多显示最近多少条采集记录
  --format        输出格式：\(formatHelp)，默认 json
  -h, --help      显示历史查询帮助
"""
let arguments = Array(CommandLine.arguments.dropFirst())
let display: QuotaDisplayOptions
switch arguments {
case ["--version"]:
    print(QuotaBuildInformation.summary)
    exit(0)
case _ where arguments.first == "--diagnose":
    let options: QuotaDiagnostics.Options
    do {
        options = try QuotaDiagnostics.Options(arguments: Array(arguments.dropFirst()))
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(64)
    }
    let report = QuotaDiagnostics.checkSources(provider: options.provider)
    do {
        print(options.json ? try QuotaOutput.json(report) : report.summary)
    } catch {
        FileHandle.standardError.write(Data("无法生成诊断 JSON。\n".utf8))
        exit(70)
    }
    exit(options.requireReady && !report.allSourcesAvailable ? 1 : 0)
case ["--list-codex-accounts"]:
    do {
        print(try QuotaOutput.json(CodexAccountProfile.accountList()))
    } catch {
        FileHandle.standardError.write(Data("无法生成账号列表。\n".utf8))
        exit(70)
    }
    exit(0)
case ["--query", "-h"], ["--query", "--help"]:
    print(queryUsage)
    exit(0)
case ["--history", "-h"], ["--history", "--help"]:
    print(historyUsage)
    exit(0)
case _ where arguments.first == "--history":
    let options: QuotaQueryOptions
    do {
        options = try QuotaQueryOptions(arguments: Array(arguments.dropFirst()), purpose: .savedHistory)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(64)
    }
    do {
        print(try QuotaHistoryCommand.render(options: options))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
case _ where arguments.first == "--query":
    let options: QuotaQueryOptions
    do {
        options = try QuotaQueryOptions(arguments: Array(arguments.dropFirst()))
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(64)
    }
    do {
        if let providers = options.batchProviders {
            let batch = try QuotaQuery.snapshots(from: providers, timeout: options.timeout, selecting: options.period,
                                                accountSelector: options.account)
            print(try batch.render(as: options.format))
            exit(batch.exitStatus(failBelow: options.failBelow, requireFresh: options.requireFresh))
        }
        if options.listModels {
            let report = try QuotaQuery.codexReport(timeout: options.timeout, accountSelector: options.account)
            print(try CodexModelCatalog(report).render(as: options.format))
            exit(0)
        }
        let provider = options.provider ?? QuotaPreferences.selectedProvider()
        var export = try QuotaQuery.snapshot(from: provider, timeout: options.timeout,
                                             modelID: options.modelID, accountSelector: options.account)
        if let period = options.period { try export.selectPeriod(period) }
        print(try export.render(as: options.format))
        exit(export.exitStatus(failBelow: options.failBelow, requireFresh: options.requireFresh))
    } catch let interruption as QuotaQuery.Interrupted {
        exit(interruption.exitStatus)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
case ["-h"], ["--help"]:
    print(usage)
    exit(0)
default:
    do {
        display = try QuotaDisplayOptions(arguments: arguments)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n\(usage)\n".utf8))
        exit(64)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate(displayOptions: display)
application.delegate = delegate
application.run()
