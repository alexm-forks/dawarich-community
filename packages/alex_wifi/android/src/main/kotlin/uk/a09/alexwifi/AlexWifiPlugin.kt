package uk.a09.alexwifi

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** alex-hack: the Wi-Fi access points the phone can see (see lib/alex_wifi.dart). */
class AlexWifiPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var context: Context? = null
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "uk.a09.alexwifi").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "scan" -> scan(result)
            else -> result.notImplemented()
        }
    }

    /**
     * Asks for a fresh scan and answers with the results once it's done (or
     * after [SCAN_TIMEOUT_MS]). Android throttles scans (4 per 2 minutes in
     * the foreground); when the request is refused, the latest results any
     * app or the system collected are returned, with their age, so the caller
     * can drop stale ones.
     */
    private fun scan(result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.error("UNAVAILABLE", "Not attached", null)
            return
        }
        val wifi = ctx.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifi == null) {
            result.error("UNAVAILABLE", "No Wi-Fi", null)
            return
        }

        var answered = false
        var receiver: BroadcastReceiver? = null
        lateinit var timeout: Runnable

        fun answer() {
            if (answered) return
            answered = true
            mainHandler.removeCallbacks(timeout)
            receiver?.let { r -> runCatching { ctx.unregisterReceiver(r) } }
            try {
                result.success(read(wifi))
            } catch (e: SecurityException) {
                result.error("PERMISSION", e.message, null)
            }
        }

        timeout = Runnable { answer() }
        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                mainHandler.post { answer() }
            }
        }

        // A system broadcast, so no exported flag is needed.
        ctx.registerReceiver(receiver, IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION))
        @Suppress("DEPRECATION")
        val started = try {
            wifi.startScan()
        } catch (e: SecurityException) {
            false
        }
        if (started) {
            mainHandler.postDelayed(timeout, SCAN_TIMEOUT_MS)
        } else {
            answer()
        }
    }

    @Suppress("DEPRECATION")
    private fun read(wifi: WifiManager): List<Map<String, Any?>> {
        val now = SystemClock.elapsedRealtime()
        return wifi.scanResults.orEmpty().mapNotNull { r ->
            val bssid = r.BSSID ?: return@mapNotNull null
            mapOf(
                "bssid" to bssid,
                "ssid" to (r.SSID ?: ""),
                "level" to r.level,
                "frequency" to r.frequency,
                // ScanResult.timestamp is microseconds since boot.
                "ageMs" to (now - r.timestamp / 1000).coerceAtLeast(0),
            )
        }
    }

    private companion object {
        const val SCAN_TIMEOUT_MS = 10_000L
    }
}
