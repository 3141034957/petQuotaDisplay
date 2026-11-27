namespace PetQuota;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args is ["--help"] or ["-h"]) {
            MessageBox.Show("PetQuota.exe [--workspace] [--always-show]\n打开工作台，或同时显示置顶额度窗。", "PetQuota");
            return;
        }
        if (args.Any(arg => arg is not ("--workspace" or "--always-show" or "--smoke-test")))
        { MessageBox.Show("支持的启动选项为 --workspace 和 --always-show。", "PetQuota"); Environment.ExitCode = 64; return; }
        // A smoke run uses only temporary files and never opens real account profiles.
        var smoke = args.Contains("--smoke-test");
        var root = smoke ? Path.Combine(Path.GetTempPath(), "PetQuota-" + Guid.NewGuid().ToString("N"))
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PetQuotaDisplay", "Workspace");
        using var mutex = new Mutex(true, smoke ? null : @"Local\PetQuotaDisplay.Workspace", out var first);
        if (!first) { MessageBox.Show("PetQuota 已运行，请从任务栏或额度窗打开工作台。", "PetQuota"); return; }
        try
        {
            var store = new Workspace(root, new WindowsSecrets());
            if (smoke)
            {
                var sample = store.Add("Smoke", Platform.Codex, Credential.Key, "test-only");
                if (store.Secrets.Reveal(sample.Secret!) != "test-only") throw new InvalidOperationException("DPAPI 校验失败");
                var member = store.AddMember(sample);
                store.SaveInstance("Smoke project", sample.Id, root, member.Id);
            }
            using var window = new Dashboard(store);
            if (smoke) window.Shown += (_, _) => window.BeginInvoke(() => {
                try { window.VerifyViews(); } catch { Environment.ExitCode = 1; } finally { window.Close(); }
            });
            else if (args.Contains("--always-show")) window.Shown += (_, _) => window.ShowOrb();
            Application.Run(window);
        }
        catch (Exception e) {
            if (!smoke) MessageBox.Show(e.Message, "PetQuota", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Environment.ExitCode = 1;
        }
        finally { if (smoke && Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
