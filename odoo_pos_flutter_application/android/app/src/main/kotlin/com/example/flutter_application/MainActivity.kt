package com.example.OdoCart

import android.os.Build
import android.os.Bundle
import android.view.MotionEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        hardenWindow()
    }

    override fun onResume() {
        super.onResume()
        hardenWindow()
    }

    private fun hardenWindow() {
        // Prevent screenshots, screen recording and recent-apps preview leakage.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )

        // Android 12+: hide non-system overlay windows while this app is visible.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                window.setHideOverlayWindows(true)
            } catch (_: SecurityException) {
                // Keep FLAG_SECURE + obscured touch rejection if overlay hiding is unavailable.
            }
        }

        // Drop touches if another window is obscuring this app's view.
        window.decorView.filterTouchesWhenObscured = true
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        val obscured = (event.flags and MotionEvent.FLAG_WINDOW_IS_OBSCURED) != 0
        val partiallyObscured = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            (event.flags and MotionEvent.FLAG_WINDOW_IS_PARTIALLY_OBSCURED) != 0

        if (obscured || partiallyObscured) {
            return false
        }

        return super.dispatchTouchEvent(event)
    }
}
