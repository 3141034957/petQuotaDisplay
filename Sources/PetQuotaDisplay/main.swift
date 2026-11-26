import AppKit
import QuotaCore

let usage = """
用法：PetQuotaDisplay [显示模式] [--provider 来源] [--period 周期] [--refresh-interval 秒数]
      PetQuotaDisplay --diagnose [--json]
      PetQuotaDisplay --query [查询选项]
      PetQuotaDisplay --list-codex-accounts
  --always-show   本次启动强制显示悬浮球
  --follow-codex  仅在 Codex 运行时显示额度悬浮球
  --follow-codex-desktop  仅跟随 Codex 桌面端
  --follow-codex-cli      仅跟随独立 Codex CLI
  --provider      本次启动的来源：\(QuotaProvider.allCases.map(\.rawValue).joined(separator: ", "))
  --period        初次展示的周期：\((QuotaPeriod.allCases.map(\.rawValue) + [QuotaWindowPreference.lowestRemaining]).joined(separator: ", "))
  --refresh-interval  定时刷新间隔：\(QuotaRefreshCadence.allCases.map { String($0.rawValue) }.joined(separator: ", "))，0 表示关闭
  --diagnose      在终端检查各额度来源的本机配置
  --query         在终端读取一次额度并输出 JSON
  --timeout       单次查询等待秒数，默认 65 秒
  --format        终端查询格式：\(QuotaExport.Format.allCases.map(\.rawValue).joined(separator: ", "))，默认 json
  --fail-below    输出周期的余量低于指定百分比时，退出码为 2
  --require-fresh  结果已过期时，退出码为 3
  --model         查询指定标识的 Codex 模型额度
  --list-models   列出 Codex 返回的额度标识和周期
  --account       本次查询的 Codex 账号名称或标识
  --list-codex-accounts  输出已配置的 Codex 账号标识及本地名称
  --json          将诊断输出为 JSON，供脚本读取
  -h, --help      显示帮助
"""
let arguments = Array(CommandLine.arguments.dropFirst())
let display: QuotaDisplayOptions
switch arguments {
case ["--diagnose"]:
    print(QuotaDiagnostics.checkSources().summary)
    exit(0)
case ["--diagnose", "--json"]:
    do {
        print(try QuotaOutput.json(QuotaDiagnostics.checkSources()))
    } catch {
        FileHandle.standardError.write(Data("无法生成诊断 JSON。\n".utf8))
        exit(70)
    }
    exit(0)
case ["--list-codex-accounts"]:
    do {
        print(try QuotaOutput.json(CodexAccountProfile.accountList()))
    } catch {
        FileHandle.standardError.write(Data("无法生成账号列表。\n".utf8))
        exit(70)
    }
    exit(0)
case _ where arguments.first == "--query":
    let options: QuotaQueryOptions
    do {
        options = try QuotaQueryOptions(arguments: Array(arguments.dropFirst()))
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(64)
    }
    do {
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
