package io.github.jqssun.airplay.mirror

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.graphics.Path
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * 无障碍反向控制服务（无需 root）。
 *
 * 原理与向日葵/TeamViewer 等远控软件一致：
 *  - 点击/滑动：AccessibilityService.dispatchGesture()，API 24+ 系统级注入手势
 *  - 滚屏：对当前窗口根节点 performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD/BACKWARD)
 *  - 文本输入：对焦点可编辑节点 setText（接收端按键消息转换为字符）
 *
 * 坐标约定：接收端消息里的 x/y 是 0-1000 相对值，此处换算为屏幕像素。
 */
class RemoteCtrlService : AccessibilityService() {

    companion object {
        private const val TAG = "RemoteCtrl"

        @Volatile
        private var instance: RemoteCtrlService? = null

        val isConnected: Boolean get() = instance != null
        val canGesture: Boolean get() = instance != null

        fun tap(xPct: Int, yPct: Int) {
            instance?.tapPct(xPct, yPct)
        }

        fun swipe(x1Pct: Int, y1Pct: Int, x2Pct: Int, y2Pct: Int, durMs: Long) {
            instance?.swipePct(x1Pct, y1Pct, x2Pct, y2Pct, durMs)
        }

        fun scroll(dir: Int) {
            instance?.scrollDir(dir)
        }

        fun typeChar(code: Int) {
            instance?.typeKeyChar(code)
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "service connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    private fun tapPct(xPct: Int, yPct: Int) {
        if (instance == null) return
        val (w, h) = screenSize()
        val x = xPct * w / 1000f
        val y = yPct * h / 1000f
        val p = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(p, 0, 50)
        val g = GestureDescription.Builder().addStroke(stroke).build()
        Log.i(TAG, "tap $x,$y")
        dispatchGesture(g, null, mainHandler)
    }

    private fun swipePct(x1Pct: Int, y1Pct: Int, x2Pct: Int, y2Pct: Int, durMs: Long) {
        if (instance == null) return
        val (w, h) = screenSize()
        val x1 = x1Pct * w / 1000f
        val y1 = y1Pct * h / 1000f
        val x2 = x2Pct * w / 1000f
        val y2 = y2Pct * h / 1000f
        val p = Path().apply {
            moveTo(x1, y1)
            lineTo(x2, y2)
        }
        val stroke = GestureDescription.StrokeDescription(p, 0, durMs.coerceIn(60, 1500))
        val g = GestureDescription.Builder().addStroke(stroke).build()
        Log.i(TAG, "swipe $x1,$y1 -> $x2,$y2")
        dispatchGesture(g, null, mainHandler)
    }

    private fun scrollDir(dir: Int) {
        val root = rootInActiveWindow ?: return
        val action = if (dir >= 0) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
        Log.i(TAG, "scroll ${if (dir >= 0) "forward" else "backward"}")
        root.performAction(action)
    }

    /** 按键码 -> 对焦点输入框追加字符；回车=点击确认，退格=删末字符 */
    private fun typeKeyChar(code: Int) {
        val ch = keyCodeToChar(code)
        if (ch == null) {
            // 回车：对焦点节点执行点击
            if (code == 66) {
                val f = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                    ?: rootInActiveWindow
                f?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            }
            return
        }
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: rootInActiveWindow
        val editable = node ?: findEditable(node)
        if (editable == null) {
            Log.i(TAG, "no editable node for char '$ch'")
            return
        }
        if (code == 67) {
            // 退格：去掉最后一个字符
            val cur = editable.text?.toString() ?: ""
            if (cur.isNotEmpty()) {
                val args = Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, cur.dropLast(1))
                }
                editable.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            }
            return
        }
        val cur = editable.text?.toString() ?: ""
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, cur + ch)
        }
        Log.i(TAG, "type '$ch' into editable")
        editable.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    private fun keyCodeToChar(code: Int): Char? {
        return when (code) {
            in 7..16 -> '0' + (code - 7)
            in 29..54 -> 'A' + (code - 29)
            62 -> ' '
            else -> null
        }
    }

    private fun findEditable(n: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        if (n == null) return null
        if (n.isEditable) return n
        for (i in 0 until n.childCount) {
            val c = n.getChild(i) ?: continue
            val r = findEditable(c)
            if (r != null) return r
        }
        return null
    }

    private fun screenSize(): Pair<Int, Int> {
        // 必须用真实屏幕尺寸（含系统栏），dispatchGesture 使用屏幕坐标系；
        // resources.displayMetrics 返回内容区域，底部导航栏会让 y 坐标整体偏移
        val wm = getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
        val dm = android.util.DisplayMetrics()
        wm.defaultDisplay.getRealMetrics(dm)
        return dm.widthPixels to dm.heightPixels
    }
}

