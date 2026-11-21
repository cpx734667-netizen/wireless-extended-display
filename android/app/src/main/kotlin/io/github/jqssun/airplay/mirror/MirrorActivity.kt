package io.github.jqssun.airplay.mirror

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import io.github.jqssun.airplay.R
import java.net.Inet4Address
import java.net.NetworkInterface
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * 独立的「扩展屏接收」界面。
 *
 * 设计成经典 View，避免和上游 Compose 主题/导航耦合；从主页的
 * 「扩展屏」按钮进入。SurfaceView 直接作为硬解输出，触摸事件
 * 经 MirrorReceiver 回传给 Mac/Windows 发送端。
 */
class MirrorActivity : Activity() {

    private lateinit var receiver: MirrorReceiver
    private lateinit var surfaceView: SurfaceView
    private lateinit var statusView: TextView
    private lateinit var infoView: TextView
    private lateinit var toggleButton: Button
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private var downX = 0f
    private var downY = 0f
    private var dragging = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        receiver = MirrorReceiver(this)
        buildUi()

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                receiver.setSurface(holder.surface)
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                receiver.setSurface(holder.surface)
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                // Activity 退出时统一 release；这里不主动停会话，避免旋转时闪断。
            }
        })

        scope.launch {
            receiver.state.collect { render(it) }
        }
        receiver.start()
    }

    override fun onDestroy() {
        scope.cancel()
        receiver.release()
        super.onDestroy()
    }

    private fun buildUi() {
        val density = resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            setPadding(dp(16), dp(12), dp(16), dp(12))
        }

        val title = TextView(this).apply {
            text = getString(R.string.mirror_title)
            setTextColor(Color.WHITE)
            textSize = 20f
            gravity = Gravity.START
        }
        root.addView(title, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ))

        statusView = TextView(this).apply {
            text = getString(R.string.mirror_listening, MirrorReceiver.PORT)
            setTextColor(Color.parseColor("#8AB4F8"))
            textSize = 14f
            setPadding(0, dp(6), 0, 0)
        }
        root.addView(statusView)

        infoView = TextView(this).apply {
            text = getString(R.string.mirror_hint, localIp() ?: "—", MirrorReceiver.PORT)
            setTextColor(Color.parseColor("#9AA0A6"))
            textSize = 12f
            setPadding(0, dp(4), 0, dp(8))
        }
        root.addView(infoView)

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.START
        }
        toggleButton = Button(this).apply {
            text = getString(R.string.mirror_stop)
            setOnClickListener {
                if (receiver.state.value.running) {
                    receiver.stop()
                } else {
                    receiver.start()
                }
            }
        }
        actions.addView(toggleButton, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ))

        val a11y = Button(this).apply {
            text = getString(R.string.mirror_a11y)
            setOnClickListener {
                startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            }
        }
        val a11yParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { leftMargin = dp(8) }
        actions.addView(a11y, a11yParams)
        root.addView(actions)

        surfaceView = SurfaceView(this).apply {
            setOnTouchListener { _, event ->
                handleTouch(event)
                true
            }
        }
        root.addView(surfaceView, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f
        ))

        val hint = TextView(this).apply {
            text = getString(R.string.mirror_control_hint)
            setTextColor(Color.parseColor("#6F7680"))
            textSize = 11f
            setPadding(0, dp(6), 0, 0)
        }
        root.addView(hint)

        setContentView(root)
    }

    private fun render(state: MirrorReceiver.State) {
        statusView.text = when {
            state.error.isNotEmpty() -> state.error
            state.connected -> getString(R.string.mirror_connected, state.width, state.height, state.fps)
            state.running -> getString(R.string.mirror_listening, MirrorReceiver.PORT)
            else -> getString(R.string.mirror_stopped)
        }
        toggleButton.text = getString(if (state.running) R.string.mirror_stop else R.string.mirror_start)
        infoView.text = getString(R.string.mirror_hint, localIp() ?: "—", MirrorReceiver.PORT)
    }

    private fun handleTouch(event: android.view.MotionEvent) {
        val w = surfaceView.width.coerceAtLeast(1)
        val h = surfaceView.height.coerceAtLeast(1)
        val x = (event.x * 1000 / w).toInt().coerceIn(0, 1000)
        val y = (event.y * 1000 / h).toInt().coerceIn(0, 1000)
        when (event.actionMasked) {
            android.view.MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                dragging = false
                receiver.sendMouse(1, x, y, 0)
            }

            android.view.MotionEvent.ACTION_MOVE -> {
                val dx = event.x - downX
                val dy = event.y - downY
                if (!dragging && dx * dx + dy * dy > 64f) dragging = true
                if (dragging) receiver.sendMouse(0, x, y, 0)
            }

            android.view.MotionEvent.ACTION_UP, android.view.MotionEvent.ACTION_CANCEL -> {
                receiver.sendMouse(2, x, y, 0)
                dragging = false
            }
        }
    }

    private fun localIp(): String? {
        return try {
            NetworkInterface.getNetworkInterfaces().toList()
                .asSequence()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList().asSequence() }
                .filterIsInstance<Inet4Address>()
                .firstOrNull()
                ?.hostAddress
        } catch (_: Exception) {
            null
        }
    }
}
