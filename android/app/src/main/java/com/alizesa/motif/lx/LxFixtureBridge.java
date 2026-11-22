package com.alizesa.motif.lx;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Binder;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Process;
import android.os.RemoteException;
import com.alizesa.motif.lxprobe.IFixtureCatalog;
import com.alizesa.motif.lxprobe.IProbe;
import com.alizesa.motif.lxprobe.IProbeResult;
import com.alizesa.motif.lxprobe.ProbeService;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.util.concurrent.atomic.AtomicInteger;

public final class LxFixtureBridge implements AutoCloseable {
    private final Context context;
    private final MethodChannel channel;
    private final Handler main = new Handler(Looper.getMainLooper());
    // Service ownership is shared across Flutter activity recreation.
    private static Run active;

    public LxFixtureBridge(Context context, BinaryMessenger messenger) {
        this.context = context.getApplicationContext();
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
                default:
                    result.notImplemented();
            }
        });
    }

    @Override
    public void close() {
        channel.setMethodCallHandler(null);
        if (active != null && active.ownedBy(this)) active.stop("fixture-cancelled");
    }

    private final class Run implements ServiceConnection {
        private final boolean timeoutFixture;
        private final MethodChannel.Result result;
        private final Runnable deadline = this::timedOut;
        private final IBinder.DeathRecipient death = () -> main.post(this::exited);
        private final AtomicInteger catalogUid = new AtomicInteger();
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
            this.timeoutFixture = timeoutFixture;
            this.result = result;
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
                main.postDelayed(deadline, 8000);
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
                worker.start(timeoutFixture ? ProbeService.PLAYBACK_TIMEOUT
                                : ProbeService.PLAYBACK_FIXTURE,
                        canary.getAbsolutePath(), listener.getLocalPort(), new IProbeResult.Stub() {
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
                        }, new IFixtureCatalog.Stub() {
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
                result.success(timeoutFixture ? "MOTIF_LX_TIMEOUT" : "MOTIF_LX_FIXED_WAVE");
            } else {
                result.error(failure != null ? failure : "fixture-isolation", null, null);
            }
        }
    }
}
