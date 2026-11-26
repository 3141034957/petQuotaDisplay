import AppKit

let usage = """
用法：PetQuotaDisplay [--always-show | --follow-codex | --diagnose [--json]]
  --always-show   本次启动强制显示悬浮球
  --follow-codex  仅在 Codex 运行时显示额度悬浮球
  --diagnose      在终端检查各额度来源的本机配置
  --json          将诊断输出为 JSON，供脚本读取
  -h, --help      显示帮助
"""
let arguments = Array(CommandLine.arguments.dropFirst())
let followCodex: Bool
switch arguments {
case [], ["--always-show"]:
    followCodex = false
case ["--follow-codex"]:
    followCodex = true
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
case ["-h"], ["--help"]:
    print(usage)
    exit(0)
default:
    FileHandle.standardError.write(Data("无法识别启动参数。\n\(usage)\n".utf8))
    exit(64)
}

let application = NSApplication.shared
let delegate = AppDelegate(followCodex: followCodex, forceOrbVisible: arguments == ["--always-show"])
application.delegate = delegate
application.run()
