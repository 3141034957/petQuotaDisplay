namespace PetQuota;

internal sealed class Dashboard : Form
{
    readonly Workspace store;
    readonly Gateway gateway;
    readonly CancellationTokenSource closing = new();
    readonly HashSet<Guid> loading = [];
    readonly Dictionary<Guid, (List<Quota> Rows, DateTimeOffset At)> readings = [];
    readonly Dictionary<Guid, string> errors = [];
    readonly Panel content = new() { Dock = DockStyle.Fill, Padding = new(18, 12, 18, 16) };
    readonly Label title = new() { AutoSize = true, Font = new("Microsoft YaHei UI", 17, FontStyle.Bold) };
    readonly FlowLayoutPanel toolbar = new() { Dock = DockStyle.Top, AutoSize = true, WrapContents = true };
    readonly Label status = new() { Dock = DockStyle.Bottom, Height = 28, Padding = new(10, 2, 6, 2) };
    readonly Label serverState = new() { AutoSize = true, ForeColor = Color.LightCyan, Margin = new(12, 24, 0, 0) };
    readonly Dictionary<string, Button> nav = [];
    readonly System.Windows.Forms.Timer timer = new() { Interval = 1000 };
    readonly NumericUpDown port = new() { Minimum = 1024, Maximum = 65535, Width = 76 };
    readonly CheckBox failures = new() { Text = "只看异常", AutoSize = true };
    readonly TextBox search = new() { PlaceholderText = "搜索成员、模型或路径", Width = 180 };
    readonly ListView accounts = Table("平台:95", "账号:160", "状态:90", "额度:350");
    readonly ListView instances = Table("实例:150", "平台:95", "账号:150", "项目目录:280", "网关:120");
    readonly ListView members = Table("成员:220", "上游:230");
    readonly ListView requests = Table("时间:85", "成员:120", "模型:130", "路径:150", "HTTP:80", "耗时:85");
    readonly ListView overview = Table("平台:95", "当前账号:150", "最低剩余 / 余额:145", "额度周期:145", "最近采集:100");
    readonly Label details = new() { Dock = DockStyle.Bottom, Height = 58, AutoEllipsis = true, Padding = new(4) };
    Orb? orb;
    string page = "";
    DateTimeOffset nextRefresh = DateTimeOffset.Now.AddMinutes(5);
    RequestRecord? newest;
    bool stopping, busy;

    public Dashboard(Workspace workspace)
    {
        store = workspace; gateway = new(store); port.Value = Math.Clamp(store.State.Port, 1024, 65535);
        Text = "PetQuota 工作台"; BackColor = Color.FromArgb(245, 247, 248); Size = new(1080, 710); MinimumSize = new(800, 530);
        StartPosition = FormStartPosition.CenterScreen;
        var rail = new FlowLayoutPanel { Dock = DockStyle.Left, Width = 156, FlowDirection = FlowDirection.TopDown, WrapContents = false,
            Padding = new(8, 18, 6, 8), BackColor = Color.FromArgb(24, 52, 57) };
        rail.Controls.Add(new Label { Text = "PetQuota", ForeColor = Color.White, AutoSize = true, Font = new("Segoe UI", 20, FontStyle.Bold), Margin = new(9, 0, 2, 24) });
        foreach (var item in new[] { "工作台总览", "账号与额度", "客户端实例", "API 网关" })
        {
            var b = new Button { Text = item, Width = 133, Height = 37, FlatStyle = FlatStyle.Flat, ForeColor = Color.White, TextAlign = ContentAlignment.MiddleLeft };
            b.FlatAppearance.BorderSize = 0; b.Click += (_, _) => Navigate(item); nav[item] = b; rail.Controls.Add(b);
        }
        rail.Controls.Add(serverState);
        var layout = new Panel { Dock = DockStyle.Fill };
        var head = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 54, Padding = new(16, 8, 0, 0) }; head.Controls.Add(title);
        layout.Controls.Add(content); layout.Controls.Add(head); layout.Controls.Add(status); Controls.Add(layout); Controls.Add(rail);
        accounts.SelectedIndexChanged += (_, _) => AccountDetail();
        overview.DoubleClick += (_, _) => Navigate("账号与额度");
        instances.DoubleClick += (_, _) => Guard(Launch);
        failures.CheckedChanged += (_, _) => Logs(); search.TextChanged += (_, _) => Logs();
        timer.Tick += (_, _) => {
            var latest = gateway.Records.FirstOrDefault();
            if (latest != newest) { newest = latest; if (page == "API 网关") Logs(); }
            if (gateway.LogError != null) status.Text = gateway.LogError;
            if (DateTimeOffset.Now >= nextRefresh) { nextRefresh = DateTimeOffset.Now.AddMinutes(5); _ = RefreshSelected(); }
        };
        Shown += (_, _) => { timer.Start(); _ = RefreshSelected(); };
        Navigate("工作台总览");
    }
    static ListView Table(params string[] columns)
    {
        var view = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true,
            MultiSelect = false, HideSelection = false, BorderStyle = BorderStyle.FixedSingle };
        foreach (var spec in columns) { var pair = spec.Split(':'); view.Columns.Add(pair[0], int.Parse(pair[1])); }
        return view;
    }
    static void Fill(ListView table, IEnumerable<(object Id, string[] Cells)> rows)
    {
        var selected = table.SelectedItems.Count == 0 ? null : table.SelectedItems[0].Tag;
        table.BeginUpdate(); table.Items.Clear();
        foreach (var (id, cells) in rows) { var item = new ListViewItem(cells) { Tag = id }; table.Items.Add(item); if (Equals(id, selected)) item.Selected = true; }
        table.EndUpdate();
    }
    static Guid Selected(ListView view) => view.SelectedItems.Count != 0 && view.SelectedItems[0].Tag is Guid id ? id : throw new InvalidOperationException("请先选中一行。");
    void Guard(Action action) { try { action(); } catch (Exception e) { status.Text = e.Message; } }
    void ActionButton(string label, Action action)
    {
        var button = new Button { Text = label, AutoSize = true }; button.Click += (_, _) => Guard(action); toolbar.Controls.Add(button);
    }
    Control? body;
    void Navigate(string target)
    {
        if (body != null) { content.Controls.Remove(body); if (body is SplitContainer split) { split.Panel1.Controls.Clear(); split.Panel2.Controls.Clear(); split.Dispose(); } }
        content.Controls.Remove(details);
        foreach (Control c in toolbar.Controls.Cast<Control>().ToArray()) {
            toolbar.Controls.Remove(c); if (c != port && c != search && c != failures) c.Dispose();
        }
        page = title.Text = target;
        foreach (var pair in nav) pair.Value.BackColor = pair.Key == page ? Color.FromArgb(47, 92, 96) : Color.FromArgb(24, 52, 57);
        switch (page)
        {
            case "工作台总览":
                body = overview; ActionButton("刷新当前账号", () => _ = RefreshSelected()); ActionButton("置顶额度窗", ShowOrb); break;
            case "账号与额度":
                body = accounts; content.Controls.Add(details);
                ActionButton("添加账号…", () => { if (Editor.AddAccount(this, store)) Draw(); });
                ActionButton("切换至此账号", () => { store.Select(store.State.Accounts.Single(a => a.Id == Selected(accounts))); Draw(); });
                ActionButton("刷新额度", () => _ = RefreshAccount(store.State.Accounts.Single(a => a.Id == Selected(accounts))));
                ActionButton("移除账号", () => {
                    var a = store.State.Accounts.Single(a => a.Id == Selected(accounts));
                    if (loading.Contains(a.Id)) throw new InvalidOperationException("请等当前刷新完成。");
                    if (Confirm($"移除 {a.Name} 及其 PetQuota 登录目录？")) {
                        store.RemoveAccount(a); readings.Remove(a.Id); errors.Remove(a.Id); Draw();
                    }
                });
                ActionButton("置顶额度窗", ShowOrb); break;
            case "客户端实例":
                body = instances; ActionButton("新建实例…", () => { if (Editor.EditInstance(this, store)) Draw(); });
                ActionButton("打开终端", Launch);
                ActionButton("编辑…", () => { if (Editor.EditInstance(this, store, store.State.Instances.Single(i => i.Id == Selected(instances)))) Draw(); });
                ActionButton("复制…", () => { if (Editor.EditInstance(this, store, store.State.Instances.Single(i => i.Id == Selected(instances)), true)) Draw(); });
                ActionButton("移除实例", () => { var id = Selected(instances); if (Confirm("移除这个实例的启动配置？")) { store.Save(store.State with { Instances = store.State.Instances.Where(i => i.Id != id).ToArray() }); Draw(); } }); break;
            default:
                var split = new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, Height = 390, SplitterDistance = 108 };
                split.Panel1.Controls.Add(members); split.Panel2.Controls.Add(requests); body = split;
                ActionButton("添加成员…", () => { if (Editor.AddMember(this, store)) Draw(); });
                ActionButton("复制本机 Key", () => Clipboard.SetText(store.Secrets.Reveal(store.State.Members.Single(m => m.Id == Selected(members)).LocalSecret)));
                ActionButton("移除成员", () => {
                    var id = Selected(members);
                    if (store.State.Instances.Any(i => i.GatewayId == id)) throw new InvalidOperationException("请先移除绑定此成员的实例。");
                    if (Confirm("撤销该成员的本机 Key？")) { store.Save(store.State with { Members = store.State.Members.Where(m => m.Id != id).ToArray() }); Draw(); }
                });
                toolbar.Controls.Add(new Label { Text = "端口", AutoSize = true, Margin = new(5, 8, 2, 0) }); toolbar.Controls.Add(port);
                ActionButton(gateway.Running ? "停止网关" : "启动网关", () => _ = ToggleGateway());
                if (gateway.Running) ActionButton("复制地址", () => Clipboard.SetText(gateway.Address + "/v1"));
                toolbar.Controls.Add(search); toolbar.Controls.Add(failures); break;
        }
        content.Controls.Add(body); body.SendToBack(); content.Controls.Add(toolbar); toolbar.BringToFront(); Draw();
    }

    bool Confirm(string message) => MessageBox.Show(this, message, Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;
    void Launch() { Clients.Launch(store, store.State.Instances.Single(i => i.Id == Selected(instances)), gateway.Running); status.Text = "已启动客户端。"; }
    async Task ToggleGateway()
    {
        if (busy || stopping) return; busy = true;
        try
        {
            if (gateway.Running) await gateway.StopAsync();
            else { await gateway.StartAsync((int)port.Value);
                try { store.Save(store.State with { Port = (int)port.Value }); } catch { await gateway.StopAsync(); throw; } }
            status.Text = gateway.Running ? gateway.Address + "/v1" : "网关已停止";
        }
        catch (Exception e) { if (!stopping) status.Text = e.Message; }
        finally { busy = false; if (!stopping) Navigate(page); }
    }
    void Logs()
    {
        var q = search.Text.Trim();
        var rows = gateway.Records.Where(r => (!failures.Checked || r.Status >= 400 || r.Interrupted) &&
            $"{r.Member} {r.Model} {r.Path} {r.Status}".Contains(q, StringComparison.OrdinalIgnoreCase));
        Fill(requests, rows.Select(r => ((object)r.Time, new[] { r.Time.ToLocalTime().ToString("T"), r.Member, r.Model ?? "—", r.Path,
            r.Status + (r.Interrupted ? " 中断" : ""), r.Milliseconds + " ms" })));
    }
    string Amount(Quota? q) => q?.Percent is int p ? $"{p}%" : q?.Detail ?? "—";
    string Summary(Account a) => loading.Contains(a.Id) ? "正在刷新…" : errors.TryGetValue(a.Id, out var error) ? error :
        readings.TryGetValue(a.Id, out var snapshot) ? string.Join("   ", snapshot.Rows.Select(q => q.Label + " " + Amount(q))) :
        a.Kind == Credential.Key ? "API Key · 平台控制台用量" : "尚未刷新";
    Quota? Lowest(Account? account) => account != null && readings.TryGetValue(account.Id, out var snapshot)
        ? snapshot.Rows.OrderBy(q => q.Percent ?? int.MaxValue).FirstOrDefault() : null;
    void Draw()
    {
        port.Enabled = !gateway.Running; serverState.Text = gateway.Running ? "● 网关运行中" : "○ 网关已停止";
        if (page == "工作台总览")
            Fill(overview, Enum.GetValues<Platform>().Select(p => {
                var a = store.Current(p); var q = Lowest(a);
                return ((object)p, new[] { p.ToString(), a?.Name ?? "未配置", Amount(q), a == null ? "—" : q?.Label ?? Summary(a),
                    a != null && readings.TryGetValue(a.Id, out var snap) ? (errors.ContainsKey(a.Id) ? "上次 " : "") + snap.At.ToString("t") : "—" });
            }));
        if (page == "账号与额度") {
            Fill(accounts, store.State.Accounts.Select(a => ((object)a.Id, new[] { a.Platform.ToString(), a.Name,
                store.Current(a.Platform)?.Id == a.Id ? "当前选择" : "", Summary(a) }))); AccountDetail(); }
        if (page == "客户端实例")
            Fill(instances, store.State.Instances.Select(i => {
                var a = store.State.Accounts.First(x => x.Id == i.AccountId);
                return ((object)i.Id, new[] { i.Name, a.Platform.ToString(), a.Name, i.Project,
                    store.State.Members.FirstOrDefault(m => m.Id == i.GatewayId)?.Name ?? "直连" }); }));
        if (page == "API 网关") {
            Fill(members, store.State.Members.Select(m => ((object)m.Id, new[] { m.Name, "OpenAI API" }))); Logs(); }
        UpdateOrb();
    }
    void AccountDetail()
    {
        if (accounts.SelectedItems.Count == 0) { details.Text = ""; return; }
        var a = store.State.Accounts.FirstOrDefault(x => x.Id == Selected(accounts));
        if (a == null) { details.Text = ""; return; }
        details.Text = Summary(a);
        if (readings.TryGetValue(a.Id, out var snap))
            details.Text += Environment.NewLine + "上次成功 " + snap.At.ToString("g") + "   " + string.Join("   ", snap.Rows.Where(q => q.Reset != null)
                .Select(q => $"{q.Label} 重置 {q.Reset!.Value.ToLocalTime():g}"));
    }
    async Task RefreshAccount(Account a)
    {
        if (stopping || !loading.Add(a.Id)) return; Draw();
        try { var rows = await Quotas.ReadAsync(store, a, closing.Token); readings[a.Id] = (rows, DateTimeOffset.Now); errors.Remove(a.Id); }
        catch (Exception e) {
            if (e is UnauthorizedAccessException or HttpRequestException { StatusCode: System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden })
                readings.Remove(a.Id);
            errors[a.Id] = e is OperationCanceledException ? "额度查询已超时或取消。" : e.Message;
        }
        finally { loading.Remove(a.Id); if (!stopping) Draw(); }
    }
    Task RefreshSelected() => Task.WhenAll(Enum.GetValues<Platform>().Select(store.Current).OfType<Account>()
        .Where(a => a.Kind != Credential.Key).Select(RefreshAccount));

    public void ShowOrb()
    {
        if (orb is null || orb.IsDisposed) {
            orb = new Orb(() => { Show(); WindowState = FormWindowState.Normal; Activate(); }, () => {
                if (store.Current(store.State.OrbPlatform) is Account a) _ = RefreshAccount(a); });
            orb.Show(); }
        UpdateOrb(); orb.Activate();
    }
    void UpdateOrb()
    {
        if (orb is null || orb.IsDisposed) return;
        var a = store.Current(store.State.OrbPlatform); var q = Lowest(a);
        orb.UpdateReading(a?.Platform.ToString() ?? "PetQuota", Amount(q), a == null ? "尚无账号" :
            loading.Contains(a.Id) ? "刷新中" : errors.ContainsKey(a.Id) ? "读取失败" : q?.Label ?? (a.Kind == Credential.Key ? "API Key" : "点击刷新"));
    }
    protected override async void OnFormClosing(FormClosingEventArgs e)
    {
        if (stopping) { e.Cancel = !shutdownComplete; base.OnFormClosing(e); return; }
        e.Cancel = true; stopping = true; Enabled = false; timer.Stop(); closing.Cancel(); orb?.Close(); base.OnFormClosing(e);
        try { while (busy) await Task.Delay(25); await gateway.DisposeAsync(); }
        finally { shutdownComplete = true; BeginInvoke(Close); }
    }
    bool shutdownComplete;
    internal void VerifyViews()
    {
        foreach (var pageName in nav.Keys) { Navigate(pageName); PerformLayout(); }
        ShowOrb();
    }
    protected override void Dispose(bool disposing)
    { if (disposing) { timer.Dispose(); closing.Dispose(); foreach (var item in new Control[] { accounts, instances, members, requests, overview, details, port, failures, search }) item.Dispose(); } base.Dispose(disposing); }
}

internal sealed class Orb : Form
{
    readonly Label platform = new(), number = new(), period = new();
    public Orb(Action open, Action refresh)
    {
        Text = "PetQuota 额度"; FormBorderStyle = FormBorderStyle.FixedToolWindow; TopMost = true;
        StartPosition = FormStartPosition.Manual; ClientSize = new(142, 98);
        var area = Screen.PrimaryScreen!.WorkingArea;
        Location = new Point(area.Right - Width - 18, area.Bottom - Height - 18);
        BackColor = Color.FromArgb(22, 55, 60); ForeColor = Color.White;
        var menu = new ContextMenuStrip(); menu.Items.Add("打开工作台", null, (_, _) => open());
        menu.Items.Add("刷新额度", null, (_, _) => refresh()); menu.Items.Add("关闭额度窗", null, (_, _) => Close());
        ContextMenuStrip = menu;
        foreach (var label in new[] { period, number, platform })
        { label.Dock = DockStyle.Top; label.Height = label == number ? 42 : 24; label.TextAlign = ContentAlignment.MiddleCenter;
          label.Click += (_, _) => refresh(); Controls.Add(label); }
        number.Font = new Font("Segoe UI", 22, FontStyle.Bold); number.ForeColor = Color.Aquamarine;
    }
    public void UpdateReading(string source, string amount, string window) { platform.Text = source; number.Text = amount; period.Text = window; }
}
