package com.alizesa.motif.library

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.OperationCanceledException
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private const val BATCH_SIZE = 200
private const val METHODS_CHANNEL = "motif/library_scanner"
private val CHILD_PROJECTION = arrayOf(
    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
    DocumentsContract.Document.COLUMN_MIME_TYPE,
    DocumentsContract.Document.COLUMN_SIZE,
    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
)

private class RootUnavailableException(message: String) : SecurityException(message)

private fun locationKey(authority: String, documentId: String): String =
    "$authority|$documentId"

private fun Cursor.getStringOrNull(column: String): String? {
    val index = getColumnIndex(column)
    return if (index < 0 || isNull(index)) null else getString(index)
}

private fun Cursor.getLongOrNull(column: String): Long? {
    val index = getColumnIndex(column)
    return if (index < 0 || isNull(index)) null else getLong(index)
}

private fun Cursor.requireCompleteResults() {
    val information = extras
    check(!information.getBoolean(DocumentsContract.EXTRA_LOADING, false)) {
        "SAF provider is still loading; retry the scan after loading finishes"
    }
    check(information.getString(DocumentsContract.EXTRA_ERROR) == null) {
        "SAF provider returned incomplete results"
    }
}

/** Pull-based SAF traversal. Cursor access and disposal stay on one worker. */
class SafLibraryScanner(context: Context, messenger: BinaryMessenger) {
    private val resolver: ContentResolver = context.contentResolver
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val metadataWorker = Executors.newSingleThreadExecutor()
    private val methods = MethodChannel(messenger, METHODS_CHANNEL)
    private val scans = ConcurrentHashMap<String, TreeScan>()
    private var closed = false

    init {
        methods.setMethodCallHandler(::handleMethod)
    }

    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        if (closed) {
            result.error("scanner_closed", "The scanner has been detached", null)
            return
        }
        when (call.method) {
            "persistedTrees" -> worker.execute {
                try {
                    complete(result, resolver.persistedUriPermissions
                        .filter { it.isReadPermission }.map { it.uri.toString() })
                } catch (error: Exception) {
                    fail(result, error)
                }
            }

            "describeTree" -> {
                val uri = call.argument<String>("treeUri")
                if (uri == null) {
                    result.error("invalid_uri", "treeUri is required", null)
                    return
                }
                worker.execute {
                    try {
                        complete(result, describeTree(Uri.parse(uri)))
                    } catch (error: Exception) {
                        fail(result, error)
                    }
                }
            }

            "startScan" -> {
                val id = call.argument<String>("scanId")
                val uri = call.argument<String>("treeUri")
                val extensions = call.argument<List<*>>("extensions")
                if (id.isNullOrEmpty() || uri == null || extensions.isNullOrEmpty() ||
                    extensions.any { it !is String || it.isEmpty() }
                ) {
                    result.error("invalid_arguments", "scanId, treeUri and extensions are required", null)
                    return
                }
                val scan = try {
                    TreeScan(
                        id,
                        Uri.parse(uri),
                        extensions.filterIsInstance<String>().map { it.lowercase(Locale.ROOT) }.toSet(),
                    )
                } catch (error: Exception) {
                    result.error("invalid_uri", error.message, null)
                    return
                }
                if (scans.putIfAbsent(id, scan) != null) {
                    result.error("duplicate_scan", "scanId is already active", null)
                    return
                }
                worker.execute {
                    try {
                        scan.cancellation.throwIfCanceled()
                        describeTree(scan.treeUri, scan.cancellation)
                        scan.cancellation.throwIfCanceled()
                        complete(result, null)
                    } catch (error: Exception) {
                        scans.remove(scan.id, scan)
                        scan.close()
                        fail(result, error)
                    }
                }
            }

            "nextBatch" -> {
                val scan = call.argument<String>("scanId")?.let { scans[it] }
                if (scan == null) {
                    result.error("unknown_scan", "No scan with this ID is active", null)
                    return
                }
                if (!scan.requestInFlight.compareAndSet(false, true)) {
                    result.error("batch_in_flight", "Wait for the previous batch", null)
                    return
                }
                worker.execute { readNextBatch(scan, result) }
            }

            "cancelScan" -> {
                val scan = call.argument<String>("scanId")?.let { scans.remove(it) }
                if (scan != null) {
                    scan.cancellation.cancel()
                    worker.execute { scan.close() }
                }
                result.success(null)
            }

            "checkFileAccess" -> {
                val uri = call.argument<String>("uri")
                if (uri == null) {
                    result.error("invalid_uri", "uri is required", null)
                    return
                }
                worker.execute {
                    try {
                        val documentUri = Uri.parse(uri)
                        require(documentUri.scheme == "content") { "A content URI is required" }
                        val descriptor = resolver.openFileDescriptor(documentUri, "r")
                            ?: throw IllegalStateException("Cannot open the selected document")
                        descriptor.use { /* Access check only; no audio is read. */ }
                        complete(result, null)
                    } catch (error: Exception) {
                        fail(result, error)
                    }
                }
            }
            "openMetadataFile", "metadataFileState" -> {
                val uriText = call.argument<String>("uri")
                if (uriText == null) {
                    result.error("invalid_uri", "uri is required", null)
                    return
                }
                metadataWorker.execute {
                    try {
                        val uri = Uri.parse(uriText)
                        require(uri.scheme == "content" && DocumentsContract.isTreeUri(uri)) {
                            "A tree-scoped content URI is required"
                        }
                        requirePersistedReadGrant(DocumentsContract.buildTreeDocumentUri(
                            uri.authority, DocumentsContract.getTreeDocumentId(uri),
                        ))
                        if (call.method == "metadataFileState") {
                            complete(result, metadataFileState(uri))
                        } else {
                            val descriptor = resolver.openFileDescriptor(uri, "r")
                                ?: throw IllegalStateException("Cannot open the selected document")
                            try {
                                val state = metadataFileState(uri)
                                val queriedSize = state["sizeBytes"]
                                check(queriedSize == null || descriptor.statSize < 0 ||
                                    queriedSize == descriptor.statSize) { "Document size changed while opening" }
                                mainHandler.post {
                                    if (closed) {
                                        descriptor.close()
                                        result.error("scanner_closed", "Scanner detached", null)
                                    } else {
                                        // Ownership transfers to Dart, which closes this FD after
                                        // the background parser finishes, including cancellation.
                                        val fd = descriptor.detachFd()
                                        descriptor.close()
                                        result.success(state + mapOf("fd" to fd))
                                    }
                                }
                            } catch (error: Exception) {
                                descriptor.close()
                                throw error
                            }
                        }
                    } catch (error: Exception) {
                        fail(result, error)
                    }
                }
            }
            "releaseTree" -> {
                val uri = call.argument<String>("treeUri")
                if (uri == null) {
                    result.error("invalid_uri", "treeUri is required", null)
                    return
                }
                worker.execute {
                    try {
                        resolver.releasePersistableUriPermission(
                            Uri.parse(uri),
                            Intent.FLAG_GRANT_READ_URI_PERMISSION,
                        )
                        complete(result, null)
                    } catch (_: SecurityException) {
                        // The grant may already have been revoked by Android or the user.
                        complete(result, null)
                    } catch (error: Exception) {
                        fail(result, error)
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun metadataFileState(uri: Uri): Map<String, Long?> {
        val cursor = resolver.query(uri, CHILD_PROJECTION, null, null, null)
            ?: throw IllegalStateException("No metadata state cursor")
        return cursor.use {
            it.requireCompleteResults()
            check(it.moveToFirst()) { "Audio document no longer exists" }
            val size = it.getLongOrNull(DocumentsContract.Document.COLUMN_SIZE)
            val modified = it.getLongOrNull(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            it.requireCompleteResults()
            mapOf("sizeBytes" to size?.takeIf { n -> n >= 0 },
                "modifiedMs" to modified?.takeIf { n -> n > 0 })
        }
    }

    private fun describeTree(
        treeUri: Uri,
        cancellation: CancellationSignal? = null,
    ): Map<String, Any> {
        require(treeUri.scheme == "content") { "A SAF content URI is required" }
        val authority = treeUri.authority
        require(!authority.isNullOrEmpty()) { "SAF URI has no provider authority" }
        requirePersistedReadGrant(treeUri)
        val documentId = DocumentsContract.getTreeDocumentId(treeUri)
        val documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        val cursor = resolver.query(documentUri, CHILD_PROJECTION, null, null, null, cancellation)
            ?: throw IllegalStateException("SAF provider returned no root cursor")
        cursor.use {
            it.requireCompleteResults()
            if (!it.moveToFirst() ||
                it.getStringOrNull(DocumentsContract.Document.COLUMN_MIME_TYPE) !=
                DocumentsContract.Document.MIME_TYPE_DIR
            ) {
                throw RootUnavailableException("The selected SAF directory is no longer available")
            }
            val name = it.getStringOrNull(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            it.requireCompleteResults()
            return mapOf(
                "key" to locationKey(authority, documentId),
                "displayName" to (name?.takeIf { value -> value.isNotEmpty() } ?: documentId),
            )
        }
    }

    private fun requirePersistedReadGrant(treeUri: Uri) {
        if (resolver.persistedUriPermissions.none { it.uri == treeUri && it.isReadPermission }) {
            throw RootUnavailableException("SAF read permission was not persisted or was revoked")
        }
    }

    private fun readNextBatch(scan: TreeScan, result: MethodChannel.Result) {
        try {
            scan.cancellation.throwIfCanceled()
            requirePersistedReadGrant(scan.treeUri)
            val files = scan.nextBatch(resolver)
            scan.cancellation.throwIfCanceled()
            if (files.isEmpty()) {
                scans.remove(scan.id, scan)
                scan.close()
                complete(result, mapOf("type" to "complete"))
            } else {
                complete(result, mapOf("type" to "batch", "files" to files))
            }
        } catch (error: Exception) {
            val cancelled = scan.cancellation.isCanceled
            val rootUnavailable = !cancelled && (error is RootUnavailableException ||
                (error is SecurityException && !canReadRoot(scan.treeUri)))
            scans.remove(scan.id, scan)
            scan.close()
            fail(result, error, rootUnavailable, cancelled)
        } finally {
            scan.requestInFlight.set(false)
        }
    }

    private fun canReadRoot(treeUri: Uri): Boolean = try {
        describeTree(treeUri)
        true
    } catch (_: Exception) {
        false
    }

    private fun complete(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun fail(
        result: MethodChannel.Result,
        error: Exception,
        rootUnavailable: Boolean = error is SecurityException,
        cancelled: Boolean = error is OperationCanceledException,
    ) {
        mainHandler.post {
            result.error(
                when {
                    cancelled -> "scan_cancelled"
                    rootUnavailable -> "permission_revoked"
                    else -> "scan_failed"
                },
                error.message,
                null,
            )
        }
    }

    fun close() {
        if (closed) return
        closed = true
        methods.setMethodCallHandler(null)
        val active = scans.values.toList()
        scans.clear()
        active.forEach { it.cancellation.cancel() }
        worker.execute { active.forEach { it.close() } }
        worker.shutdown()
        metadataWorker.shutdown()
    }

    private class TreeScan(
        val id: String,
        val treeUri: Uri,
        private val extensions: Set<String>,
    ) {
        val cancellation = CancellationSignal()
        val requestInFlight = AtomicBoolean(false)
        private val directories = ArrayDeque<String>()
        private val visitedDirectories = HashSet<String>()
        private var cursor: Cursor? = null

        init {
            require(treeUri.scheme == "content" && !treeUri.authority.isNullOrEmpty()) {
                "A SAF content URI with an authority is required"
            }
            val rootDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
            directories.addLast(rootDocumentId)
            visitedDirectories.add(rootDocumentId)
        }

        fun nextBatch(resolver: ContentResolver): List<Map<String, Any?>> {
            val files = ArrayList<Map<String, Any?>>(BATCH_SIZE)
            while (files.size < BATCH_SIZE) {
                cancellation.throwIfCanceled()
                if (cursor == null) {
                    if (directories.isEmpty()) break
                    val uri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, directories.removeLast())
                    cursor = resolver.query(uri, CHILD_PROJECTION, null, null, null, cancellation)
                        ?: throw IllegalStateException("SAF provider returned no child cursor")
                    cursor?.requireCompleteResults()
                }
                val current = cursor ?: continue
                if (!current.moveToNext()) {
                    current.requireCompleteResults()
                    current.close()
                    cursor = null
                    continue
                }
                val documentId = current.getStringOrNull(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val name = current.getStringOrNull(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeType = current.getStringOrNull(DocumentsContract.Document.COLUMN_MIME_TYPE)
                check(!documentId.isNullOrEmpty() && !name.isNullOrEmpty() && !mimeType.isNullOrEmpty()) {
                    "SAF provider returned an incomplete document row"
                }
                if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                    if (visitedDirectories.add(documentId)) directories.addLast(documentId)
                    continue
                }
                val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
                if (extension !in extensions) continue
                val size = current.getLongOrNull(DocumentsContract.Document.COLUMN_SIZE)
                val modified = current.getLongOrNull(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                files.add(
                    mapOf(
                        "key" to locationKey(treeUri.authority.orEmpty(), documentId),
                        "locator" to DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId).toString(),
                        "fileName" to name,
                        "sizeBytes" to size?.takeIf { it >= 0 },
                        "modifiedMs" to modified?.takeIf { it > 0 },
                    ),
                )
            }
            cursor?.requireCompleteResults()
            return files
        }

        // Called only on the worker, including cancellation and engine teardown.
        fun close() {
            runCatching { cursor?.close() }
            cursor = null
            directories.clear()
            visitedDirectories.clear()
        }
    }
}
