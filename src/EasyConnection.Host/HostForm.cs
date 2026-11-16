using System.Diagnostics;
using System.Drawing;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;

namespace EasyConnection.Host;

internal sealed class HostForm : Form
{
    private readonly NotifyIcon tray;
    private readonly Icon applicationIcon = Branding.LoadIcon();
    private readonly System.Windows.Forms.Timer timer;
    private readonly ToolTip tips = new();
    private readonly Label pairingState = new() { AutoSize = true, ForeColor = Color.SeaGreen };
    private readonly ListBox devices = new() { Dock = DockStyle.Fill, DisplayMember = "Name" };
    private readonly TextBox fallback = new() { Dock = DockStyle.Top, PlaceholderText = "https://公网地址或隧道域名:端口（可选）" };
    private readonly ListBox addresses = new() { Dock = DockStyle.Top, Height = 100 };
    private readonly Label diagnostics = new() { AutoSize = true, MaximumSize = new Size(660, 0) };

    public HostForm(SecurityStore security, Catalog catalog, SnapshotService snapshots, TaskEngine tasks, string dataDirectory, int port, bool minimized, bool loopbackOnly)
    {
        Text = "EasyConnection · 电脑端";
        Icon = applicationIcon;
        ClientSize = new Size(760, 690);
        MinimumSize = new Size(650, 600);
        Font = new Font("Microsoft YaHei UI", 10);
        BackColor = Color.FromArgb(246, 248, 252);
        fallback.Text = ConnectionPreferences.Load(dataDirectory).Fallback;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24), ColumnCount = 1, RowCount = 9 };
        for (var index = 0; index < 9; index++) layout.RowStyles.Add(new RowStyle(index == 6 ? SizeType.Percent : SizeType.AutoSize, index == 6 ? 100 : 0));
        Controls.Add(layout);
        layout.Controls.Add(new Label { Text = "EasyConnection", Font = new Font(Font.FontFamily, 23, FontStyle.Bold), AutoSize = true });
        layout.Controls.Add(new Label { Text = "电脑复制连接信息 → 手机粘贴并连接", AutoSize = true, Margin = new Padding(0, 12, 0, 16) });
        var copy = new Button { Text = "复制手机连接信息", AutoSize = true, Height = 48, Dock = DockStyle.Top, BackColor = Color.FromArgb(221, 234, 255) };
        tips.SetToolTip(copy, "自动包含可用地址、证书身份和临时配对码；手机无需逐项输入。");
        copy.Click += (_, _) =>
        {
            try
            {
                new ConnectionPreferences(fallback.Text).Save(dataDirectory);
                var candidates = ReadAddresses();
                var endpoints = PairingInvitation.RankAddresses(candidates);
                security.RefreshPairingCode();
                var invitation = new PairingInvitation(2, Environment.MachineName, endpoints, fallback.Text.Trim(), security.Fingerprint,
                    security.GetPairingCode(), security.PairingExpiresAt) { CandidateCount = candidates.Length };
                Clipboard.SetText(invitation.Encode());
                pairingState.Text = $"已复制。请在 5 分钟内到手机粘贴；自动尝试 {endpoints.Length} 个电脑地址。";
            }
            catch (CommandException error) { pairingState.Text = error.Message; }
            catch (Exception) { pairingState.Text = "复制失败，请检查连接设置或剪贴板是否被其他程序占用。"; }
        };
        layout.Controls.Add(copy);
        layout.Controls.Add(pairingState);
        var advancedToggle = new CheckBox { Text = "高级设置与连接排查", AutoSize = true, Margin = new Padding(0, 16, 0, 8) };
        layout.Controls.Add(advancedToggle);
        var advanced = new Panel { Visible = false, Dock = DockStyle.Top, Height = 240, AutoScroll = true };
        var advancedBody = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 1 };
        advanced.Controls.Add(advancedBody);
        advancedBody.Controls.Add(new Label { Text = "外网备用地址（电脑端填一次，自动带到手机）", AutoSize = true });
        advancedBody.Controls.Add(fallback);
        advancedBody.Controls.Add(new Label { Text = "本机候选地址（排序不代表手机一定可达）", AutoSize = true, Margin = new Padding(0, 8, 0, 0) });
        advancedBody.Controls.Add(addresses);
        var checks = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top };
        var check = new Button { Text = "检查本机连接", AutoSize = true };
        check.Click += async (_, _) =>
        {
            check.Enabled = false;
            diagnostics.Text = "正在检查本机监听和 TLS，直接连接，不使用系统代理…";
            try
            {
                var available = ReadAddresses();
                using var handler = new HttpClientHandler { UseProxy = false, ServerCertificateCustomValidationCallback = (_, certificate, _, _) =>
                    certificate?.GetCertHashString(HashAlgorithmName.SHA256).Equals(security.Fingerprint, StringComparison.OrdinalIgnoreCase) == true };
                using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(3) };
                var response = await client.GetAsync($"https://127.0.0.1:{port}/health");
                response.EnsureSuccessStatusCode();
                diagnostics.Text = $"本机服务和 TLS 正常，找到 {available.Length} 个地址。若手机连接超时，请检查防火墙是否允许此程序，以及校园网是否限制设备互访。跨网络需可达公网地址或 TCP 隧道。";
            }
            catch (Exception) { diagnostics.Text = "本机服务检查失败，请确认监听端口没有被占用，并重新启动电脑端。"; }
            finally { check.Enabled = true; }
        };
        var allow = new Button { Text = "允许网络访问", AutoSize = true };
        tips.SetToolTip(allow, "为此程序的监听端口添加 Windows 防火墙入站规则，需要管理员授权；不修改代理设置。");
        allow.Click += async (_, _) =>
        {
            allow.Enabled = false;
            try
            {
                var executable = Environment.ProcessPath!;
                if (Path.GetFileNameWithoutExtension(executable) != System.Reflection.Assembly.GetEntryAssembly()!.GetName().Name)
                    throw new CommandException("apphost_required", "请使用发布后的 EXE 配置防火墙，不能为共享运行时添加此规则。");
                var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "netsh.exe")) { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden };
                foreach (var argument in new[] { "advfirewall", "firewall", "add", "rule", $"name=EasyConnection TCP {port}", "dir=in", "action=allow", $"program={executable}", "protocol=TCP", $"localport={port}", "profile=any" }) start.ArgumentList.Add(argument);
                using var process = Process.Start(start)!;
                await process.WaitForExitAsync();
                diagnostics.Text = process.ExitCode == 0 ? "已添加此程序的防火墙规则。请重新复制信息到手机连接；校园网设备隔离仍可能需要公网地址或隧道。" : "防火墙规则未添加，请检查管理员权限。";
            }
            catch (CommandException error) { diagnostics.Text = error.Message; }
            catch (Exception) { diagnostics.Text = "未更改防火墙规则，可能取消了管理员授权。"; }
            finally { allow.Enabled = true; }
        };
        var clear = new Button { Text = "电脑缓存与清理", AutoSize = true };
        clear.Click += (_, _) =>
        {
            using var dialog = new CacheForm(snapshots, tasks);
            dialog.ShowDialog(this);
        };
        checks.Controls.AddRange([check, allow, clear]);
        advancedBody.Controls.Add(checks);
        advancedBody.Controls.Add(diagnostics);
        layout.Controls.Add(advanced);
        layout.Controls.Add(devices);
        var management = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top };
        var revoke = new Button { Text = "撤销选中手机", AutoSize = true };
        revoke.Click += (_, _) => { if (devices.SelectedItem is TrustedDevice device) { security.Revoke(device.Id); UpdateDevices(); } };
        var register = new Button { Text = "注册可启动应用", AutoSize = true };
        register.Click += (_, _) =>
        {
            using var dialog = new OpenFileDialog { Filter = "应用程序 (*.exe)|*.exe", CheckFileExists = true };
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            catalog.RegisterApp(new(Guid.NewGuid().ToString("N"), Path.GetFileNameWithoutExtension(dialog.FileName), dialog.FileName, []));
            MessageBox.Show("应用已注册，可在手机流程编辑器中选择。");
        };
        var licenses = new Button { Text = "开源许可证", AutoSize = true };
        licenses.Click += (_, _) => { using var dialog = new LicenseForm(); dialog.ShowDialog(this); };
        management.Controls.AddRange([revoke, register, licenses]);
        layout.Controls.Add(management);
        layout.Controls.Add(new Label { Text = $"已授权手机显示在上方。隧道本地目标：127.0.0.1:{port}。关闭窗口后在托盘继续运行。", AutoSize = true, MaximumSize = new Size(690, 0) });
        advancedToggle.CheckedChanged += (_, _) => { advanced.Visible = advancedToggle.Checked; if (advanced.Visible) ReadAddresses(); };
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开设置", null, (_, _) => { Show(); WindowState = FormWindowState.Normal; Activate(); });
        menu.Items.Add("退出", null, (_, _) => Application.Exit());
        tray = new NotifyIcon { Text = "EasyConnection · 运行中", Icon = applicationIcon, Visible = true, ContextMenuStrip = menu };
        tray.DoubleClick += (_, _) => { Show(); WindowState = FormWindowState.Normal; Activate(); };
        Resize += (_, _) => { if (WindowState == FormWindowState.Minimized) Hide(); };
        FormClosing += (_, args) => { if (args.CloseReason == CloseReason.UserClosing) { args.Cancel = true; Hide(); } };
        timer = new System.Windows.Forms.Timer { Interval = 2000 };
        timer.Tick += (_, _) => UpdateDevices();
        timer.Start();
        Shown += (_, _) => { if (minimized) Hide(); };
        pairingState.Text = "手机只需粘贴一段连接信息。系统代理无需关闭。";
        UpdateDevices();

        ConnectionAddress[] ReadAddresses()
        {
            var found = loopbackOnly ? [] : ConnectionAddresses.Discover(port);
            addresses.Items.Clear();
            foreach (var endpoint in PairingInvitation.RankAddresses(found))
            {
                var candidate = found.First(a => a.Endpoint == endpoint);
                addresses.Items.Add($"{candidate.InterfaceName} · {endpoint}{(candidate.HasGateway ? " · 有网关" : "")}");
            }
            return found;
        }
        void UpdateDevices()
        {
            var current = security.ListDevices();
            if (!devices.Items.Cast<TrustedDevice>().Select(d => d.Id).SequenceEqual(current.Select(d => d.Id)))
            { devices.Items.Clear(); devices.Items.AddRange(current); }
        }
    }
    protected override void Dispose(bool disposing) { if (disposing) { timer.Dispose(); tray.Dispose(); tips.Dispose(); applicationIcon.Dispose(); } base.Dispose(disposing); }
}
