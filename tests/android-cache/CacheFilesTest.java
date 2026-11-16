package dev.easyconnection.easy_connection;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;

public final class CacheFilesTest {
    public static void main(String[] args) throws Exception {
        Path fixture = Files.createTempDirectory(Path.of(args[0]), "cache-fixture-").toRealPath();
        File root = Files.createDirectory(fixture.resolve("cache")).toFile().getCanonicalFile();
        Path nested = Files.createDirectory(root.toPath().resolve("nested"));
        Files.write(root.toPath().resolve("first"), new byte[2]);
        Files.write(nested.resolve("second"), new byte[3]);
        File persistent = Files.write(fixture.resolve("persistent-fixture"), new byte[7]).toFile();
        CacheFiles.Usage usage = CacheFiles.measure(root, root);
        require(usage.bytes == 5 && usage.entries == 2, "Usage must count nested cached files");
        require(!CacheFiles.removeChild(root, root), "Cache root itself must be preserved");
        require(!CacheFiles.removeChild(persistent, root) && persistent.exists(), "Files outside the cache root must be preserved");
        Path link = root.toPath().resolve("outside-link");
        try {
            Files.createSymbolicLink(link, persistent.toPath());
            require(CacheFiles.measure(link.toFile(), root).bytes == 0 && !CacheFiles.removeChild(link.toFile(), root), "Links must not escape the cache boundary");
            Files.delete(link);
        } catch (java.nio.file.FileSystemException error) {
            System.out.println("SKIP: symbolic links unavailable on this Windows configuration");
        }
        for (File child : root.listFiles()) require(CacheFiles.removeChild(child, root), "Cache child must be removable");
        require(CacheFiles.measure(root, root).bytes == 0 && persistent.exists(), "Cleanup must empty cache and preserve persistent data");
        System.out.println("PASS: Android cache measurement, nested cleanup, root protection and persistent-data boundary");
    }
    private static void require(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
