package com.example.pomodoro_app

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Build
import android.view.Display
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onResume() {
        super.onResume()
        requestHighestRefreshRate()
    }

    /**
     * 高刷请求(原生层,与 Dart 层的 refresh_rate 包双层保障):
     * Android 默认可能只给应用 60Hz。把窗口的 preferredDisplayModeId /
     * preferredRefreshRate 设为设备支持的最高模式(同分辨率下最高刷新率),
     * 系统才会把 vsync 拉到 120Hz;最终速率仍由系统决定(省电/发热/无动画
     * 时 LTPO 会降频,这是正常机制,不是应用能强制锁死的)。
     */
    private fun requestHighestRefreshRate() {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
            val dm = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
            val display = dm.getDisplay(Display.DEFAULT_DISPLAY) ?: return
            val best = display.supportedModes.maxByOrNull { it.refreshRate } ?: return
            val attrs = window.attributes
            attrs.preferredDisplayModeId = best.modeId
            attrs.preferredRefreshRate = best.refreshRate
            window.attributes = attrs
        } catch (_: Exception) {
            // 无最高模式或系统拒绝时静默回退,不影响正常启动。
        }
    }
}
