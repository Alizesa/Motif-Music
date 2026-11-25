package com.alizesa.motif.lx;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.database.Cursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Process;
import android.os.RemoteException;
import android.provider.OpenableColumns;
import com.alizesa.motif.lxprobe.IFixtureCatalog;
import com.alizesa.motif.lxprobe.IProbe;
import com.alizesa.motif.lxprobe.IProbeResult;
import com.alizesa.motif.lxprobe.IScriptBroker;
import com.alizesa.motif.lxprobe.ProbeService;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.util.Arrays;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

public final class LxFixtureBridge implements AutoCloseable {
    private static final int SCRIPT_LIMIT = 768 * 1024;
    private static final int MESSAGE_LIMIT = 64 * 1024;
    private static final int PART_BYTES = 32 * 1024;
    private static final int PICK_SCRIPT = 9413;
    private final Activity activity;
    private final Context context;
    private final MethodChannel channel;
    private final Handler main = new Handler(Looper.getMainLooper());
    // Service ownership is shared across Flutter activity recreation.
    private static Run active;
    private MethodChannel.Result picking;

    public LxFixtureBridge(Activity activity, BinaryMessenger messenger) {
        this.activity = activity;
        this.context = activity.getApplicationContext();
        channel = new MethodChannel(messenger, "motif/lx_fixture");
        channel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "run":
                    if (!(call.arguments instanceof Boolean)) {
                        result.error("fixture-argument", null, null);
                    } else if (active != null) {
                        result.error("fixture-busy", null, null);
                    } else {
                        active = new Run((Boolean) call.arguments, result);
                        active.begin();
                    }
                    break;
                case "cancel":
                    if (active != null && active.ownedBy(this)) active.stop("fixture-cancelled");
                    result.success(null);
                    break;
                case "runScript":
                    if (active != null) {
                        result.error("fixture-busy", null, null);
                    } else if (!(call.arguments instanceof Map)) {
                        result.error("fixture-argument", null, null);
                    } else {
                        final Map<?, ?> args = (Map<?, ?>) call.arguments;
                        final Object script = args.get("script");
                        final Object parameters = args.get("parameters");
                        if (!validBytes(script, SCRIPT_LIMIT)
                                || !validBytes(parameters, MESSAGE_LIMIT)) {
                            result.error("fixture-argument", null, null);
                        } else {
                            active = new Run(false, result, (byte[]) script, (byte[]) parameters);
                            active.begin();
                        }
                    }
                    break;
                case "pickScript":
                    if (picking != null) {
                        result.error("fixture-busy", null, null);
                        break;
                    }
                    picking = result;
                    try {
                        activity.startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT)
                                .addCategory(Intent.CATEGORY_OPENABLE)
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                .setType("*/*"), PICK_SCRIPT);
                    } catch (RuntimeException error) {
                        picking = null;
                        result.error("pick-unavailable", null, null);
                    }
                    break;
                default:
                    result.notImplemented();
            }
        });
    }

    @Override
    public void close() {
        channel.setMethodCallHandler(null);
        if (active != null && active.ownedBy(this)) active.stop("fixture-cancelled");
        if (picking != null) picking.success(null);
        picking = null;
    }

    private static boolean validBytes(Object value, int maximum) {
        return value instanceof byte[] && ((byte[]) value).length > 0
                && ((byte[]) value).length <= maximum;
    }

    public boolean onActivityResult(int code, int status, Intent data) {
        if (code != PICK_SCRIPT) return false;
        final MethodChannel.Result result = picking;
        if (result == null) return true;
        final Uri uri = status == Activity.RESULT_OK && data != null ? data.getData() : null;
        if (uri == null) {
            picking = null;
            result.success(null);
            return true;
        }
        new Thread(() -> {
            byte[] bytes = null;
            try {
                bytes = readDocument(uri);
            } catch (IOException | RuntimeException ignored) {}
            final byte[] document = bytes;
            main.post(() -> {
                if (picking != result) return;
                picking = null;
                if (validBytes(document, SCRIPT_LIMIT)) result.success(document);
                else result.error("pick-invalid", null, null);
            });
        }, "motif-lx-import").start();
        return true;
    }

    private byte[] readDocument(Uri uri) throws IOException {
        if (!"content".equals(uri.getScheme())) return null;
        try (Cursor cursor = context.getContentResolver().query(uri,
                new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor == null || !cursor.moveToFirst()) return null;
            final int column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
            final String name = column < 0 ? null : cursor.getString(column);
            if (name == null || !name.toLowerCase(Locale.ROOT).endsWith(".js")) return null;
        }
        try (InputStream input = context.getContentResolver().openInputStream(uri)) {
            if (input == null) return null;
            final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            final byte[] chunk = new byte[PART_BYTES];
            int count;
            while ((count = input.read(chunk)) > 0) {
                if (bytes.size() + count > SCRIPT_LIMIT) return null;
                bytes.write(chunk, 0, count);
            }
            return bytes.toByteArray();
        }
    }

    private final class Run implements ServiceConnection {
        private final boolean timeoutFixture;
        private final MethodChannel.Result result;
        private final Runnable deadline = this::timedOut;
        private final IBinder.DeathRecipient death = () -> main.post(this::exited);
        private final AtomicInteger catalogUid = new AtomicInteger();
        private final AtomicInteger scriptCalls = new AtomicInteger();
        private final AtomicReference<byte[]> scriptReply = new AtomicReference<>();
        private final byte[] script;
        private final byte[] parameters;
        private volatile boolean admitCatalog;
        private IBinder binder;
        private IProbe worker;
        private File canary;
        private ServerSocket listener;
        private boolean bound;
        private boolean started;
        private boolean finished;
        private boolean replied;
        private Integer outcome;
        private String failure;

        Run(boolean timeoutFixture, MethodChannel.Result result) {
            this(timeoutFixture, result, null, null);
        }

        Run(boolean timeoutFixture, MethodChannel.Result result, byte[] script, byte[] parameters) {
            this.timeoutFixture = timeoutFixture;
            this.result = result;
            this.script = script;
            this.parameters = parameters;
        }

        boolean ownedBy(LxFixtureBridge bridge) {
            return LxFixtureBridge.this == bridge;
        }

        void begin() {
            try {
                canary = File.createTempFile("lx-app-fixture-", ".tmp", context.getCacheDir());
                try (FileOutputStream file = new FileOutputStream(canary)) {
                    file.write('M');
                }
                if (!verifyCanary()) throw new IOException("fixture canary");
                listener = new ServerSocket(0, 1,
                        InetAddress.getByAddress(new byte[]{127, 0, 0, 1}));
                main.postDelayed(deadline, script == null ? 8000 : 36500);
                bound = context.bindService(new Intent(context, ProbeService.class),
                        this, Context.BIND_AUTO_CREATE);
                if (!bound) stop("fixture-unavailable");
            } catch (IOException | RuntimeException error) {
                stop("fixture-unavailable");
            }
        }

        @Override
        public void onServiceConnected(ComponentName name, IBinder service) {
            if (finished) return;
            binder = service;
            worker = IProbe.Stub.asInterface(service);
            try {
                binder.linkToDeath(death, 0);
                admitCatalog = !timeoutFixture;
                started = true;
                final IProbeResult report = new IProbeResult.Stub() {
                            @Override
                            public void report(int code, int uid) {
                                final boolean verified = uid > 0 && uid != Process.myUid()
                                        && Binder.getCallingUid() == uid
                                        && (timeoutFixture ? catalogUid.get() == 0 : catalogUid.get() == uid);
                                main.post(() -> {
                                    if (finished || failure != null || outcome != null) return;
                                    if (verified) {
                                        outcome = code;
                                        stop(null);
                                    } else {
                                        stop("fixture-isolation");
                                    }
                                });
                            }
                        };
                if (script != null) {
                    worker.startScript(canary.getAbsolutePath(), listener.getLocalPort(), report,
                            scriptBroker());
                    return;
                }
                worker.start(timeoutFixture ? ProbeService.PLAYBACK_TIMEOUT
                                : ProbeService.PLAYBACK_FIXTURE,
                        canary.getAbsolutePath(), listener.getLocalPort(), report, new IFixtureCatalog.Stub() {
                            @Override
                            public int query(int request) {
                                final int uid = Binder.getCallingUid();
                                return admitCatalog && request == 1 && uid > 0
                                        && uid != Process.myUid() && catalogUid.compareAndSet(0, uid)
                                        ? 1 : -1;
                            }
                        });
            } catch (RemoteException | RuntimeException error) {
                stop("fixture-unavailable");
                if (!binder.isBinderAlive()) exited();
            }
        }

        private IScriptBroker scriptBroker() {
            return new IScriptBroker.Stub() {
                private boolean fromWorker() {
                    return admitCatalog && Binder.getCallingUid() == catalogUid.get();
                }

                @Override
                public byte[] part(int index) {
                    final int uid = Binder.getCallingUid();
                    if (!admitCatalog || uid <= 0 || uid == Process.myUid()) return null;
                    if (index == -1 && catalogUid.compareAndSet(0, uid)) return parameters;
                    if (!fromWorker() || index < 0 || index > SCRIPT_LIMIT / PART_BYTES) return null;
                    final int from = index * PART_BYTES;
                    if (from >= script.length) return new byte[0];
                    return Arrays.copyOfRange(script, from, Math.min(from + PART_BYTES, script.length));
                }

                @Override
                public byte[] request(byte[] message) {
                    if (!fromWorker() || !validBytes(message, MESSAGE_LIMIT)
                            || scriptCalls.incrementAndGet() > 2400) return null;
                    final CountDownLatch ready = new CountDownLatch(1);
                    final AtomicReference<byte[]> reply = new AtomicReference<>();
                    main.post(() -> {
                        if (!admitCatalog) {
                            ready.countDown();
                            return;
                        }
                        channel.invokeMethod("scriptRequest", message, new MethodChannel.Result() {
                            @Override public void success(Object value) {
                                if (validBytes(value, MESSAGE_LIMIT)) reply.set((byte[]) value);
                                ready.countDown();
                            }
                            @Override public void error(String code, String message, Object details) {
                                ready.countDown();
                            }
                            @Override public void notImplemented() { ready.countDown(); }
                        });
                    });
                    try {
                        return ready.await(4, TimeUnit.SECONDS) && admitCatalog ? reply.get() : null;
                    } catch (InterruptedException error) {
                        Thread.currentThread().interrupt();
                        return null;
                    }
                }

                @Override
                public void publish(byte[] message) {
                    if (fromWorker() && validBytes(message, MESSAGE_LIMIT)) {
                        scriptReply.compareAndSet(null, message);
                    }
                }
            };
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            // Wait for the registered death notification before reusing the slot.
            if (binder == null) stop("fixture-unavailable");
        }

        @Override
        public void onNullBinding(ComponentName name) {
            stop("fixture-unavailable");
        }

        @Override
        public void onBindingDied(ComponentName name) {
            if (binder == null || !binder.isBinderAlive()) exited();
        }

        void stop(String reason) {
            if (finished) return;
            if (reason != null && failure == null) failure = reason;
            admitCatalog = false;
            if (!started) {
                exited();
                return;
            }
            try {
                worker.stop();
            } catch (RemoteException ignored) {
                // Binder death or the isolate watchdog will complete cleanup.
            }
        }

        private void timedOut() {
            stop("fixture-timeout");
            if (!replied) {
                replied = true;
                result.error("fixture-timeout", null, null);
            }
            // An unresolved binding keeps its slot until death is observed.
        }

        private boolean verifyCanary() throws IOException {
            try (FileInputStream file = new FileInputStream(canary)) {
                return file.read() == 'M';
            }
        }

        private void exited() {
            if (finished) return;
            finished = true;
            admitCatalog = false;
            main.removeCallbacks(deadline);
            if (bound) context.unbindService(this);
            if (listener != null) {
                try {
                    listener.close();
                } catch (IOException ignored) {
                    // The worker is already gone.
                }
            }
            boolean canaryPresent = false;
            if (canary != null) {
                try {
                    canaryPresent = verifyCanary();
                } catch (IOException ignored) {}
                if (!canary.delete()) canaryPresent = false;
            }
            active = null;
            if (replied) return;
            replied = true;
            final int expected = timeoutFixture ? ProbeService.PLAYBACK_TIMED_OUT : 0;
            if (failure == null && outcome != null && outcome == expected && canaryPresent) {
                if (script != null && scriptReply.get() == null) {
                    result.error("fixture-isolation", null, null);
                } else {
                    result.success(script != null ? scriptReply.get()
                            : timeoutFixture ? "MOTIF_LX_TIMEOUT" : "MOTIF_LX_FIXED_WAVE");
                }
            } else {
                result.error(failure != null ? failure : "fixture-isolation", null, null);
            }
        }
    }
}
