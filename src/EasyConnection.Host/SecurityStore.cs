using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;

namespace EasyConnection.Host;

public sealed record TrustedDevice(string Id, string Name, string TokenHash, DateTimeOffset PairedAt);
public sealed record PairRequest(string Code, string DeviceName);
public sealed record PairResponse(string DeviceId, string Token, string HostName, int ProtocolVersion);

public sealed class SecurityStore : IDisposable
{
    private readonly string devicePath;
    private readonly object sync = new();
    private readonly List<TrustedDevice> devices;
    private string pairingCode = "";
    private int failedAttempts;
    public DateTimeOffset PairingExpiresAt { get; private set; }
    public X509Certificate2 Certificate { get; }
    public string Fingerprint => Certificate.GetCertHashString(HashAlgorithmName.SHA256).ToLowerInvariant();

    public SecurityStore(string directory)
    {
        Directory.CreateDirectory(directory);
        devicePath = Path.Combine(directory, "devices.json");
        devices = File.Exists(devicePath) ? JsonSerializer.Deserialize<List<TrustedDevice>>(File.ReadAllText(devicePath), Protocol.Json) ?? [] : [];
        var certPath = Path.Combine(directory, "server-certificate.bin");
        if (File.Exists(certPath))
        {
            var bytes = ProtectedData.Unprotect(File.ReadAllBytes(certPath), null, DataProtectionScope.CurrentUser);
            Certificate = X509CertificateLoader.LoadPkcs12(bytes, null, X509KeyStorageFlags.DefaultKeySet);
            CryptographicOperations.ZeroMemory(bytes);
        }
        else
        {
            using var key = RSA.Create(3072);
            var request = new CertificateRequest("CN=EasyConnection", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
            var names = new SubjectAlternativeNameBuilder();
            names.AddDnsName("localhost");
            names.AddIpAddress(System.Net.IPAddress.Loopback);
            names.AddIpAddress(System.Net.IPAddress.IPv6Loopback);
            request.CertificateExtensions.Add(names.Build());
            using var generated = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddYears(3));
            var bytes = generated.Export(X509ContentType.Pfx);
            // Schannel needs a key container when using the certificate for server authentication.
            Certificate = X509CertificateLoader.LoadPkcs12(bytes, null, X509KeyStorageFlags.DefaultKeySet);
            File.WriteAllBytes(certPath, ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser));
            CryptographicOperations.ZeroMemory(bytes);
        }
        RefreshPairingCode();
    }

    public string GetPairingCode() { lock (sync) return pairingCode; }
    public bool IsPairingActive { get { lock (sync) return pairingCode.Length > 0 && failedAttempts < 5 && DateTimeOffset.UtcNow < PairingExpiresAt; } }
    public void RefreshPairingCode()
    {
        lock (sync)
        {
            pairingCode = RandomNumberGenerator.GetInt32(10_000_000, 100_000_000).ToString();
            PairingExpiresAt = DateTimeOffset.UtcNow.AddMinutes(5);
            failedAttempts = 0;
        }
    }

    public PairResponse Pair(PairRequest request)
    {
        lock (sync)
        {
            if (!IsPairingActive) throw new CommandException("pairing_closed", "连接信息已使用或过期，请在电脑端重新复制。");
            if (request.DeviceName.Length is < 1 or > 64) throw new CommandException("invalid_device", "设备名称长度无效。");
            if (!CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(pairingCode), Encoding.UTF8.GetBytes(request.Code)))
            {
                failedAttempts++;
                throw new CommandException("pairing_denied", "连接信息无效，请在电脑端重新复制完整信息。");
            }
            var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
            var device = new TrustedDevice(Guid.NewGuid().ToString("N"), request.DeviceName, Hash(token), DateTimeOffset.UtcNow);
            devices.Add(device);
            Persist();
            pairingCode = "";
            return new PairResponse(device.Id, token, Environment.MachineName, Protocol.Version);
        }
    }

    public TrustedDevice? Authenticate(string token)
    {
        if (token.Length != 64) return null;
        var hash = Encoding.ASCII.GetBytes(Hash(token));
        lock (sync) return devices.FirstOrDefault(d => CryptographicOperations.FixedTimeEquals(hash, Encoding.ASCII.GetBytes(d.TokenHash)));
    }

    public TrustedDevice[] ListDevices() { lock (sync) return devices.ToArray(); }
    public void Revoke(string id)
    {
        lock (sync) { devices.RemoveAll(d => d.Id == id); Persist(); }
    }
    private void Persist()
    {
        File.WriteAllText(devicePath + ".tmp", JsonSerializer.Serialize(devices, Protocol.Json));
        File.Move(devicePath + ".tmp", devicePath, true);
    }
    private static string Hash(string token) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
    public void Dispose() => Certificate.Dispose();
}
