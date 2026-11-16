using System.Drawing;

namespace EasyConnection.Host;

internal sealed class CacheForm : Form
{
    public CacheForm(SnapshotService snapshots, TaskEngine tasks)
    {
        Text = "电脑缓存";
        ClientSize = new Size(780, 320);
        MinimumSize = new Size(680, 320);
        Font = new Font("Microsoft YaHei UI", 10);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(16), RowCount = 4, ColumnCount = 1 };
        layout.RowStyles.Add(new(SizeType.AutoSize));
        layout.RowStyles.Add(new(SizeType.Percent, 100));
        layout.RowStyles.Add(new(SizeType.AutoSize));
        layout.RowStyles.Add(new(SizeType.AutoSize));
        Controls.Add(layout);
        layout.Controls.Add(new Label { Text = "仅查看和清理这台电脑的缓存。大小为缓存 JPEG 数据的实际字节数。", AutoSize = true });
        var grid = new DataGridView { Dock = DockStyle.Fill, ReadOnly = true, AllowUserToAddRows = false, AllowUserToDeleteRows = false, RowHeadersVisible = false, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill };
        foreach (var name in new[] { "类型", "数量", "大小", "上限", "位置" }) grid.Columns.Add(name, name);
        grid.Columns[4].FillWeight = 180;
        layout.Controls.Add(grid);
        var message = new Label { AutoSize = true, MaximumSize = new Size(740, 0), Padding = new Padding(0, 8, 0, 8) };
        layout.Controls.Add(message);
        var buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
        var refresh = new Button { Text = "刷新用量", AutoSize = true };
        var clear = new Button { Text = "清理电脑截图缓存", AutoSize = true };
        buttons.Controls.AddRange([refresh, clear]);
        layout.Controls.Add(buttons);
        refresh.Click += (_, _) => UpdateUsage();
        clear.Click += (_, _) =>
        {
            try
            {
                var released = tasks.ClearImageCache(snapshots.Clear);
                UpdateUsage();
                message.Text = $"已释放 {FormatBytes(released.Snapshots.Bytes + released.Live.Bytes)}。配对、预置流程和任务记录已保留。";
            }
            catch (CommandException error) { message.Text = error.Message; }
        };
        UpdateUsage();
        void UpdateUsage()
        {
            var usage = snapshots.Usage;
            grid.Rows.Clear();
            Add("单张截图", usage.Snapshots);
            Add("实时画面", usage.Live);
            message.Text = "位置为本进程内存，没有截图文件夹。过期缓存自动释放；正在实时控制时会继续产生新帧。";
        }
        void Add(string name, CacheUsage usage) => grid.Rows.Add(name, usage.Entries, FormatBytes(usage.Bytes), FormatBytes(usage.LimitBytes), "电脑进程内存（不写入磁盘）");
    }
    private static string FormatBytes(long bytes) => bytes < 1024 ? $"{bytes} B" : bytes < 1024 * 1024 ? $"{bytes / 1024d:F1} KiB" : $"{bytes / (1024d * 1024):F2} MiB";
}
