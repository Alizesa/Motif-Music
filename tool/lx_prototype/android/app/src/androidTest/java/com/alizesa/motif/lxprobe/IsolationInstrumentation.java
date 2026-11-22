package com.alizesa.motif.lxprobe;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Binder;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Process;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

public final class IsolationInstrumentation extends Instrumentation {
    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    @Override
    public void onStart() {
        final Bundle result = new Bundle();
        int status = Activity.RESULT_CANCELED;
        try {
            runIsolationChecks();
            System.loadLibrary("motif_lx_probe");
            final int media = nativeRunMediaFixture();
            require(media == 0, "controlled libmpv fixture failed at gate " + media);
            result.putString("stream", "PASS Motif LX Android isolation and controlled media\n");
            status = Activity.RESULT_OK;
        } catch (Exception | LinkageError | AssertionError error) {
            result.putString("stream", "FAIL Motif LX Android isolation: " + error + "\n");
        }
        finish(status, result);
    }

    private void runIsolationChecks() throws Exception {
        final Context context = getTargetContext();
        final File canary = File.createTempFile("lx-probe-", ".tmp", context.getCacheDir());
        try {
            try (FileOutputStream stream = new FileOutputStream(canary)) {
                stream.write('M');
            }
            verifyHostCanary(canary);
            final InetAddress loopback = InetAddress.getByAddress(new byte[]{127, 0, 0, 1});
            try (ServerSocket listener = new ServerSocket(0, 1, loopback)) {
                final int port = listener.getLocalPort();
                runWorker(context, canary, port, ProbeService.RUN_FIXTURES, 0);
                runWorker(context, canary, port, ProbeService.STALL_FIXTURE, ProbeService.STALL_STARTED);
                runWorker(context, canary, port, ProbeService.RUN_FIXTURES, 0);
                runWorker(context, canary, port, ProbeService.PLAYBACK_FIXTURE, 0);
                runWorker(context, canary, port, ProbeService.PLAYBACK_TIMEOUT, ProbeService.PLAYBACK_TIMED_OUT);
            }
            verifyHostCanary(canary);
        } finally {
            require(canary.delete(), "could not remove host-only fixture");
        }
    }

    private static void verifyHostCanary(File canary) throws Exception {
        try (FileInputStream stream = new FileInputStream(canary)) {
            require(stream.read() == 'M', "host cannot read its own fixture");
        }
    }

    private static void runWorker(Context context, File canary, int port, int fixture, int expected)
            throws Exception {
        final CompletableFuture<IBinder> ready = new CompletableFuture<>();
        final ServiceConnection connection = new ServiceConnection() {
            @Override
            public void onServiceConnected(ComponentName name, IBinder binder) {
                ready.complete(binder);
            }

            @Override
            public void onServiceDisconnected(ComponentName name) {}

            @Override
            public void onNullBinding(ComponentName name) {
                ready.completeExceptionally(new IllegalStateException("No sandbox binding"));
            }
        };
        final Intent intent = new Intent().setClassName(context.getPackageName(),
                "com.alizesa.motif.lxprobe.ProbeService");
        require(context.bindService(intent, connection, Context.BIND_AUTO_CREATE),
                "could not bind test service");
        try {
            final IBinder binder = ready.get(10, TimeUnit.SECONDS);
            final CompletableFuture<Void> exited = new CompletableFuture<>();
            final IBinder.DeathRecipient recipient = () -> exited.complete(null);
            binder.linkToDeath(recipient, 0);
            try {
                final IProbe worker = IProbe.Stub.asInterface(binder);
                final CompletableFuture<Integer> outcome = new CompletableFuture<>();
                final AtomicInteger catalogUid = new AtomicInteger();
                worker.start(fixture,
                        canary.getAbsolutePath(), port, new IProbeResult.Stub() {
                            @Override
                            public void report(int code, int isolatedUid) {
                                if (isolatedUid > 0 && isolatedUid != Process.myUid()
                                        && isolatedUid == Binder.getCallingUid()
                                        && (fixture != ProbeService.PLAYBACK_FIXTURE
                                        || catalogUid.get() == isolatedUid)) {
                                    outcome.complete(code);
                                } else {
                                    outcome.completeExceptionally(
                                            new IllegalStateException("Worker ran under app UID"));
                                }
                            }
                        }, new IFixtureCatalog.Stub() {
                            @Override
                            public int query(int request) {
                                final int uid = Binder.getCallingUid();
                                return fixture == ProbeService.PLAYBACK_FIXTURE && request == 1
                                        && uid != Process.myUid() && uid > 0
                                        && catalogUid.compareAndSet(0, uid) ? 1 : -1;
                            }
                        });
                final int code = outcome.get(8, TimeUnit.SECONDS);
                require(code == expected,
                        "sandbox or fixed QuickJS test returned " + code);
                if (fixture != ProbeService.STALL_FIXTURE) worker.stop();
                // Unbind and onServiceDisconnected are not evidence of exit.
                exited.get(8, TimeUnit.SECONDS);
            } finally {
                if (binder.isBinderAlive()) binder.unlinkToDeath(recipient, 0);
            }
        } finally {
            context.unbindService(connection);
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static native int nativeRunMediaFixture();
}
