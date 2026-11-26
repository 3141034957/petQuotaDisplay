import AppKit

let usage = """
用法：PetQuotaDisplay [--always-show | --follow-codex | --diagnose]
  --always-show   立即显示额度悬浮球（默认）
  --follow-codex  仅在 Codex 运行时显示额度悬浮球
  --diagnose      在终端检查各额度来源的本机配置
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
    print(QuotaDiagnostics.summary())
    exit(0)
case ["-h"], ["--help"]:
    print(usage)
    exit(0)
default:
    FileHandle.standardError.write(Data("无法识别启动参数。\n\(usage)\n".utf8))
    exit(64)
}

let application = NSApplication.shared
let delegate = AppDelegate(followCodex: followCodex)
application.delegate = delegate
application.run()
