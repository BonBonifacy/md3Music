package com.md3music.md3music

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/** Publishes only app-created download artifacts. All copies run off the UI thread. */
class AudioDownloadPublisher(private val activity: Activity, messenger: BinaryMessenger) {
    companion object { const val PICK_REQUEST = 28451 }
    private val channel = MethodChannel(messenger, "com.md3music.md3music/downloads")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val preferences = activity.getSharedPreferences("download_publications", Activity.MODE_PRIVATE)
    private class State { var cancelled = false; var output: String? = null }
    private val states = ConcurrentHashMap<String, State>()
    private var picker: MethodChannel.Result? = null
    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDirectory" -> {
                    if (picker != null) { result.error("busy", "目录选择器已打开", null); return@setMethodCallHandler }
                    picker = result
                    activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    }, PICK_REQUEST)
                }
                "cancel" -> {
                    val id = call.argument<String>("id") ?: ""
                    val state = states[id]
                    val output = if (state != null) synchronized(state) { state.cancelled = true; state.output } else null
                    result.success(output)
                }
                "publish" -> {
                    val id = call.argument<String>("id") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    val source = call.argument<String>("source") ?: ""
                    val destination = call.argument<String>("destination")
                    val mime = call.argument<String>("mime") ?: "audio/mpeg"
                    if (!id.matches(Regex("[0-9a-f-]{36}")) || name.isBlank() || name.contains('/') || name.contains('\\')) {
                        result.error("invalid_input", "无效下载任务", null); return@setMethodCallHandler
                    }
                    val state = State(); states[id] = state
                    worker.execute {
                        try { val uri = publish(id, name, File(source), destination, mime, state); main.post { result.success(uri) } }
                        catch (e: Exception) { main.post { result.error("publish_failed", e.message, null) } }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    fun onActivityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != PICK_REQUEST) return false
        val pending = picker; picker = null
        val uri = data?.data
        if (code != Activity.RESULT_OK || uri == null) { pending?.success(null); return true }
        try {
            val flags = ((data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
            if ((flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION) == 0) throw SecurityException("目录未授予写入权限")
            activity.contentResolver.takePersistableUriPermission(uri, flags)
            pending?.success(uri.toString())
        } catch (e: Exception) { pending?.error("permission_denied", e.message, null) }
        return true
    }
    private fun publish(id: String, requestedName: String, file: File, destination: String?, mime: String, state: State): String {
        val root = File(activity.filesDir, "download_staging").canonicalFile
        val source = file.canonicalFile
        require(source.parentFile == root && source.isFile && source.length() > 0) { "只能发布应用自有的下载暂存文件" }
        val resolver = activity.contentResolver
        val saved = preferences.getString(id, null)
        val digest = source.inputStream().use { sha256(it) }
        if (saved != null && preferences.getBoolean("$id.complete", false)) {
            try { resolver.openInputStream(Uri.parse(saved))?.use { if (sha256(it) == digest) { synchronized(state) { state.output = saved }; return saved } } } catch (_: Exception) {}
        } else if (saved != null) {
            // Only this task's unfinished publication may be removed. Completed user files are retained.
            try { if (destination?.startsWith("content://") == true) DocumentsContract.deleteDocument(resolver, Uri.parse(saved)) else resolver.delete(Uri.parse(saved), null, null) } catch (_: Exception) {}
        }
        var name = requestedName
        val saf = destination?.startsWith("content://") == true
        var output: Uri? = null
        try {
            output = if (saf) {
                val tree = Uri.parse(destination)
                require(resolver.persistedUriPermissions.any { it.uri == tree && it.isWritePermission }) { "目录写入授权已失效" }
                val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                val names = mutableSetOf<String>()
                resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
                    while (cursor.moveToNext()) names.add(cursor.getString(0))
                }
                var suffix = 0
                while (names.contains(name)) {
                    suffix++
                    val dot = requestedName.lastIndexOf('.')
                    val stem = if (dot > 0) requestedName.substring(0, dot) else requestedName
                    val ext = if (dot > 0) requestedName.substring(dot) else ""
                    name = "$stem(${id.take(8)}${if (suffix == 1) "" else "-$suffix"})$ext"
                }
                DocumentsContract.createDocument(resolver, parent, mime, ".$name.$id.part") ?: error("无法创建目标文档")
            } else {
                require(Build.VERSION.SDK_INT >= 29) { "此系统版本需要先选择可写下载目录" }
                val values = ContentValues().apply {
                    put(MediaStore.Audio.Media.DISPLAY_NAME, name)
                    put(MediaStore.Audio.Media.MIME_TYPE, mime)
                    put(MediaStore.Audio.Media.RELATIVE_PATH, "Music/MD3Music")
                    put(MediaStore.Audio.Media.IS_PENDING, 1)
                }
                resolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values) ?: error("无法创建共享音乐文件")
            }
            preferences.edit().putString(id, output.toString()).putBoolean("$id.complete", false).commit()
            resolver.openOutputStream(requireNotNull(output), "w")?.use { target ->
                source.inputStream().use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        synchronized(state) { check(!state.cancelled) { "下载已取消" } }
                        val count = input.read(buffer); if (count < 0) break
                        target.write(buffer, 0, count)
                    }
                    target.flush()
                }
            } ?: error("目标目录不可写")
            synchronized(state) {
                check(!state.cancelled) { "下载已取消" }
                if (saf) {
                    output = DocumentsContract.renameDocument(resolver, requireNotNull(output), name) ?: error("目标不支持完成文件重命名")
                } else {
                    check(resolver.update(requireNotNull(output), ContentValues().apply { put(MediaStore.Audio.Media.IS_PENDING, 0) }, null, null) == 1) { "发布共享音乐失败" }
                }
                val uri = output.toString()
                preferences.edit().putString(id, uri).putBoolean("$id.complete", true).commit()
                state.output = uri
                return uri
            }
        } catch (e: Exception) {
            output?.let { try { if (saf) DocumentsContract.deleteDocument(resolver, it) else resolver.delete(it, null, null) } catch (_: Exception) {} }
            preferences.edit().remove(id).remove("$id.complete").commit()
            throw e
        }
    }
    private fun sha256(input: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
