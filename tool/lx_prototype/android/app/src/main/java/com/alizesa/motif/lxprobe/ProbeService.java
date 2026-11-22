package com.alizesa.motif.lxprobe;

import android.Manifest;
import android.app.Service;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Binder;
import android.os.IBinder;
import android.os.Process;
import android.os.RemoteException;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import java.io.FileDescriptor;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

public final class ProbeService extends Service {
    static final int RUN_FIXTURES = 1;
    static final int STALL_FIXTURE = 2;
    static final int STALL_STARTED = 8;
    private static final int ISOLATION_REJECTED = 10;
    private static final int RUNNER_FAILURE = 11;
    private static final int NO_OWNER = -1;

    private final AtomicInteger owner = new AtomicInteger(NO_OWNER);
    private final ScheduledExecutorService watchdog = Executors.newSingleThreadScheduledExecutor();
    private final IProbe.Stub endpoint = new IProbe.Stub() {
        @Override
        public void start(int fixture, String canary, int port, IProbeResult result) {
            final int caller = Binder.getCallingUid();
            if ((fixture != RUN_FIXTURES && fixture != STALL_FIXTURE)
                    || canary == null || canary.isEmpty() || canary.length() > 4096
                    || port < 1 || port > 65535 || result == null
                    || caller == Process.myUid() || !owner.compareAndSet(NO_OWNER, caller)) {
                return;
            }
            watchdog.schedule(ProbeService::stopProcess, 4, TimeUnit.SECONDS);
            new Thread(() -> runFixture(fixture, canary, port, result), "motif-lx-fixture").start();
        }

        @Override
        public void stop() {
            if (Binder.getCallingUid() == owner.get()) stopProcess();
        }
    };

    @Override
    public IBinder onBind(Intent intent) {
        return endpoint;
    }

    @Override
    public void onDestroy() {
        // The watchdog must remain able to reap a stalled worker even after
        // the controller has revoked its binding.
        if (owner.get() == NO_OWNER) watchdog.shutdownNow();
        super.onDestroy();
    }

    private void runFixture(int fixture, String canary, int port, IProbeResult result) {
        int code;
        try {
            if (checkSelfPermission(Manifest.permission.INTERNET) != PackageManager.PERMISSION_DENIED
                    || !canaryDenied(canary) || !loopbackDenied(port)) {
                code = ISOLATION_REJECTED;
            } else if (fixture == STALL_FIXTURE) {
                result.report(STALL_STARTED, Process.myUid());
                new CountDownLatch(1).await();
                return;
            } else {
                System.loadLibrary("motif_lx_probe");
                code = nativeRunFixture();
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            code = RUNNER_FAILURE;
        } catch (LinkageError | RuntimeException | RemoteException error) {
            code = RUNNER_FAILURE;
        }
        try {
            result.report(code, Process.myUid());
        } catch (RemoteException ignored) {
            stopProcess();
        }
    }

    private static boolean isAccessDenied(ErrnoException error) {
        return error.errno == OsConstants.EACCES || error.errno == OsConstants.EPERM;
    }

    private static boolean canaryDenied(String canary) {
        try {
            FileDescriptor fd = Os.open(canary, OsConstants.O_RDONLY, 0);
            Os.close(fd);
            return false;
        } catch (ErrnoException error) {
            return isAccessDenied(error);
        }
    }

    private static boolean loopbackDenied(int port) {
        FileDescriptor fd = null;
        try {
            fd = Os.socket(OsConstants.AF_INET, OsConstants.SOCK_STREAM, 0);
            Os.connect(fd, InetAddress.getByAddress(new byte[]{127, 0, 0, 1}), port);
            return false;
        } catch (ErrnoException error) {
            return isAccessDenied(error);
        } catch (UnknownHostException error) {
            return false;
        } finally {
            if (fd != null) {
                try {
                    Os.close(fd);
                } catch (ErrnoException ignored) {
                    // The watchdog still owns process cleanup.
                }
            }
        }
    }

    private static void stopProcess() {
        Process.killProcess(Process.myPid());
    }

    private static native int nativeRunFixture();
}
