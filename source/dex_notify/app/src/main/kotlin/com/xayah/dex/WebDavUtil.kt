package com.xayah.dex

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.system.Os
import org.w3c.dom.Element
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.system.exitProcess

/**
 * WebDAV client CLI backed by HttpCore.
 *
 * No external HTTP/logging client libraries. Daemon mode keeps HttpCore keep-alive sockets
 * per host/port for fast small-file operations, while putstdinchunked remains true
 * streaming and never buffers the whole archive on disk.
 */
object WebDavUtil {
    private val DAV_PROPFIND_BODY = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:allprop/></d:propfind>
    """.trimIndent().toByteArray(StandardCharsets.UTF_8)

    private val http = HttpCore.Client(keepAlive = true)

    @JvmStatic
    fun main(args: Array<String>) {
        if (args.isEmpty()) {
            printUsage()
            exitProcess(2)
        }
        when (args[0]) {
            "mkdir" -> cmdMkdir(args)
            "mkdirrel" -> cmdMkdirRel(args)
            "put" -> cmdPut(args)
            "putrel" -> cmdPutRel(args)
            "putstdin" -> cmdPutStdin(args)
            "putstdinchunked" -> cmdPutStdinChunked(args)
            "putstdinchunkedrel" -> cmdPutStdinChunkedRel(args)
            "get" -> cmdGet(args)
            "getrel" -> cmdGetRel(args)
            "getstdout" -> cmdGetStdout(args)
            "getstdoutrel" -> cmdGetStdoutRel(args)
            "delete" -> cmdDelete(args)
            "deleterel" -> cmdDeleteRel(args)
            "propfind" -> cmdPropfind(args)
            "propfindrel" -> cmdPropfindRel(args)
            "list" -> cmdList(args)
            "listrel" -> cmdListRel(args)
            "encodepath" -> cmdEncodePath(args)
            "decodepath" -> cmdDecodePath(args)
            "daemon" -> cmdDaemon(args)
            "daemonunix" -> cmdDaemonUnix(args)
            else -> {
                printUsage()
                exitProcess(2)
            }
        }
    }

    // ---------------------------------------------------------------- daemon ----

    private fun cmdDaemon(args: Array<String>) {
        require(args.size >= 2) { "daemon <port> [idleTimeoutSec] [ownerPid]" }
        val port = args[1].toIntOrNull() ?: run { println("bad port"); exitProcess(2) }
        require(port in 1..65535) { "bad port" }
        val idleTimeoutMs = ((args.getOrNull(2)?.toLongOrNull()) ?: 1800L) * 1000L
        require(idleTimeoutMs > 0) { "idleTimeoutSec must be > 0" }
        val ownerPid = parseOptionalOwnerPid(args.getOrNull(3))
        runDaemon(TcpDaemonListener(port), "DAEMON_READY $port", idleTimeoutMs, ownerPid)
    }

    private fun cmdDaemonUnix(args: Array<String>) {
        require(args.size >= 2) { "daemonunix <socketPath> [idleTimeoutSec] [ownerPid]" }
        val socketPath = args[1]
        val idleTimeoutMs = ((args.getOrNull(2)?.toLongOrNull()) ?: 1800L) * 1000L
        require(idleTimeoutMs > 0) { "idleTimeoutSec must be > 0" }
        val ownerPid = parseOptionalOwnerPid(args.getOrNull(3))
        val listener = UnixDaemonListener(socketPath)
        runDaemon(listener, "DAEMON_READY_UNIX ${listener.socketPath}", idleTimeoutMs, ownerPid)
    }

    private fun parseOptionalOwnerPid(raw: String?): Int? {
        if (raw.isNullOrBlank()) return null
        val pid = raw.toIntOrNull() ?: throw IllegalArgumentException("ownerPid must be numeric")
        require(pid > 1) { "ownerPid must be > 1" }
        require(readProcStarttime(pid) != null) { "ownerPid is not alive: $pid" }
        return pid
    }

    private fun runDaemon(
        listener: DaemonListener,
        readyLine: String,
        idleTimeoutMs: Long,
        ownerPid: Int?,
    ) {
        val lastActivity = AtomicLong(System.currentTimeMillis())
        val activeRequests = AtomicInteger(0)
        val parentPpidAtStart = if (ownerPid == null) readPpid() else -1
        val ownerStarttime = ownerPid?.let { readProcStarttime(it) }
        val listenerRef = AtomicReference<DaemonListener?>()

        fun closeDaemonResources() {
            runCatching { http.closeAll() }
            runCatching { listenerRef.getAndSet(null)?.close() }
        }

        Runtime.getRuntime().addShutdownHook(Thread { closeDaemonResources() })

        Thread {
            while (true) {
                Thread.sleep(2000)
                val ownerGone = if (ownerPid != null) {
                    ownerStarttime == null || readProcStarttime(ownerPid) != ownerStarttime
                } else {
                    parentPpidAtStart != -1 && readPpid() != parentPpidAtStart
                }
                if (ownerGone) {
                    closeDaemonResources()
                    exitProcess(0)
                }
                if (activeRequests.get() == 0 && System.currentTimeMillis() - lastActivity.get() > idleTimeoutMs) {
                    closeDaemonResources()
                    exitProcess(0)
                }
            }
        }.apply { isDaemon = true; start() }

        listenerRef.set(listener)
        println(readyLine)
        System.out.flush()

        try {
            while (true) {
                val client = try { listener.accept() } catch (_: Exception) {
                    if (listener.isClosed) break else continue
                }
                lastActivity.set(System.currentTimeMillis())
                activeRequests.incrementAndGet()
                Thread {
                    try {
                        handleDaemonConn(client.input, client.output)
                    } catch (e: Exception) {
                        System.err.println("[daemon] unhandled: ${e.javaClass.name}: ${e.message}")
                    } finally {
                        activeRequests.decrementAndGet()
                        lastActivity.set(System.currentTimeMillis())
                        runCatching { client.close() }
                    }
                }.apply { isDaemon = true; start() }
            }
        } finally {
            closeDaemonResources()
        }
    }

    private interface DaemonConnection : Closeable {
        val input: InputStream
        val output: OutputStream
    }

    private interface DaemonListener : Closeable {
        val isClosed: Boolean
        fun accept(): DaemonConnection
    }

    private class TcpDaemonListener(port: Int) : DaemonListener {
        private val server = ServerSocket().apply {
            reuseAddress = true
            bind(InetSocketAddress("127.0.0.1", port))
        }

        override val isClosed: Boolean
            get() = server.isClosed

        override fun accept(): DaemonConnection = TcpDaemonConnection(server.accept())

        override fun close() {
            server.close()
        }
    }

    private class TcpDaemonConnection(private val socket: Socket) : DaemonConnection {
        override val input: InputStream = socket.getInputStream()
        override val output: OutputStream = socket.getOutputStream()

        override fun close() {
            socket.close()
        }
    }

    private class UnixDaemonListener(path: String) : DaemonListener {
        val socketPath: String
        private val closed = AtomicBoolean(false)
        private val bindSocket = LocalSocket(LocalSocket.SOCKET_STREAM)
        private val server: LocalServerSocket

        init {
            require(path.isNotBlank()) { "socketPath is empty" }
            require(!path.contains('\u0000') && !path.contains('\n') && !path.contains('\r')) {
                "socketPath contains invalid characters"
            }

            val socketFile = File(path)
            require(socketFile.isAbsolute) { "socketPath must be absolute" }
            socketPath = socketFile.absolutePath
            require(socketPath.toByteArray(StandardCharsets.UTF_8).size <= UNIX_PATH_MAX_BYTES) {
                "socketPath is too long (max $UNIX_PATH_MAX_BYTES UTF-8 bytes)"
            }

            val parent = socketFile.parentFile ?: throw IOException("socketPath has no parent")
            if (!parent.isDirectory && !parent.mkdirs()) {
                throw IOException("cannot create socket parent: ${parent.absolutePath}")
            }
            if (socketFile.exists() && !socketFile.delete()) {
                throw IOException("cannot remove stale socket: $socketPath")
            }

            try {
                bindSocket.bind(LocalSocketAddress(socketPath, LocalSocketAddress.Namespace.FILESYSTEM))
                server = LocalServerSocket(bindSocket.fileDescriptor)
                runCatching { Os.chmod(socketPath, UNIX_SOCKET_MODE) }
            } catch (e: Throwable) {
                runCatching { bindSocket.close() }
                runCatching { socketFile.delete() }
                throw e
            }
        }

        override val isClosed: Boolean
            get() = closed.get()

        override fun accept(): DaemonConnection = UnixDaemonConnection(server.accept())

        override fun close() {
            if (!closed.compareAndSet(false, true)) return
            // LocalServerSocket(FileDescriptor) does not own the descriptor. Closing the
            // LocalSocket that created/bound it is what releases accept() and the inode.
            runCatching { bindSocket.close() }
            runCatching { server.close() }
            runCatching { File(socketPath).delete() }
        }
    }

    private class UnixDaemonConnection(private val socket: LocalSocket) : DaemonConnection {
        override val input: InputStream = socket.inputStream
        override val output: OutputStream = socket.outputStream

        override fun close() {
            socket.close()
        }
    }

    private fun readPpid(): Int = runCatching {
        File("/proc/self/stat").readText().split(")").last().trim().split(" ")[1].toInt()
    }.getOrDefault(-1)

    private fun readProcStarttime(pid: Int): Long? = runCatching {
        val text = File("/proc/$pid/stat").readText()
        val fields = text.substringAfterLast(')').trim().split(Regex("\\s+"))
        fields.getOrNull(19)?.toLongOrNull()
    }.getOrNull()

    private fun handleDaemonConn(input: InputStream, output: OutputStream) {
        fun readLine(): String {
            // The loopback daemon protocol is byte-oriented and shell/nc sends UTF-8.
            // Do not append byte.toChar(): that turns CJK URL bytes into mojibake
            // (e.g. 主 -> Ã¤Â¸Â»), then HttpCore can no longer choose the correct
            // percent-encoded/raw-UTF8 WebDAV request target.
            val buf = ByteArrayOutputStream(256)
            while (true) {
                val b = input.read()
                if (b == -1 || b == '\n'.code) break
                if (b != '\r'.code) buf.write(b)
            }
            return buf.toByteArray().toString(StandardCharsets.UTF_8)
        }

        val command = readLine()
        val user = readLine()
        val pass = readLine()
        val url = readLine()
        val extra = readLine()
        val requestBodyLen = readLine().toLongOrNull() ?: 0L

        var httpCode = 0
        var respBody = ByteArray(0)
        var streamingResponseStarted = false
        var streamingChunkOutput: RelayChunkedOutputStream? = null
        var lastError: Throwable? = null

        fun safe(block: () -> Int): Int = runCatching(block).getOrElse { e -> lastError = e; HttpCore.extractCode(e) }

        fun extraParts(): List<String> = extra.split('\t')
        fun extra1(): String = extraParts().getOrElse(0) { "" }
        fun extra2(): String = extraParts().getOrElse(1) { "" }
        fun relUrl(): String = buildRelUrl(url, extra1())

        when (command) {
            "mkdir" -> httpCode = safe { mkcol(user, pass, url) }
            "mkdirrel" -> httpCode = safe { mkcol(user, pass, relUrl()) }
            "put" -> {
                val file = File(extra)
                httpCode = if (!file.isFile) 0 else safe {
                    FileInputStream(file).use { put(user, pass, url, it, file.length(), chunked = false) }
                }
            }
            "putrel" -> {
                val file = File(extra2())
                httpCode = if (!file.isFile) 0 else safe {
                    FileInputStream(file).use { put(user, pass, relUrl(), it, file.length(), chunked = false) }
                }
            }
            "putstdin" -> httpCode = safe {
                put(user, pass, url, LimitedInputStream(input, requestBodyLen), requestBodyLen, chunked = false)
            }
            "putstdinchunked" -> httpCode = safe {
                put(user, pass, url, input, contentLength = null, chunked = true)
            }
            "putstdinchunkedrel" -> httpCode = safe {
                put(user, pass, relUrl(), input, contentLength = null, chunked = true)
            }
            "get" -> httpCode = safe {
                FileOutputStream(extra).use { out -> getTo(user, pass, url, out) }
            }
            "getrel" -> httpCode = safe {
                FileOutputStream(extra2()).use { out -> getTo(user, pass, relUrl(), out) }
            }
            "getstdout" -> httpCode = safe {
                streamDaemonGet(user, pass, url, output) { chunkOutput ->
                    streamingResponseStarted = true
                    streamingChunkOutput = chunkOutput
                }
            }
            "getstdoutrel" -> httpCode = safe {
                streamDaemonGet(user, pass, relUrl(), output) { chunkOutput ->
                    streamingResponseStarted = true
                    streamingChunkOutput = chunkOutput
                }
            }
            "delete" -> httpCode = safe { delete(user, pass, url) }
            "deleterel" -> httpCode = safe { delete(user, pass, relUrl()) }
            "propfind" -> {
                val depth = extra.toIntOrNull() ?: 0
                httpCode = safe { propfindRaw(user, pass, url, depth).first }
            }
            "propfindrel" -> {
                val depth = extra2().toIntOrNull() ?: 0
                httpCode = safe { propfindRaw(user, pass, relUrl(), depth).first }
            }
            "list" -> {
                val depth = extra.toIntOrNull() ?: -1
                httpCode = safe {
                    val (code, body) = propfindRaw(user, pass, url, depth)
                    if (code in 200..299) respBody = parseDavList(body).toByteArray(StandardCharsets.UTF_8)
                    code
                }
            }
            "listrel" -> {
                val depth = extra2().toIntOrNull() ?: -1
                httpCode = safe {
                    val (code, body) = propfindRaw(user, pass, relUrl(), depth)
                    if (code in 200..299) respBody = parseDavList(body).toByteArray(StandardCharsets.UTF_8)
                    code
                }
            }
            "encodepath" -> {
                respBody = HttpCore.percentEncodePath(url).toByteArray(StandardCharsets.UTF_8)
                httpCode = 200
            }
            "decodepath" -> {
                respBody = HttpCore.percentDecodePath(url).toByteArray(StandardCharsets.UTF_8)
                httpCode = 200
            }
            else -> httpCode = 0
        }

        if (httpCode == 0 && lastError != null) {
            System.err.println("[daemon] cmd=$command url=$url -> ${lastError!!.javaClass.name}: ${lastError!!.message}")
            lastError!!.printStackTrace(System.err)
        }

        if (streamingResponseStarted) {
            // Unknown-origin-length streams are re-framed between daemon and native relay.
            // Only a successfully completed HTTP body writes the terminating zero chunk;
            // an interrupted body therefore makes unixsock return non-zero instead of
            // silently accepting a truncated archive.
            if (httpCode in 200..299) streamingChunkOutput?.finish()
            output.flush()
            return
        }

        val responseBodyLen = respBody.size.toLong()
        writeDaemonResponseHead(output, httpCode, responseBodyLen)
        if (respBody.isNotEmpty()) output.write(respBody)
        output.flush()
    }

    private fun writeDaemonResponseHead(output: OutputStream, code: Int, bodyLength: Long) {
        output.write("HTTP $code\n".toByteArray(StandardCharsets.UTF_8))
        output.write("$bodyLength\n".toByteArray(StandardCharsets.UTF_8))
        output.flush()
    }

    /**
     * Stream a GET response directly from HttpCore into the daemon connection.
     *
     * bodyLength >= 0: raw body with exact byte count.
     * bodyLength == -2: daemon-local chunk framing, decoded by native unixsock v2.
     */
    private fun streamDaemonGet(
        user: String,
        pass: String,
        url: String,
        output: OutputStream,
        onStarted: (RelayChunkedOutputStream?) -> Unit
    ): Int {
        val code = http.getToStreaming(url, user, pass) { status, originLength ->
            val protocolLength = if (status in 200..299 && originLength < 0) DAEMON_CHUNKED_BODY else originLength.coerceAtLeast(0L)
            writeDaemonResponseHead(output, status, protocolLength)
            if (protocolLength == DAEMON_CHUNKED_BODY) {
                RelayChunkedOutputStream(output).also(onStarted)
            } else {
                onStarted(null)
                output
            }
        }
        return code
    }

    private class RelayChunkedOutputStream(private val target: OutputStream) : OutputStream() {
        private var finished = false

        override fun write(value: Int) {
            val one = byteArrayOf(value.toByte())
            write(one, 0, 1)
        }

        override fun write(buffer: ByteArray, offset: Int, length: Int) {
            check(!finished) { "relay chunk stream already finished" }
            if (length <= 0) return
            target.write(Integer.toHexString(length).toByteArray(StandardCharsets.US_ASCII))
            target.write("\r\n".toByteArray(StandardCharsets.US_ASCII))
            target.write(buffer, offset, length)
            target.write("\r\n".toByteArray(StandardCharsets.US_ASCII))
        }

        override fun flush() {
            target.flush()
        }

        fun finish() {
            if (finished) return
            finished = true
            target.write("0\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
            target.flush()
        }
    }

    // ---------------------------------------------------------------- commands ----

    private fun cmdMkdir(args: Array<String>) {
        require(args.size >= 4) { "mkdir <user> <pass> <url>" }
        finish(runCatching { mkcol(args[1], args[2], args[3]) }.getOrElse { HttpCore.extractCode(it) })
    }

    private fun cmdMkdirRel(args: Array<String>) {
        require(args.size >= 5) { "mkdirrel <user> <pass> <baseUrl> <relPath>" }
        finish(runCatching { mkcol(args[1], args[2], buildRelUrl(args[3], args[4])) }.getOrElse { HttpCore.extractCode(it) })
    }

    private fun cmdPut(args: Array<String>) {
        require(args.size >= 5) { "put <user> <pass> <url> <localFile>" }
        val file = File(args[4])
        if (!file.isFile) { println("HTTP 000"); exitProcess(1) }
        val code = runCatching {
            FileInputStream(file).use { put(args[1], args[2], args[3], it, file.length(), chunked = false) }
        }.getOrElse { HttpCore.extractCode(it) }
        finish(code)
    }

    private fun cmdPutRel(args: Array<String>) {
        require(args.size >= 6) { "putrel <user> <pass> <baseUrl> <relPath> <localFile>" }
        val file = File(args[5])
        if (!file.isFile) { println("HTTP 000"); exitProcess(1) }
        val code = runCatching {
            FileInputStream(file).use { put(args[1], args[2], buildRelUrl(args[3], args[4]), it, file.length(), chunked = false) }
        }.getOrElse { HttpCore.extractCode(it) }
        finish(code)
    }

    private fun cmdPutStdin(args: Array<String>) {
        require(args.size >= 4) { "putstdin <user> <pass> <url>" }
        val tmp = File.createTempFile("webdavutil_stdin_", ".bin")
        try {
            FileOutputStream(tmp).use { out -> System.`in`.copyTo(out) }
            val code = runCatching {
                FileInputStream(tmp).use { put(args[1], args[2], args[3], it, tmp.length(), chunked = false) }
            }.getOrElse { HttpCore.extractCode(it) }
            finish(code)
        } finally {
            tmp.delete()
        }
    }

    private fun cmdPutStdinChunked(args: Array<String>) {
        require(args.size >= 4) { "putstdinchunked <user> <pass> <url>" }
        val code = runCatching {
            put(args[1], args[2], args[3], System.`in`, contentLength = null, chunked = true)
        }.getOrElse { HttpCore.extractCode(it) }
        finish(code)
    }

    private fun cmdPutStdinChunkedRel(args: Array<String>) {
        require(args.size >= 5) { "putstdinchunkedrel <user> <pass> <baseUrl> <relPath>" }
        val code = runCatching {
            put(args[1], args[2], buildRelUrl(args[3], args[4]), System.`in`, contentLength = null, chunked = true)
        }.getOrElse { HttpCore.extractCode(it) }
        finish(code)
    }

    private fun cmdGet(args: Array<String>) {
        require(args.size >= 5) { "get <user> <pass> <url> <localFile>" }
        val code = runCatching {
            FileOutputStream(args[4]).use { out -> getTo(args[1], args[2], args[3], out) }
        }.getOrElse { HttpCore.extractCode(it) }
        finish(code)
    }

    private fun cmdGetRel(args: Array<String>) {
        require(args.size >= 6) { "getrel <user> <pass> <baseUrl> <relPath> <localFile>" }
        val code = runCatching {
            FileOutputStream(args[5]).use { out -> getTo(args[1], args[2], buildRelUrl(args[3], args[4]), out) }
        }.getOrElse { HttpCore.extractCode(it) }
        finish(code)
    }

    private fun cmdGetStdout(args: Array<String>) {
        require(args.size >= 4) { "getstdout <user> <pass> <url>" }
        val code = runCatching { getTo(args[1], args[2], args[3], System.out) }.getOrElse { HttpCore.extractCode(it) }
        System.out.flush()
        System.err.println("HTTP $code")
        exitProcess(if (code in 200..299) 0 else 1)
    }

    private fun cmdGetStdoutRel(args: Array<String>) {
        require(args.size >= 5) { "getstdoutrel <user> <pass> <baseUrl> <relPath>" }
        val code = runCatching { getTo(args[1], args[2], buildRelUrl(args[3], args[4]), System.out) }.getOrElse { HttpCore.extractCode(it) }
        System.out.flush()
        System.err.println("HTTP $code")
        exitProcess(if (code in 200..299) 0 else 1)
    }

    private fun cmdDelete(args: Array<String>) {
        require(args.size >= 4) { "delete <user> <pass> <url>" }
        finish(runCatching { delete(args[1], args[2], args[3]) }.getOrElse { HttpCore.extractCode(it) })
    }

    private fun cmdDeleteRel(args: Array<String>) {
        require(args.size >= 5) { "deleterel <user> <pass> <baseUrl> <relPath>" }
        finish(runCatching { delete(args[1], args[2], buildRelUrl(args[3], args[4])) }.getOrElse { HttpCore.extractCode(it) })
    }

    private fun cmdPropfind(args: Array<String>) {
        require(args.size >= 4) { "propfind <user> <pass> <url> [depth]" }
        val depth = args.getOrNull(4)?.toIntOrNull() ?: 0
        finish(runCatching { propfindRaw(args[1], args[2], args[3], depth).first }.getOrElse { HttpCore.extractCode(it) })
    }

    private fun cmdPropfindRel(args: Array<String>) {
        require(args.size >= 5) { "propfindrel <user> <pass> <baseUrl> <relPath> [depth]" }
        val depth = args.getOrNull(5)?.toIntOrNull() ?: 0
        finish(runCatching { propfindRaw(args[1], args[2], buildRelUrl(args[3], args[4]), depth).first }.getOrElse { HttpCore.extractCode(it) })
    }

    private fun cmdList(args: Array<String>) {
        require(args.size >= 4) { "list <user> <pass> <url> [depth]" }
        val depth = args.getOrNull(4)?.toIntOrNull() ?: -1
        val code = runCatching {
            val (status, body) = propfindRaw(args[1], args[2], args[3], depth)
            if (status in 200..299) print(parseDavList(body))
            status
        }.getOrElse { HttpCore.extractCode(it) }
        finish(code)
    }

    private fun cmdListRel(args: Array<String>) {
        require(args.size >= 5) { "listrel <user> <pass> <baseUrl> <relPath> [depth]" }
        val depth = args.getOrNull(5)?.toIntOrNull() ?: -1
        val code = runCatching {
            val (status, body) = propfindRaw(args[1], args[2], buildRelUrl(args[3], args[4]), depth)
            if (status in 200..299) print(parseDavList(body))
            status
        }.getOrElse { HttpCore.extractCode(it) }
        finish(code)
    }

    private fun cmdEncodePath(args: Array<String>) {
        require(args.size >= 2) { "encodepath <text>" }
        print(HttpCore.percentEncodePath(args[1]))
    }

    private fun cmdDecodePath(args: Array<String>) {
        require(args.size >= 2) { "decodepath <text>" }
        print(HttpCore.percentDecodePath(args[1]))
    }

    // ---------------------------------------------------------------- relative URL API ----

    private fun buildRelUrl(baseUrl: String, relPath: String): String {
        val base = baseUrl.trimEnd('/')
        val rel = relPath.trimStart('/')
        if (rel.isEmpty() || rel == ".") return base
        return "$base/$rel"
    }

    // ---------------------------------------------------------------- WebDAV HTTP ----

    private fun mkcol(user: String, pass: String, url: String): Int {
        val code = http.request("MKCOL", url, user, pass, mapOf("Content-Length" to "0"))
        return if (code == 405) 200 else code
    }

    private fun put(user: String, pass: String, url: String, input: InputStream, contentLength: Long?, chunked: Boolean): Int {
        val headers = linkedMapOf("Content-Type" to "application/octet-stream")
        if (chunked || contentLength == null) headers["Transfer-Encoding"] = "chunked" else headers["Content-Length"] = contentLength.toString()
        return http.request("PUT", url, user, pass, headers, bodyWriter = { out ->
            if (chunked || contentLength == null) HttpCore.writeChunked(input, out) else input.copyTo(out)
        })
    }

    private fun getTo(user: String, pass: String, url: String, out: OutputStream): Int {
        return http.request("GET", url, user, pass) { code, headers, input ->
            if (code in 200..299) HttpCore.readResponseBody(headers, input, out) else HttpCore.discardErrorResponseBody(headers, input)
        }
    }

    private fun delete(user: String, pass: String, url: String): Int {
        val code = http.request("DELETE", url, user, pass, mapOf("Content-Length" to "0"))
        return if (code == 404) 204 else code
    }

    private fun propfindRaw(user: String, pass: String, url: String, depth: Int): Pair<Int, ByteArray> {
        val bodyOut = ByteArrayOutputStream()
        val headers = linkedMapOf(
            "Depth" to if (depth < 0) "infinity" else depth.toString(),
            "Content-Type" to "application/xml; charset=utf-8",
            "Content-Length" to DAV_PROPFIND_BODY.size.toString()
        )
        val code = http.request("PROPFIND", url, user, pass, headers, bodyWriter = { out -> out.write(DAV_PROPFIND_BODY) }) { status, respHeaders, input ->
            if (status in 200..299) HttpCore.readResponseBody(respHeaders, input, bodyOut) else HttpCore.discardErrorResponseBody(respHeaders, input)
        }
        return code to bodyOut.toByteArray()
    }

    // ---------------------------------------------------------------- XML/list ----

    private data class DavEntry(val href: String, val length: Long, val isDirectory: Boolean)

    private fun parseDavList(body: ByteArray): String {
        if (body.isEmpty()) return ""
        val entries = mutableListOf<DavEntry>()
        val factory = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
            runCatching { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
            runCatching { setFeature("http://xml.org/sax/features/external-general-entities", false) }
            runCatching { setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
            runCatching { setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false) }
            isExpandEntityReferences = false
        }
        val doc = factory.newDocumentBuilder().parse(ByteArrayInputStream(body))
        val responses = doc.getElementsByTagNameNS("*", "response")
        for (i in 0 until responses.length) {
            val node = responses.item(i)
            if (node !is Element) continue
            val hrefRaw = node.firstText("href") ?: continue
            val href = HttpCore.percentDecodePath(hrefRaw)
            val length = node.firstText("getcontentlength")?.trim()?.toLongOrNull() ?: 0L
            val isDir = node.hasDescendant("collection") || href.endsWith("/")
            entries.add(DavEntry(href, length, isDir))
        }
        val sb = StringBuilder()
        for (e in entries) {
            sb.append(e.href).append('\t').append(e.length).append('\t').append(if (e.isDirectory) "D" else "F").append('\n')
        }
        return sb.toString()
    }

    private fun Element.firstText(local: String): String? {
        val list = getElementsByTagNameNS("*", local)
        if (list.length == 0) return null
        return list.item(0)?.textContent
    }

    private fun Element.hasDescendant(local: String): Boolean = getElementsByTagNameNS("*", local).length > 0

    // ---------------------------------------------------------------- util ----

    private fun InputStream.copyTo(out: OutputStream) {
        val buf = ByteArray(HttpCore.COPY_BUF_SIZE)
        while (true) {
            val n = read(buf)
            if (n <= 0) break
            out.write(buf, 0, n)
        }
    }

    private fun finish(code: Int) {
        println("HTTP $code")
        exitProcess(if (code in 200..299) 0 else 1)
    }

    private class LimitedInputStream(private val source: InputStream, private var remaining: Long) : InputStream() {
        override fun read(): Int {
            if (remaining <= 0) return -1
            val b = source.read()
            if (b >= 0) remaining--
            return b
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (remaining <= 0) return -1
            val want = minOf(length.toLong(), remaining).toInt()
            val n = source.read(buffer, offset, want)
            if (n > 0) remaining -= n.toLong()
            return n
        }
    }

    private fun printUsage() {
        println("WebDavUtil commands:")
        println("  mkdir <user> <pass> <url>")
        println("  mkdirrel <user> <pass> <baseUrl> <relPath>")
        println("  put <user> <pass> <url> <localFile>")
        println("  putrel <user> <pass> <baseUrl> <relPath> <localFile>")
        println("  putstdin <user> <pass> <url>            (data on stdin, fixed Content-Length via temp file)")
        println("  putstdinchunked <user> <pass> <url>     (data on stdin, true streaming chunked PUT)")
        println("  get <user> <pass> <url> <localFile>")
        println("  getstdout <user> <pass> <url>           (bytes on stdout, HTTP line on stderr)")
        println("  delete <user> <pass> <url>")
        println("  propfind <user> <pass> <url> [depth]")
        println("  list <user> <pass> <url> [depth]        (href\\tlength\\tD|F lines, then HTTP line)")
        println("  encodepath <text>")
        println("  decodepath <text>")
        println("  daemon <port> [idleTimeoutSec] [ownerPid]          (persistent mode, TCP loopback)")
        println("  daemonunix <socketPath> [idleTimeoutSec] [ownerPid] (persistent mode, AF_UNIX filesystem socket)")
    }

    private const val UNIX_PATH_MAX_BYTES = 100
    private const val UNIX_SOCKET_MODE = 0x180 // 0600
    private const val DAEMON_CHUNKED_BODY = -2L
}
