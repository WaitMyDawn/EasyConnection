using System.Drawing;
using System.Net;
using System.Net.NetworkInformation;

namespace EasyConnection.Host;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Contains("--self-test")) { Environment.ExitCode = HostSelfTest.Run(); return; }
        var dataDirectory = Option(args, "--data-dir") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "EasyConnection");
        var port = int.TryParse(Option(args, "--port"), out var parsed) ? parsed : 23456;
        if (port is < 1 or > 65535) { MessageBox.Show("端口必须在 1–65535 之间。", "EasyConnection"); return; }
        try
        {
            using var security = new SecurityStore(Path.Combine(dataDirectory, "credentials"));
            var catalog = new Catalog(dataDirectory);
            using var snapshots = new SnapshotService();
            var runtime = new DesktopRuntime(catalog, snapshots);
            using var tasks = new TaskEngine(runtime, Path.Combine(dataDirectory, "tasks"));
            var server = new ApiServer(security, catalog, runtime, snapshots, tasks, port, args.Contains("--loopback"));
            server.StartAsync().GetAwaiter().GetResult();
            try { Application.Run(new HostForm(security, catalog, snapshots, tasks, dataDirectory, port, args.Contains("--minimized"), args.Contains("--loopback"))); }
            finally { server.DisposeAsync().AsTask().GetAwaiter().GetResult(); tasks.StopAsync().GetAwaiter().GetResult(); }
        }
        catch (Exception)
        {
            MessageBox.Show("启动失败。请检查端口占用、数据目录权限和系统运行环境。", "EasyConnection", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Environment.ExitCode = 1;
        }
    }
    private static string? Option(string[] args, string name)
    {
        var index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }
}
