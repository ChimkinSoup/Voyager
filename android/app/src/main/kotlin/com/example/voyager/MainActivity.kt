package com.example.voyager

import android.content.ClipData
import android.content.ClipboardManager
import android.os.Build
import android.os.PersistableBundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Secure Notes' clipboard (see secure_clipboard.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "voyager/secure_clipboard")
            .setMethodCallHandler { call, result ->
                val clipboard = getSystemService(ClipboardManager::class.java)
                when (call.method) {
                    "copy" -> {
                        val clip = ClipData.newPlainText("", call.arguments as String)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            // ClipDescription.EXTRA_IS_SENSITIVE (API 33); keyboards
                            // read the same key below it.
                            clip.description.extras = PersistableBundle().apply {
                                putBoolean("android.content.extra.IS_SENSITIVE", true)
                            }
                        }
                        clipboard.setPrimaryClip(clip)
                        result.success(null)
                    }
                    "clear" -> {
                        // Needs no focus, unlike reading the clipboard.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            clipboard.clearPrimaryClip()
                        } else {
                            clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // This device's zone, which reminders are scheduled in so they keep
        // their wall-clock time (see reminder_os_notifier.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "voyager/timezone")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "localZone" -> result.success(TimeZone.getDefault().id)
                    else -> result.notImplemented()
                }
            }
        // While the vault is unlocked, its photos and notes stay out of
        // screenshots and the recent-apps thumbnail (see secure_window.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "voyager/secure_window")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "set" -> {
                        if (call.arguments as Boolean) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
