namespace PetQuota;

internal sealed class Editor : Form
{
    readonly TableLayoutPanel grid = new() { Dock = DockStyle.Top, AutoSize = true, Padding = new(16), ColumnCount = 2 };
    readonly Button confirm = new() { Text = "保存", AutoSize = true };
    public Editor(string title)
    {
        Text = title; StartPosition = FormStartPosition.CenterParent; FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false; AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
        grid.ColumnStyles.Add(new(SizeType.Absolute, 92)); grid.ColumnStyles.Add(new(SizeType.Absolute, 370));
        Controls.Add(grid);
    }
    void Row(string label, Control control)
    {
        int row = grid.RowCount++;
        grid.RowStyles.Add(new(SizeType.AutoSize));
        grid.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left }, 0, row);
        control.Anchor = AnchorStyles.Left | AnchorStyles.Right; control.Margin = new(4, 6, 4, 6);
        grid.Controls.Add(control, 1, row);
    }
    TextBox TextRow(string label, bool secret = false)
    { var box = new TextBox { UseSystemPasswordChar = secret }; Row(label, box); return box; }
    ComboBox Choices(string label, params object[] options)
    {
        var box = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList };
        box.Items.AddRange(options); if (options.Length > 0) box.SelectedIndex = 0;
        Row(label, box); return box;
    }
    TextBox PathRow(string label, bool folder)
    {
        var line = new TableLayoutPanel { AutoSize = true, ColumnCount = 2 };
        line.ColumnStyles.Add(new(SizeType.Percent, 100)); line.ColumnStyles.Add(new(SizeType.AutoSize));
        var path = new TextBox { Dock = DockStyle.Fill };
        var browse = new Button { Text = "浏览…", AutoSize = true };
        browse.Click += (_, _) => {
            if (folder) { using var d = new FolderBrowserDialog(); if (d.ShowDialog(this) == DialogResult.OK) path.Text = d.SelectedPath; }
            else { using var d = new OpenFileDialog { Filter = "登录 JSON|*.json|所有文件|*.*" }; if (d.ShowDialog(this) == DialogResult.OK) path.Text = d.FileName; }
        };
        line.Controls.Add(path, 0, 0); line.Controls.Add(browse, 1, 0); Row(label, line); return path;
    }
    bool Submit(IWin32Window parent, Action save)
    {
        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.RightToLeft };
        var cancel = new Button { Text = "取消", DialogResult = DialogResult.Cancel };
        buttons.Controls.Add(confirm); buttons.Controls.Add(cancel); Row("", buttons);
        AcceptButton = confirm; CancelButton = cancel;
        confirm.Click += (_, _) => {
            try { save(); DialogResult = DialogResult.OK; }
            catch (Exception e) { MessageBox.Show(this, e.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        };
        return ShowDialog(parent) == DialogResult.OK;
    }

    public static bool AddAccount(IWin32Window parent, Workspace store)
    {
        using var d = new Editor("添加账号");
        var platform = d.Choices("平台", Enum.GetValues<Platform>().Cast<object>().ToArray());
        var name = d.TextRow("账号名称");
        var type = d.Choices("凭据类型", "登录 JSON", "API Key");
        var path = d.PathRow("登录文件", false);
        var secret = d.TextRow("密钥或令牌", true);
        var region = d.Choices("账号区域", "国际", "中国大陆");
        var project = d.TextRow("Cloud 项目 ID");
        void Sync()
        {
            bool login = type.SelectedIndex == 0;
            path.Parent!.Enabled = login; secret.Enabled = !login;
            region.Enabled = (Platform)platform.SelectedItem! == Platform.CodeBuddy;
            project.Enabled = (Platform)platform.SelectedItem! == Platform.Gemini && login;
        }
        platform.SelectedIndexChanged += (_, _) => {
            if ((Platform)platform.SelectedItem! == Platform.CodeBuddy && type.Items.Count == 2) type.Items.Add("访问令牌");
            else if ((Platform)platform.SelectedItem! != Platform.CodeBuddy && type.Items.Count == 3) {
                if (type.SelectedIndex == 2) type.SelectedIndex = 0;
                type.Items.RemoveAt(2);
            }
            Sync();
        };
        type.SelectedIndexChanged += (_, _) => Sync(); Sync();
        return d.Submit(parent, () => store.Add(name.Text, (Platform)platform.SelectedItem!,
            type.SelectedIndex switch { 0 => Credential.Login, 1 => Credential.Key, _ => Credential.Token },
            type.SelectedIndex == 0 ? path.Text : secret.Text, region.SelectedIndex == 1, project.Text));
    }

    public static bool EditInstance(IWin32Window parent, Workspace store, Instance? template = null, bool copy = false)
    {
        if (store.State.Accounts.Length == 0) throw new InvalidOperationException("请先添加账号。");
        using var d = new Editor(template == null || copy ? "新建客户端实例" : "编辑客户端实例");
        var name = d.TextRow("实例名称");
        var account = d.Choices("绑定账号", store.State.Accounts.Cast<object>().ToArray());
        account.SelectedItem = store.State.Accounts.FirstOrDefault(a => a.Id == template?.AccountId)
            ?? store.Current(store.State.OrbPlatform) ?? store.State.Accounts[0];
        var path = d.PathRow("项目目录", true);
        var gateway = d.Choices("Codex 网关", ["直接连接", ..store.State.Members.Cast<object>()]);
        if (template != null) {
            name.Text = (copy ? "副本 · " : "") + template.Name; path.Text = template.Project;
            if (store.State.Members.FirstOrDefault(m => m.Id == template.GatewayId) is Member m) gateway.SelectedItem = m;
        }
        void Sync() { gateway.Enabled = ((Account)account.SelectedItem!).Platform == Platform.Codex; if (!gateway.Enabled) gateway.SelectedIndex = 0; }
        account.SelectedIndexChanged += (_, _) => Sync(); Sync();
        return d.Submit(parent, () => store.SaveInstance(name.Text, ((Account)account.SelectedItem!).Id, path.Text,
            (gateway.SelectedItem as Member)?.Id, copy ? null : template?.Id));
    }
    public static bool AddMember(IWin32Window parent, Workspace store)
    {
        var available = store.State.Accounts.Where(a => a.Platform == Platform.Codex && a.Kind == Credential.Key &&
            !store.State.Members.Any(m => m.AccountId == a.Id)).ToArray();
        if (available.Length == 0) throw new InvalidOperationException("请在账号页添加尚未入池的 Codex API Key 账号。");
        using var d = new Editor("添加网关成员");
        var account = d.Choices("API Key 账号", available.Cast<object>().ToArray());
        return d.Submit(parent, () => store.AddMember((Account)account.SelectedItem!));
    }
}
