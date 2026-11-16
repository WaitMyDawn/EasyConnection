using System.Net;
using System.Text;
using System.Text.Json;

namespace EasyConnection.Core;

public sealed record ConnectionAddress(string Endpoint, string InterfaceName, bool HasGateway, bool IsLanTransport, bool IsIPv6);

public sealed record PairingInvitation(int Version, string HostName, string[] Endpoints, string Fallback,
    string Fingerprint, string Code, DateTimeOffset ExpiresAt)
{
    public const string Prefix = "EC2:";
    public int CandidateCount { get; init; }
    public static string[] RankAddresses(IEnumerable<ConnectionAddress> addresses) => addresses
        .OrderByDescending(a => a.HasGateway)
        .ThenByDescending(a => a.IsLanTransport)
        .ThenBy(a => a.IsIPv6)
        .ThenBy(a => a.Endpoint, StringComparer.Ordinal)
        .Select(a => NormalizeEndpoint(a.Endpoint)).Distinct(StringComparer.Ordinal).Take(16).ToArray();

    public static string NormalizeEndpoint(string endpoint)
    {
        if (!Uri.TryCreate(endpoint.Trim(), UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
            string.IsNullOrEmpty(uri.Host) || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0 || uri.AbsolutePath != "/")
            throw new CommandException("invalid_endpoint", "请输入 HTTPS 主机地址与端口，不包含路径、账号或查询参数。");
        return uri.GetLeftPart(UriPartial.Authority);
    }

    public string Encode()
    {
        if (Version != 2 || Endpoints.Length > 16 || (Endpoints.Length == 0 && string.IsNullOrEmpty(Fallback)))
            throw new CommandException("missing_endpoint", "尚无可用网络地址，请连接网络或填写外网备用地址。");
        var normalized = this with { Endpoints = Endpoints.Select(NormalizeEndpoint).Distinct().ToArray(), Fallback = string.IsNullOrWhiteSpace(Fallback) ? "" : NormalizeEndpoint(Fallback), CandidateCount = Math.Max(CandidateCount, Endpoints.Length) };
        return Prefix + Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(normalized, Protocol.Json)))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }
}
