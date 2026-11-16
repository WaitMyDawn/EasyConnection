namespace EasyConnection.Core;

public sealed record CacheUsage(int Entries, long Bytes, long LimitBytes);

public sealed class BoundedCache<T>(long maximumBytes, int maximumEntries, TimeSpan lifetime, Func<T, long> size, TimeProvider? clock = null)
{
    private readonly Dictionary<string, (T Value, DateTimeOffset Created, long Bytes)> entries = [];
    private readonly TimeProvider time = clock ?? TimeProvider.System;
    private long bytes;
    private readonly object sync = new();
    public void Put(string key, T value)
    {
        lock (sync)
        {
            Prune();
            var weight = size(value);
            if (weight < 0 || weight > maximumBytes) throw new CommandException("cache_item_too_large", "截图超过缓存容量，请降低分辨率。");
            Remove(key);
            while (entries.Count >= maximumEntries || bytes + weight > maximumBytes) Remove(entries.MinBy(e => e.Value.Created).Key);
            entries.Add(key, (value, time.GetUtcNow(), weight));
            bytes += weight;
        }
    }
    public bool TryGet(string key, out T value)
    {
        lock (sync)
        {
            Prune();
            if (entries.TryGetValue(key, out var entry)) { value = entry.Value; return true; }
            value = default!;
            return false;
        }
    }
    public CacheUsage Usage { get { lock (sync) { Prune(); return new(entries.Count, bytes, maximumBytes); } } }
    public CacheUsage Clear()
    {
        lock (sync) { var previous = new CacheUsage(entries.Count, bytes, maximumBytes); entries.Clear(); bytes = 0; return previous; }
    }
    public void Prune()
    {
        lock (sync)
            foreach (var key in entries.Where(e => time.GetUtcNow() - e.Value.Created >= lifetime).Select(e => e.Key).ToArray()) Remove(key);
    }
    private void Remove(string key) { if (entries.Remove(key, out var item)) bytes -= item.Bytes; }
}

public static class PointerGeometry
{
    public static (int X, int Y) Move(int x, int y, int dx, int dy, int left, int top, int width, int height)
    {
        if (width < 1 || height < 1) throw new CommandException("invalid_display", "显示器尺寸无效。");
        if (x < left || y < top || x >= (long)left + width || y >= (long)top + height)
            throw new CommandException("cursor_outside", "鼠标位于其他显示器，请先点按当前画面定位。");
        return ((int)Math.Clamp((long)x + dx, left, (long)left + width - 1), (int)Math.Clamp((long)y + dy, top, (long)top + height - 1));
    }
}
