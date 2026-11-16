using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json;

namespace EasyConnection.Host;

internal static class ConnectionAddresses
{
    public static ConnectionAddress[] Discover(int port)
    {
        var addresses = new List<ConnectionAddress>();
        foreach (var network in NetworkInterface.GetAllNetworkInterfaces().Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback))
        {
            try
            {
                var properties = network.GetIPProperties();
                var gateway = properties.GatewayAddresses.Any(g => !g.Address.Equals(IPAddress.Any) && !g.Address.Equals(IPAddress.IPv6Any));
                foreach (var unicast in properties.UnicastAddresses)
                {
                    var address = unicast.Address;
                    if (IPAddress.IsLoopback(address) || address.IsIPv6LinkLocal || address.IsIPv6Multicast || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any)) continue;
                    addresses.Add(new(new UriBuilder("https", address.ToString(), port).Uri.GetLeftPart(UriPartial.Authority), network.Name, gateway,
                        network.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.Wireless80211,
                        address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6));
                }
            }
            catch (NetworkInformationException) { }
        }
        return addresses.ToArray();
    }
}

internal sealed record ConnectionPreferences(string Fallback = "")
{
    public static ConnectionPreferences Load(string directory)
    {
        var path = Path.Combine(directory, "connection.json");
        return File.Exists(path) ? JsonSerializer.Deserialize<ConnectionPreferences>(File.ReadAllText(path), Protocol.Json) ?? new() : new();
    }
    public void Save(string directory)
    {
        var normalized = this with { Fallback = string.IsNullOrWhiteSpace(Fallback) ? "" : PairingInvitation.NormalizeEndpoint(Fallback) };
        var path = Path.Combine(directory, "connection.json");
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(normalized, Protocol.Json));
        File.Move(path + ".tmp", path, true);
    }
}
