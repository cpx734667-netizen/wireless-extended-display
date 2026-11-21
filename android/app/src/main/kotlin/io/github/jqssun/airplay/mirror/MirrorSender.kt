package io.github.jqssun.airplay.mirror

import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.io.DataInputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import kotlin.concurrent.thread

/**
 * 整屏镜像发射端：MediaProjection 录屏 + MediaCodec H.264 编码，
 * 按自有协议推给「无线扩展屏」接收端（MirrorReceiver，TCP 9000）。
 */
class MirrorSender(private val ctx: Context) {

    data class State(
        val running: Boolean = false,
        val connected: Boolean = false,
        val target: String = "",
        val width: Int = 0,
        val height: Int = 0,
        val error: String = ""
    )

    val state = kotlinx.coroutines.flow.MutableStateFlow(State())

    /** 会话报错回调（错误状态在 finally 中会被立即清空，必须靠回调可靠通知） */
    var onError: ((String) -> Unit)? = null

    /** 会话结束回调（正常结束或出错都会触发；MediaProjection 实例只能创建一次 VirtualDisplay，结束后必须重新授权） */
    var onFinished: (() -> Unit)? = null

    private var mediaProjection: android.media.projection.MediaProjection? = null
    private var codec: MediaCodec? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var codecThread: HandlerThread? = null
    private var socket: Socket? = null
    private var out: OutputStream? = null
    private var running = false
    private val writeLock = Object()

    fun setProjection(projection: android.media.projection.MediaProjection?) {
        mediaProjection = projection
    }

    fun start(targetIp: String, port: Int = MirrorReceiver.PORT) {
        if (running) return
        val projection = mediaProjection
        if (projection == null) {
            state.value = State(error = "尚未获得录屏授权，请先点「允许录屏」")
            return
        }
        running = true
        state.value = State(running = true, connected = false, target = "$targetIp:$port")
        thread(name = "mirror-sender", isDaemon = true) { runSession(projection, targetIp, port) }
    }

    fun stop() {
        running = false
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        out = null
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
        try { virtualDisplay?.release() } catch (_: Exception) {}
        virtualDisplay = null
        codecThread?.quitSafely()
        codecThread = null
        state.value = State()
    }

    fun release() {
        stop()
        try { mediaProjection?.stop() } catch (_: Exception) {}
        mediaProjection = null
    }

    private fun runSession(projection: android.media.projection.MediaProjection, targetIp: String, port: Int) {
        var socket: Socket? = null
        try {
            // 1) TCP connect
            socket = Socket()
            socket!!.tcpNoDelay = true
            socket!!.soTimeout = 15_000
            socket!!.connect(InetSocketAddress(targetIp, port), 8_000)
            this.socket = socket
            out = socket!!.getOutputStream()
            state.value = state.value.copy(connected = true)

            // 2) screen size
            val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
            val dm = android.util.DisplayMetrics()
            wm.defaultDisplay.getRealMetrics(dm)
            val w = dm.widthPixels
            val h = dm.heightPixels
            val dpi = dm.densityDpi
            val fps = 30

            // 3) handshake
            val hs = ByteBuffer.allocate(16).apply {
                put("WXESMIRROR".toByteArray(Charsets.US_ASCII))
                put(1.toByte())
                putShort(w.toShort())
                putShort(h.toShort())
                put(fps.toByte())
            }
            synchronized(writeLock) { out!!.write(hs.array()) }

            // 4) encoder
            codecThread = HandlerThread("mirror-encoder").also { it.start() }
            val handler = Handler(codecThread!!.looper)
            val bitrate = (w * h * 8).coerceIn(4_000_000, 40_000_000)
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                if (android.os.Build.VERSION.SDK_INT >= 23) {
                    setInteger(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 10_000)
                }
            }
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            enc.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(c: MediaCodec, index: Int) {}
                override fun onOutputBufferAvailable(c: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    try {
                        val buf = c.getOutputBuffer(index) ?: return
                        val cfg = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                        if (info.size > 0 && !cfg) {
                            val data = ByteArray(info.size)
                            buf.position(info.offset)
                            buf.get(data)
                            sendFrame(TYPE_FRAME, data)
                        } else if (info.size > 0 && cfg) {
                            val data = ByteArray(info.size)
                            buf.position(info.offset)
                            buf.get(data)
                            sendFrame(TYPE_CONFIG, data)
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "output error", e)
                    } finally {
                        // stop()/release() 后 codec 可能已停止，回调线程仍有 pending 输出：
                        // releaseOutputBuffer 直接抛 IllegalStateException（真机实测崩溃），必须保护
                        try { c.releaseOutputBuffer(index, false) } catch (_: Exception) {}
                    }
                }

                override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
                    Log.e(TAG, "codec error", e)
                    stop()
                }

                override fun onOutputFormatChanged(c: MediaCodec, format: MediaFormat) {}
            }, handler)
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val inputSurface = enc.createInputSurface()
            codec = enc
            enc.start()

            // 5) virtual display (Android 14+ requires a registered callback before capture)
            projection.registerCallback(object : android.media.projection.MediaProjection.Callback() {}, handler)
            virtualDisplay = projection.createVirtualDisplay(
                "wuxian-mirror", w, h, dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                inputSurface, null, handler
            )
            state.value = state.value.copy(running = true, connected = true, width = w, height = h)
            Log.i(TAG, "mirroring $w x $h @$fps to $targetIp bitrate=${bitrate / 1000}kbps")

            // 6) 控制接收：接收端发来的鼠标/键盘消息 -> 无障碍服务执行（无需 root）
            thread(name = "mirror-control-in", isDaemon = true) {
                try {
                    val din = DataInputStream(socket!!.getInputStream())
                    while (running) {
                        val len = din.readInt()
                        if (len <= 0 || len > 1 shl 20) break
                        val type = din.readByte().toInt()
                        if (type == TYPE_MOUSE && len >= 7) {
                            val p = ByteArray(len)
                            din.readFully(p)
                            val action = p[0].toInt()
                            val x = ((p[1].toInt() and 0xFF) shl 8) or (p[2].toInt() and 0xFF)
                            val y = ((p[3].toInt() and 0xFF) shl 8) or (p[4].toInt() and 0xFF)
                            val wheel = (((p[5].toInt() shl 8) or (p[6].toInt() and 0xFF)).toShort()).toInt()
                            handleControlMouse(action, x, y, wheel)
                        } else if (type == TYPE_KEY && len >= 5) {
                            val p = ByteArray(len)
                            din.readFully(p)
                            val action = p[0].toInt()
                            val code = ((p[1].toInt() and 0xFF) shl 24) or ((p[2].toInt() and 0xFF) shl 16) or
                                ((p[3].toInt() and 0xFF) shl 8) or (p[4].toInt() and 0xFF)
                            handleControlKey(action, code)
                        } else if (len > 0) {
                            val skip = ByteArray(len)
                            din.readFully(skip)
                        }
                    }
                } catch (e: Exception) {
                    Log.i(TAG, "control channel closed: ${e.message ?: e.javaClass.simpleName}")
                }
            }

            // 7) keep alive until stop; heartbeat every 5s
            while (running) {
                Thread.sleep(5_000)
                if (running) sendFrame(TYPE_HEARTBEAT, ByteArray(0))
            }
        } catch (e: Exception) {
            if (running) {
                val msg = "发送失败: ${e.message ?: e.javaClass.simpleName}"
                state.value = state.value.copy(error = msg)
                Log.e(TAG, "sender session failed", e)
                onError?.invoke(msg)
            }
        } finally {
            try { virtualDisplay?.release() } catch (_: Exception) {}
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            codec = null
            virtualDisplay = null
            codecThread?.quitSafely()
            codecThread = null
            try { socket?.close() } catch (_: Exception) {}
            if (this.socket === socket) this.socket = null
            out = null
            running = false
            state.value = State()
            Log.i(TAG, "sender stopped")
            onFinished?.invoke()
        }
    }

    private fun sendFrame(type: Byte, payload: ByteArray) {
        val o = out ?: return
        synchronized(writeLock) {
            try {
                val hdr = ByteBuffer.allocate(5).apply {
                    putInt(payload.size)
                    put(type)
                }
                o.write(hdr.array())
                if (payload.isNotEmpty()) o.write(payload)
            } catch (e: Exception) {
                Log.w(TAG, "send failed", e)
                stop()
            }
        }
    }

    // ---------- 反向控制（无障碍执行）----------

    private var dragStartX = 0
    private var dragStartY = 0
    private var dragging = false

    private fun handleControlMouse(action: Int, x: Int, y: Int, wheel: Int) {
        when (action) {
            1 -> { // down
                dragStartX = x
                dragStartY = y
                dragging = true
            }
            0 -> {} // move：不即时手势，up 时按距离决定 tap/swipe
            2 -> { // up
                dragging = false
                val dx = x - dragStartX
                val dy = y - dragStartY
                if (dx * dx + dy * dy < 100) {
                    RemoteCtrlService.tap(x, y)
                } else {
                    RemoteCtrlService.swipe(dragStartX, dragStartY, x, y, 180)
                }
            }
            3 -> { // wheel
                RemoteCtrlService.scroll(if (wheel >= 0) 1 else -1)
            }
        }
    }

    private fun handleControlKey(action: Int, androidKeyCode: Int) {
        if (action == 0) RemoteCtrlService.typeChar(androidKeyCode)
    }

    companion object {
        private const val TAG = "MirrorSender"
        private const val TYPE_CONFIG = 1.toByte()
        private const val TYPE_FRAME = 2.toByte()
        private const val TYPE_HEARTBEAT = 3.toByte()
        const val TYPE_MOUSE = 4
        const val TYPE_KEY = 5
    }
}
