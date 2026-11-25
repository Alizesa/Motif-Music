package com.alizesa.motif.downloads;

import android.app.Activity;
import android.content.Intent;
import android.content.UriPermission;
import android.database.Cursor;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;

import java.io.Closeable;
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
            } catch (Exception ignored) {
                main.post(() -> result.error("download_io", "Cannot save download", null));
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
                if (closed || !DocumentsContract.isTreeUri(uri)) throw new IllegalArgumentException();
                int mode = data.getFlags() & (Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
                if ((mode & Intent.FLAG_GRANT_WRITE_URI_PERMISSION) == 0) throw new SecurityException();
                activity.getContentResolver().takePersistableUriPermission(uri, mode);
                Map<String, Object> details = new HashMap<>();
                details.put("uri", uri.toString());
                details.put("label", displayName(root(uri)));
                main.post(() -> result.success(details));
            } catch (Exception ignored) {
                main.post(() -> result.error("download_directory", "Directory unavailable", null));
            }
        });
        return true;
    }

    private String begin(String directory) throws Exception {
        if (!jobs.isEmpty()) throw new IllegalStateException();
        Uri tree = Uri.parse(directory);
        boolean granted = false;
        for (UriPermission permission : activity.getContentResolver().getPersistedUriPermissions()) {
            if (permission.getUri().equals(tree) && permission.isReadPermission() && permission.isWritePermission()) granted = true;
        }
        if (!granted || !DocumentsContract.isTreeUri(tree)) throw new SecurityException();
        String id = UUID.randomUUID().toString();
        Uri parent = root(tree);
        Uri temporary = DocumentsContract.createDocument(activity.getContentResolver(), parent,
            "application/octet-stream", ".motif-" + id + ".part");
        if (temporary == null) throw new IllegalStateException();
        try {
            ParcelFileDescriptor descriptor = activity.getContentResolver().openFileDescriptor(temporary, "w");
            if (descriptor == null) throw new IllegalStateException();
            jobs.put(id, new Job(parent, temporary, new ParcelFileDescriptor.AutoCloseOutputStream(descriptor)));
            return id;
        } catch (Exception error) {
            DocumentsContract.deleteDocument(activity.getContentResolver(), temporary);
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
        Uri target = DocumentsContract.createDocument(activity.getContentResolver(), job.parent, mime, name + "." + extension);
        if (target == null) throw new IllegalStateException();
        boolean complete = false;
        try {
            ParcelFileDescriptor descriptor = activity.getContentResolver().openFileDescriptor(target, "w");
            if (descriptor == null) throw new IllegalStateException();
            try (InputStream input = activity.getContentResolver().openInputStream(job.temporary);
                 OutputStream output = new ParcelFileDescriptor.AutoCloseOutputStream(descriptor)) {
                job.copying = output;
                byte[] buffer = new byte[32768];
                long copied = 0;
                int count;
                if (input == null) throw new IllegalStateException();
                while ((count = input.read(buffer)) != -1) {
                    if (closed || job.cancelled) throw new IllegalStateException();
                    copied += count;
                    if (copied > job.received) throw new IllegalStateException();
                    output.write(buffer, 0, count);
                }
                if (copied != job.received || copied == 0) throw new IllegalStateException();
                output.flush();
            } finally { job.copying = null; }
            if (closed || job.cancelled) throw new IllegalStateException();
            Map<String, Object> receipt = new HashMap<>();
            receipt.put("name", displayName(target));
            receipt.put("location", target.toString());
            if (!DocumentsContract.deleteDocument(activity.getContentResolver(), job.temporary)) throw new IllegalStateException();
            complete = true;
            jobs.remove(id);
            return receipt;
        } finally {
            if (!complete) DocumentsContract.deleteDocument(activity.getContentResolver(), target);
        }
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
        }
        return "下载目录";
    }

    private void cleanup(Job job) throws Exception {
        closeQuietly(job.stream);
        closeQuietly(job.copying);
        if (!DocumentsContract.deleteDocument(activity.getContentResolver(), job.temporary)) throw new IllegalStateException();
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

    private static final class Job {
        final Uri parent;
        final Uri temporary;
        final OutputStream stream;
        volatile Closeable copying;
        volatile boolean cancelled;
        long received;
        Job(Uri parent, Uri temporary, OutputStream stream) {
            this.parent = parent; this.temporary = temporary; this.stream = stream;
        }
    }
}
