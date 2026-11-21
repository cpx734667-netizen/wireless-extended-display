package io.github.jqssun.airplay.mirror

import android.content.Context
import android.util.Log
import android.view.Surface
import io.github.jqssun.airplay.renderer.VideoRenderer
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.concurrent.thread
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * 「无线扩展屏」接收端（WXESMIRROR / TCP 9000）。
 *
 * 与 Mac / Windows / 网页发送端配套：接收 H.264 AnnexB 码流，交给
 * [VideoRenderer] 硬解后显示到 [Surface]；同时把触摸事件封装成
 * type=4 鼠标消息回传给发送端，实现反向控制。
 *
 * 协议：
 *   握手 16 字节 = "WXESMIRROR"(10) + version(1) + width(2 BE) + height(2 BE) + fps(1)
 *   之后每帧 = length(4 BE) + type(1) + payload
 *   type 1 = SPS/PPS，type 2 = 一个访问单元，type 3 = 心跳
 *   type 4 = 鼠标（发送端可执行），type 5 = 键盘
 */
class MirrorReceiver(private val ctx: Context) {

    data class State(
        val running: Boolean = false,
        val connected: Boolean = false,
        val width: Int = 0,
        val height: Int = 0,
        val fps: Int = 0,
        val error: String = ""
    )

    val state = MutableStateFlow(State())

    private val renderer = VideoRenderer(ctx)
    private val controlQueue = ConcurrentLinkedQueue<ByteArray>()

    @Volatile private var running = false
    @Volatile private var frameIndex = 0L
    @Volatile private var lastDataAt = 0L
    @Volatile private var surface: Surface? = null
    @Volatile private var socket: Socket? = null
    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var controlThread: Thread? = null
    private var fps = 30

    fun setSurface(surface: Surface?) {
        this.surface = surface
        if (surface != null) {
            val s = state.value
            if (s.width > 0 && s.height > 0) {
                renderer.setResolution(s.width, s.height)
            }
            renderer.setSurface(surface)
        }
    }

    fun start() {
        if (running) return
        running = true
        state.value = State(running = true)
        try {
            serverSocket = ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(InetAddress.getByName("0.0.0.0"), PORT), 16)
            }
            state.value = State(running = true)
            thread(name = "mirror-accept", isDaemon = true) { acceptLoop() }
            Log.i(TAG, "listening on $PORT")
        } catch (e: Exception) {
            running = false
            state.value = State(error = "端口 $PORT 监听失败：${e.message ?: e.javaClass.simpleName}")
            Log.e(TAG, "listen failed", e)
        }
    }

    fun stop() {
        running = false
        try { socket?.close() } catch (_: Exception) {}
        try { serverSocket?.close() } catch (_: Exception) {}
        socket = null
        serverSocket = null
        controlThread?.interrupt()
        controlThread = null
        controlQueue.clear()
        renderer.stopSession()
        state.value = State()
    }

    fun release() {
        stop()
        renderer.release()
    }

    // ---------------------------------------------------------------- 接收

    private fun acceptLoop() {
        val server = serverSocket ?: return
        while (running) {
            val client = try {
                server.accept()
            } catch (e: Exception) {
                if (running) Log.w(TAG, "accept error", e)
                break
            }
            if (!running) {
                try { client.close() } catch (_: Exception) {}
                break
            }
            socket = client
            try {
                handleClient(client)
            } catch (e: Exception) {
                if (running) Log.i(TAG, "session ended: ${e.message ?: e.javaClass.simpleName}")
            } finally {
                try { client.close() } catch (_: Exception) {}
                if (socket === client) {
                    socket = null
                    renderer.stopSession()
                    val error = state.value.error
                    state.value = State(running = running, error = error)
                    Log.i(TAG, "client disconnected")
                }
            }
        }
    }

    private fun handleClient(client: Socket) {
        client.soTimeout = 15_000
        val input = DataInputStream(BufferedInputStream(client.getInputStream()))

        val magic = ByteArray(MAGIC.size)
        input.readFully(magic)
        if (!magic.contentEquals(MAGIC)) {
            Log.w(TAG, "bad magic: ${String(magic, Charsets.UTF_8)}")
            state.value = State(running = true, error = "协议不匹配（不是 WXESMIRROR 发送端）")
            return
        }

        val version = input.readUnsignedByte()
        val width = input.readUnsignedShort()
        val height = input.readUnsignedShort()
        var sourceFps = input.readUnsignedByte()
        if (sourceFps !in 1..120) sourceFps = 30
        fps = sourceFps

        Log.i(TAG, "handshake ver=$version ${width}x$height@$fps")
        if (version != 1 || width <= 0 || height <= 0) {
            state.value = State(running = true, error = "不支持的握手参数")
            return
        }

        renderer.setResolution(width, height)
        if (!renderer.selectDecoders(width, height, fps, false)) {
            state.value = State(running = true, error = "没有可用的 H.264 解码器")
            return
        }
        surface?.let { renderer.setSurface(it) }
        renderer.startSession()
        state.value = State(true, true, width, height, fps)
        frameIndex = 0
        lastDataAt = System.currentTimeMillis()
        startWatchdog(client)

        while (running) {
            val length = input.readInt()
            if (length < 0 || length > MAX_FRAME) {
                throw IOException("bad frame length $length")
            }
            val type = input.readUnsignedByte()
            val payload = ByteArray(length)
            if (length > 0) input.readFully(payload)
            lastDataAt = System.currentTimeMillis()

            // 配置帧和视频帧都送给解码器：SPS/PPS 自带 AnnexB 起始码，
            // VideoRenderer 会在关键帧处自动重建 codec。
            if (type == TYPE_CONFIG || type == TYPE_FRAME) {
                renderer.feedFrame(payload, framePtsNs(), false)
                frameIndex++
            }
        }
    }

    private fun startWatchdog(client: Socket) {
        thread(name = "mirror-watchdog", isDaemon = true) {
            try {
                while (running && socket === client) {
                    Thread.sleep(5_000)
                    if (System.currentTimeMillis() - lastDataAt > 20_000) {
                        Log.w(TAG, "watchdog: 20s 无数据，结束会话")
                        try { client.close() } catch (_: Exception) {}
                        break
                    }
                }
            } catch (_: InterruptedException) {
            } catch (_: Exception) {
            }
        }
    }

    private fun framePtsNs(): Long = frameIndex * 1_000_000_000L / fps.coerceAtLeast(1)

    // ---------------------------------------------------------------- 反控

    fun sendMouse(action: Int, x: Int, y: Int, wheel: Int = 0) {
        val buf = ByteBuffer.allocate(7).order(ByteOrder.BIG_ENDIAN)
        buf.put(action.toByte())
        buf.putShort(x.coerceIn(0, 1000).toShort())
        buf.putShort(y.coerceIn(0, 1000).toShort())
        buf.putShort(wheel.toShort())
        sendControl(TYPE_MOUSE, buf.array())
    }

    fun sendKey(action: Int, androidKeyCode: Int) {
        val buf = ByteBuffer.allocate(5).order(ByteOrder.BIG_ENDIAN)
        buf.put(action.toByte())
        buf.putInt(androidKeyCode)
        sendControl(TYPE_KEY, buf.array())
    }

    private fun sendControl(type: Int, payload: ByteArray) {
        val target = socket ?: return
        val header = ByteBuffer.allocate(5).order(ByteOrder.BIG_ENDIAN)
            .putInt(payload.size)
            .put(type.toByte())
            .array()
        controlQueue.add(header + payload)
        ensureControlThread(target)
    }

    private fun ensureControlThread(target: Socket) {
        if (controlThread?.isAlive == true) return
        controlThread = thread(name = "mirror-control", isDaemon = true) {
            try {
                val out = target.getOutputStream()
                while (running && socket === target) {
                    val packet = controlQueue.poll()
                    if (packet == null) {
                        Thread.sleep(10)
                        continue
                    }
                    out.write(packet)
                    out.flush()
                }
            } catch (e: Exception) {
                Log.i(TAG, "control channel closed: ${e.message ?: e.javaClass.simpleName}")
            }
        }
    }

    companion object {
        const val PORT = 9000
        const val TYPE_MOUSE = 4
        const val TYPE_KEY = 5
        private const val TAG = "MirrorReceiver"
        private const val MAX_FRAME = 4 * 1024 * 1024
        private const val TYPE_CONFIG = 1
        private const val TYPE_FRAME = 2
        private val MAGIC = "WXESMIRROR".toByteArray(Charsets.US_ASCII)
    }
}
