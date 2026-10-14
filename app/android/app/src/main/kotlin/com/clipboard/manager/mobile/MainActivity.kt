package com.clipboard.manager.mobile

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import java.io.File

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        intent?.let { intent = sanitizeShareIntent(it) }
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        val safe = sanitizeShareIntent(intent)
        setIntent(safe)
        super.onNewIntent(safe)
    }

    // receive_sharing_intent copies content:// streams to cacheDir using the provider-supplied display name,
    // which allows path traversal into app-private files. Copy shared streams here under sanitized names and
    // hand the plugin plain file:// URIs; file:// URIs from other apps are dropped.
    @Suppress("DEPRECATION")
    private fun sanitizeShareIntent(source: Intent): Intent {
        val multiple = source.action == Intent.ACTION_SEND_MULTIPLE
        if (source.action != Intent.ACTION_SEND && !multiple) return source
        val uris: List<Uri> = if (multiple) {
            source.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        } else {
            listOfNotNull(source.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        }
        if (uris.isEmpty()) return source
        val root = File(cacheDir, "shared")
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        root.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.deleteRecursively() }
        val dir = File(root, System.nanoTime().toString())
        val copies = ArrayList<Uri>()
        uris.forEachIndexed { index, uri -> copyShared(uri, File(dir, index.toString()), index)?.let { copies.add(Uri.fromFile(it)) } }
        val safe = Intent(source)
        safe.clipData = null
        safe.removeExtra(Intent.EXTRA_STREAM)
        safe.removeExtra(Intent.EXTRA_MIME_TYPES)
        if (copies.isEmpty()) {
            if (safe.getStringExtra(Intent.EXTRA_TEXT).isNullOrEmpty()) safe.action = Intent.ACTION_MAIN
        } else if (multiple) {
            safe.putParcelableArrayListExtra(Intent.EXTRA_STREAM, copies)
        } else {
            safe.putExtra(Intent.EXTRA_STREAM, copies[0])
        }
        return safe
    }

    private fun copyShared(uri: Uri, dir: File, index: Int): File? {
        if (uri.scheme != "content") return null
        return try {
            dir.mkdirs()
            val target = File(dir, safeName(displayName(uri), index))
            val input = contentResolver.openInputStream(uri) ?: return null
            input.use { stream -> target.outputStream().use { stream.copyTo(it) } }
            target
        } catch (e: Exception) {
            null
        }
    }

    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getString(0) else null
        }
    } catch (e: Exception) {
        null
    }

    private fun safeName(name: String?, index: Int): String {
        val base = (name ?: "")
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .replace(Regex("[\\u0000-\\u001f\\u007f:*?\"<>|]"), "_")
            .trim()
            .take(120)
        return if (base.isEmpty() || base.all { it == '.' }) "file-${index + 1}" else base
    }
}
