package uk.a09.alexpower

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** alex-hack: whether a charger is connected (see lib/alex_power.dart). */
class AlexPowerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var context: Context? = null
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "uk.a09.alexpower").also {
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
            "isPluggedIn" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("UNAVAILABLE", "Not attached", null)
                    return
                }
                // The battery broadcast is sticky: registering a null receiver
                // just returns the latest one.
                val battery: Intent? =
                    ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                if (battery == null) {
                    result.error("UNAVAILABLE", "No battery broadcast", null)
                    return
                }
                result.success(battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0)
            }
            else -> result.notImplemented()
        }
    }
}
