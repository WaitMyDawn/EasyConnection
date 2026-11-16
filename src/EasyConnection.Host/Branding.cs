using System.Drawing;
using System.Reflection;

namespace EasyConnection.Host;

internal static class Branding
{
    public static Icon LoadIcon()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("EasyConnection.Icon")
            ?? throw new InvalidOperationException("Application icon resource missing.");
        using var icon = new Icon(stream);
        return (Icon)icon.Clone();
    }
    public static string LicenseText(string resource)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource)
            ?? throw new InvalidOperationException("License resource missing.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}
