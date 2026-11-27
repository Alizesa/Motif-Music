package com.alizesa.motif.downloads;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.Intent;
import android.content.UriPermission;
import android.database.Cursor;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.system.ErrnoException;
import android.system.OsConstants;
import android.provider.DocumentsContract;

import java.io.Closeable;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Writes only to a user-selected SAF tree. No storage-wide permission. */
public final class SafDownloadBridge implements AutoCloseable {
    private static final int PICK_DIRECTORY = 19780;
    private final Activity activity;
    private final MethodChannel channel;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Map<String, Job> jobs = new ConcurrentHashMap<>();
    private MethodChannel.Result picking;
    private volatile boolean closed;

    public SafDownloadBridge(Activity activity, BinaryMessenger messenger) {
        this.activity = activity;
        channel = new MethodChannel(messenger, "motif/downloads");
        channel.setMethodCallHandler(this::handle);
    }

    private void handle(MethodCall call, MethodChannel.Result result) {
        if (closed) { result.error("download_closed", "Downloads closed", null); return; }
        if (call.method.equals("pickDirectory")) {
            if (picking != null) { result.error("download_busy", "Picker busy", null); return; }
            picking = result;
            try {
                activity.startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION), PICK_DIRECTORY);
            } catch (Exception ignored) {
                picking = null;
                result.error("download_directory", "Directory unavailable", null);
            }
            return;
        }
        if (call.method.equals("abort")) {
            Job job = jobs.get(call.argument("id"));
            if (job != null) { job.cancelled = true; closeQuietly(job.stream); closeQuietly(job.copying); }
        }
        io.execute(() -> {
            try {
                if (closed) throw new IllegalStateException();
                Object value;
                switch (call.method) {
                    case "restoreDirectory": value = restore(tree(call.argument("directory"))); break;
                    case "begin": value = begin(call.argument("directory")); break;
                    case "write":
                        Job job = get(call.argument("id"));
                        byte[] bytes = call.argument("bytes");
                        if (bytes == null || bytes.length > 32768 || job.received + bytes.length > 512L * 1024 * 1024) {
                            throw new IllegalArgumentException();
                        }
                        job.stream.write(bytes);
                        job.received += bytes.length;
                        value = null;
                        break;
                    case "finish": value = finish(call.argument("id"), call.argument("name"), call.argument("extension")); break;
                    case "abort":
                        Job aborted = jobs.remove(call.argument("id"));
                        if (aborted != null) cleanup(aborted);
                        value = null;
                        break;
                    default: main.post(result::notImplemented); return;
                }
                main.post(() -> result.success(value));
            } catch (Exception error) {
                report(result, error);
            }
        });
    }

    public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != PICK_DIRECTORY) return false;
        MethodChannel.Result result = picking;
        picking = null;
        if (result == null) return true;
        if (resultCode != Activity.RESULT_OK || data == null || data.getData() == null) {
            result.success(null);
            return true;
        }
        Uri uri = data.getData();
        io.execute(() -> {
            try {
                if (closed) throw new IllegalStateException();
                Uri tree = tree(uri.toString());
                int mode = data.getFlags() & (Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
                if ((mode & Intent.FLAG_GRANT_WRITE_URI_PERMISSION) == 0) throw new SecurityException();
                // Inspect with the picker's temporary grant first. A cancelled or
                // unusable selection must not replace the previous directory.
                Map<String, Object> details = describe(tree, (mode & Intent.FLAG_GRANT_READ_URI_PERMISSION) != 0);
                activity.getContentResolver().takePersistableUriPermission(tree, mode);
                writeGrant(tree);
                main.post(() -> result.success(details));
            } catch (Exception error) {
                report(result, error);
            }
        });
        return true;
    }

    private static Uri tree(String locator) throws DirectoryUnavailable {
        if (locator == null) throw new DirectoryUnavailable();
        Uri tree = Uri.parse(locator);
        if (!ContentResolver.SCHEME_CONTENT.equals(tree.getScheme()) || tree.getAuthority() == null
                || !DocumentsContract.isTreeUri(tree)) throw new DirectoryUnavailable();
        return tree;
    }

    private UriPermission writeGrant(Uri tree) {
        for (UriPermission p : activity.getContentResolver().getPersistedUriPermissions()) {
            if (p.getUri().equals(tree) && p.isWritePermission()) return p;
        }
        throw new SecurityException();
    }

    private Map<String, Object> restore(Uri tree) throws IOException {
        return describe(tree, writeGrant(tree).isReadPermission());
    }

    private Map<String, Object> describe(Uri tree, boolean canRead) throws IOException {
        String label = "所选下载目录";
        if (canRead) {
            String[] columns = {DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_FLAGS};
            try (Cursor c = activity.getContentResolver().query(root(tree), columns, null, null, null)) {
                if (c == null) throw new IOException();
                if (!c.moveToFirst()) throw new DirectoryUnavailable();
                int type = c.getColumnIndex(columns[1]);
                if (type >= 0 && !c.isNull(type) && !DocumentsContract.Document.MIME_TYPE_DIR.equals(c.getString(type))) {
                    throw new DirectoryUnavailable();
                }
                int flags = c.getColumnIndex(columns[2]);
                if (flags >= 0 && !c.isNull(flags) && (c.getInt(flags) & DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE) == 0) {
                    throw new SecurityException();
                }
                int name = c.getColumnIndex(columns[0]);
                if (name >= 0 && !c.isNull(name)) label = c.getString(name);
            }
        }
        Map<String, Object> details = new HashMap<>();
        details.put("uri", tree.toString());
        details.put("label", label);
        return details;
    }

    private String begin(String directory) throws IOException {
        if (!jobs.isEmpty()) throw new IllegalStateException();
        Uri tree = tree(directory);
        restore(tree); // Check again before any source request, even within the same session.
        String id = UUID.randomUUID().toString();
        // The provider only needs to create the final audio document. In
        // particular, don't require it to expose a readable/deletable .part.
        File cache = activity.getCacheDir();
        if (cache == null) throw new IOException();
        File temporary = File.createTempFile("motif-download-", ".part", cache);
        try {
            jobs.put(id, new Job(tree, temporary, new FileOutputStream(temporary)));
            return id;
        } catch (IOException | RuntimeException error) {
            temporary.delete();
            throw error;
        }
    }

    private Map<String, Object> finish(String id, String name, String extension) throws Exception {
        Job job = get(id);
        if (name == null || name.length() > 201 || name.isEmpty() || name.startsWith(".")
            || name.matches("(?s).*[<>:\"/\\\\|?*\\p{Cntrl}].*") || !name.equals(name.trim())) throw new IllegalArgumentException();
        String mime;
        switch (extension) {
            case "mp3": mime = "audio/mpeg"; break;
            case "flac": mime = "audio/flac"; break;
            case "wav": mime = "audio/wav"; break;
            default: throw new IllegalArgumentException();
        }
        job.stream.flush();
        job.stream.close();
        // SAF createDocument creates a new document and resolves name collisions.
        // Never open a pre-existing target with "w", or use overwrite-style rename.
        UriPermission grant = writeGrant(job.tree);
        ContentResolver resolver = activity.getContentResolver();
        Uri target = DocumentsContract.createDocument(resolver, root(job.tree), mime, name + "." + extension);
        if (target == null) throw new IOException();
        // Only this newly created document can ever be removed by abort().
        job.partialTarget = target;
        try (InputStream input = new FileInputStream(job.temporary);
             OutputStream output = resolver.openOutputStream(target, "w")) {
            if (output == null) throw new IOException();
            job.copying = output;
            byte[] buffer = new byte[32768];
            long copied = 0;
            int count;
            while ((count = input.read(buffer)) != -1) {
                if (closed || job.cancelled) throw new IllegalStateException();
                copied += count;
                if (copied > job.received) throw new IOException();
                output.write(buffer, 0, count);
            }
            if (copied != job.received || copied == 0) throw new IOException();
            output.flush();
        } finally { job.copying = null; }
        if (closed || job.cancelled) throw new IllegalStateException();
        Map<String, Object> receipt = new HashMap<>();
        receipt.put("name", grant.isReadPermission() ? displayName(target) : "已保存音频文件");
        receipt.put("location", target.toString());
        if (closed || job.cancelled) throw new IllegalStateException();
        job.partialTarget = null;
        jobs.remove(id);
        job.temporary.delete(); // Cache cleanup must not invalidate an already committed document.
        return receipt;
    }

    private Job get(String id) {
        Job job = jobs.get(id);
        if (job == null || job.cancelled || closed) throw new IllegalStateException();
        return job;
    }

    private Uri root(Uri tree) {
        return DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree));
    }

    private String displayName(Uri document) {
        try (Cursor cursor = activity.getContentResolver().query(document,
            new String[] {DocumentsContract.Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) return cursor.getString(0);
        } catch (RuntimeException ignored) { /* Some providers don't expose a display name. */ }
        return "已保存音频文件";
    }

    private void cleanup(Job job) throws Exception {
        closeQuietly(job.stream);
        closeQuietly(job.copying);
        try {
            if (job.partialTarget != null && !DocumentsContract.deleteDocument(activity.getContentResolver(), job.partialTarget)) {
                throw new IOException();
            }
        } finally {
            if (job.temporary.exists() && !job.temporary.delete()) throw new IOException();
        }
    }

    private static void closeQuietly(Closeable stream) {
        if (stream != null) try { stream.close(); } catch (Exception ignored) { }
    }

    @Override public void close() {
        if (closed) return;
        closed = true;
        channel.setMethodCallHandler(null);
        if (picking != null) { picking.success(null); picking = null; }
        for (Job job : jobs.values()) {
            job.cancelled = true;
            closeQuietly(job.stream);
            closeQuietly(job.copying);
        }
        io.execute(() -> {
            for (Job job : jobs.values()) try { cleanup(job); } catch (Exception ignored) { }
            jobs.clear();
        });
        io.shutdown();
    }

    private static final class DirectoryUnavailable extends IOException { }

    private void report(MethodChannel.Result result, Exception error) {
        String code = "download_io";
        for (Throwable e = error; e != null; e = e.getCause()) {
            if (e instanceof SecurityException) { code = "download_permission"; break; }
            if (e instanceof DirectoryUnavailable) { code = "download_unavailable"; break; }
            if (e instanceof ErrnoException) {
                int errno = ((ErrnoException) e).errno;
                if (errno == OsConstants.ENOSPC || errno == OsConstants.EDQUOT) code = "download_space";
                if (errno == OsConstants.EACCES || errno == OsConstants.EPERM || errno == OsConstants.EROFS) code = "download_permission";
                break;
            }
        }
        final String safeCode = code;
        main.post(() -> result.error(safeCode, "Download destination unavailable", null));
    }

    private static final class Job {
        final Uri tree;
        final File temporary;
        final OutputStream stream;
        Uri partialTarget;
        volatile Closeable copying;
        volatile boolean cancelled;
        long received;
        Job(Uri tree, File temporary, OutputStream stream) {
            this.tree = tree; this.temporary = temporary; this.stream = stream;
        }
    }
}
