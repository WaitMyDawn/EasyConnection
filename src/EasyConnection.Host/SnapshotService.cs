using System.Drawing;
using System.Drawing.Imaging;
using System.Security.Cryptography;
using System.Text;

namespace EasyConnection.Host;

public sealed record ImageCacheUsage(CacheUsage Snapshots, CacheUsage Live);

public sealed record CapturedSnapshot(SnapshotInfo Info, byte[] Image, Rectangle Bounds);

public sealed class SnapshotService : IDisposable
{
    private readonly object sync = new();
    private readonly BoundedCache<CapturedSnapshot> cache = new(32 * 1024 * 1024, 12, TimeSpan.FromMinutes(5), s => s.Image.LongLength);
    private readonly BoundedCache<CapturedSnapshot> liveCache = new(16 * 1024 * 1024, 12, TimeSpan.FromSeconds(10), s => s.Image.LongLength);
    private readonly Func<Rectangle?>? isolatedBounds;
    private readonly System.Threading.Timer expiration;
    private long generation;
    public SnapshotService(Func<Rectangle?>? isolatedBounds = null)
    {
        this.isolatedBounds = isolatedBounds;
        expiration = new System.Threading.Timer(_ => { cache.Prune(); liveCache.Prune(); }, null, TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(15));
    }
    public ImageCacheUsage Usage => new(cache.Usage, liveCache.Usage);
    public ImageCacheUsage Clear()
    {
        lock (sync) { generation++; return new(cache.Clear(), liveCache.Clear()); }
    }
    public void Dispose() => expiration.Dispose();
    public DisplayInfo[] Displays()
    {
        if (isolatedBounds?.Invoke() is { } test) return [new("fixture", "隔离测试窗口", test.X, test.Y, test.Width, test.Height, true)];
        return Screen.AllScreens.Select(s => new DisplayInfo(s.DeviceName, s.DeviceName, s.Bounds.X, s.Bounds.Y, s.Bounds.Width, s.Bounds.Height, s.Primary)).ToArray();
    }
    public string LayoutId() => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join("|", Displays().Select(d => $"{d.Id}:{d.X},{d.Y},{d.Width},{d.Height}")))));

    public CapturedSnapshot Capture(string? displayId = null, int maxWidth = 1600, long quality = 75, bool live = false)
    {
        long epoch;
        lock (sync) epoch = generation;
        var display = FindDisplay(displayId);
        var inputDesktop = NativeMethods.OpenInputDesktop(0, false, 0x0001);
        if (inputDesktop == 0) throw new CommandException("desktop_unavailable", "交互桌面不可访问，请检查登录或锁屏状态。");
        NativeMethods.CloseDesktop(inputDesktop);
        var bounds = new Rectangle(display.X, display.Y, display.Width, display.Height);
        using var source = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format24bppRgb);
        using (var graphics = Graphics.FromImage(source)) graphics.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);
        var scale = Math.Min(1d, (double)Math.Clamp(maxWidth, 320, 2560) / bounds.Width);
        using var image = new Bitmap(source, new Size(Math.Max(1, (int)(source.Width * scale)), Math.Max(1, (int)(source.Height * scale))));
        using var stream = new MemoryStream();
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, Math.Clamp(quality, 30, 90));
        image.Save(stream, ImageCodecInfo.GetImageEncoders().First(e => e.FormatID == ImageFormat.Jpeg.Guid), parameters);
        var info = new SnapshotInfo(Guid.NewGuid().ToString("N"), display.Id, image.Width, image.Height, DateTimeOffset.UtcNow, LayoutId(), CursorAt(bounds));
        var snapshot = new CapturedSnapshot(info, stream.ToArray(), bounds);
        lock (sync)
        {
            if (epoch != generation) throw new CommandException("snapshot_cleared", "截图缓存已清理，请重新获取。");
            (live ? liveCache : cache).Put(info.Id, snapshot);
        }
        return snapshot;
    }

    public CapturedSnapshot Get(string id)
    {
        lock (sync)
            return (cache.TryGet(id, out var snapshot) || liveCache.TryGet(id, out snapshot)) ? snapshot :
                throw new CommandException("snapshot_expired", "截图已过期，请重新获取。");
    }

    public Point ResolvePoint(string id, double x, double y)
    {
        var snapshot = ValidSnapshot(id);
        return new Point(snapshot.Bounds.X + (int)Math.Round(x * (snapshot.Bounds.Width - 1)), snapshot.Bounds.Y + (int)Math.Round(y * (snapshot.Bounds.Height - 1)));
    }
    public CapturedSnapshot ValidSnapshot(string id)
    {
        var snapshot = Get(id);
        if (DateTimeOffset.UtcNow - snapshot.Info.CapturedAt > TimeSpan.FromSeconds(30) || snapshot.Info.LayoutId != LayoutId())
            throw new CommandException("stale_snapshot", "截图已过期或显示器布局改变，请刷新后再操作。");
        return snapshot;
    }
    private DisplayInfo FindDisplay(string? id) => id is null ? Displays().First(d => d.Primary) : Displays().FirstOrDefault(d => d.Id == id)
        ?? throw new CommandException("display_missing", "显示器已移除，请重新选择。");
    public object Cursor(string? displayId)
    {
        var display = FindDisplay(displayId);
        return new { displayId = display.Id, layoutId = LayoutId(), cursor = CursorAt(new Rectangle(display.X, display.Y, display.Width, display.Height)) };
    }
    public static CursorInfo? CursorAt(Rectangle bounds)
    {
        var cursor = NativeMethods.ReadCursor();
        if (cursor is null) return null;
        var point = cursor.Value.Position;
        return new(Math.Clamp((double)(point.X - bounds.X) / Math.Max(1, bounds.Width - 1), 0, 1),
            Math.Clamp((double)(point.Y - bounds.Y) / Math.Max(1, bounds.Height - 1), 0, 1),
            bounds.Contains(point.X, point.Y), (cursor.Value.Flags & 1) != 0);
    }
}
