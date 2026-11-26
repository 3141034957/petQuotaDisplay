import AppKit
import QuotaCore

let usage = """
用法：PetQuotaDisplay [显示模式] [--provider 来源] [--period 周期] [--refresh-interval 秒数]
      PetQuotaDisplay --diagnose [--json]
      PetQuotaDisplay --query [--provider 来源]
  --always-show   本次启动强制显示悬浮球
  --follow-codex  仅在 Codex 运行时显示额度悬浮球
  --follow-codex-desktop  仅跟随 Codex 桌面端
  --follow-codex-cli      仅跟随独立 Codex CLI
  --provider      本次启动的来源：\(QuotaProvider.allCases.map(\.rawValue).joined(separator: ", "))
  --period        初次展示的周期：\((QuotaPeriod.allCases.map(\.rawValue) + [QuotaWindowPreference.lowestRemaining]).joined(separator: ", "))
  --refresh-interval  定时刷新间隔：\(QuotaRefreshCadence.allCases.map { String($0.rawValue) }.joined(separator: ", "))，0 表示关闭
  --diagnose      在终端检查各额度来源的本机配置
  --query         在终端读取一次额度并输出 JSON
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
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let json = try encoder.encode(QuotaDiagnostics.checkSources())
        print(String(decoding: json, as: UTF8.self))
    } catch {
        FileHandle.standardError.write(Data("无法生成诊断 JSON。\n".utf8))
        exit(70)
    }
    exit(0)
case _ where arguments.first == "--query":
    let options: QuotaDisplayOptions
    do {
        options = try QuotaDisplayOptions(arguments: Array(arguments.dropFirst()))
        guard options.mode == nil, options.period == nil, options.refreshCadence == nil else {
            FileHandle.standardError.write(Data("--query 只接受 --provider 选项。\n".utf8))
            exit(64)
        }
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(64)
    }
    do {
        let provider = options.provider ?? QuotaPreferences.selectedProvider()
        print(try QuotaQuery.snapshot(from: provider).json())
        exit(0)
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
