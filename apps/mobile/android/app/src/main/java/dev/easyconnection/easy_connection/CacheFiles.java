package dev.easyconnection.easy_connection;

import java.io.File;
import java.io.IOException;

final class CacheFiles {
    static final class Usage {
        final long bytes;
        final int entries;
        Usage(long bytes, int entries) { this.bytes = bytes; this.entries = entries; }
    }

    private static boolean contained(File file, File root) throws IOException {
        File canonical = file.getCanonicalFile();
        // Parent aliases are resolved once at the boundary; individual cache entries must never follow links.
        return file.getAbsoluteFile().equals(canonical) &&
            (canonical.equals(root) || canonical.getPath().startsWith(root.getPath() + File.separator));
    }

    static Usage measure(File file, File root) throws IOException {
        if (!contained(file, root)) return new Usage(0, 0);
        if (file.isFile()) return new Usage(file.length(), 1);
        long bytes = 0;
        int entries = 0;
        File[] children = file.listFiles();
        if (children == null && file.isDirectory()) throw new IOException("Cache directory cannot be enumerated");
        if (children != null) for (File child : children) {
            Usage usage = measure(child, root);
            bytes += usage.bytes;
            entries += usage.entries;
        }
        return new Usage(bytes, entries);
    }

    static boolean removeChild(File file, File root) throws IOException {
        if (!contained(file, root) || file.getCanonicalFile().equals(root)) return false;
        boolean removed = true;
        File[] children = file.listFiles();
        if (children != null) for (File child : children) if (!removeChild(child, root)) removed = false;
        return file.delete() && removed;
    }
}
