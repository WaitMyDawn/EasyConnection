package dev.easyconnection.easy_connection

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val cacheWorker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.easyconnection/cache")
            .setMethodCallHandler { call, result ->
                if (call.method != "inspect" && call.method != "clear") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                cacheWorker.execute {
                    try {
                        val roots = listOfNotNull(cacheDir, *externalCacheDirs).map { it.canonicalFile }.distinct()
                        var skipped = 0
                        if (call.method == "clear") {
                            roots.forEach { root -> root.listFiles()?.forEach { if (!CacheFiles.removeChild(it, root)) skipped++ } }
                        }
                        val rows = (roots.map { it to true } + (codeCacheDir.canonicalFile to false)).map { (root, clearable) ->
                            val usage = CacheFiles.measure(root, root)
                            mapOf("name" to (if (root == codeCacheDir.canonicalFile) "Android 运行代码缓存" else if (root == cacheDir.canonicalFile) "应用临时文件" else "外部临时文件"),
                                "location" to root.absolutePath, "bytes" to usage.bytes, "entries" to usage.entries, "clearable" to clearable)
                        }
                        runOnUiThread { result.success(mapOf("items" to rows, "skipped" to skipped)) }
                    } catch (_: Exception) {
                        runOnUiThread { result.error("cache_unavailable", "无法访问应用缓存目录", null) }
                    }
                }
            }
    }

    override fun onDestroy() {
        cacheWorker.shutdown()
        super.onDestroy()
    }
}
