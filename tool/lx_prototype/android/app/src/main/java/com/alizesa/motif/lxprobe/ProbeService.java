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
import android.util.Log;
import java.io.ByteArrayOutputStream;
import java.io.FileDescriptor;
import java.net.InetAddress;
import java.net.SocketException;
import java.net.UnknownHostException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

public final class ProbeService extends Service {
    public static final int SCRIPT_WATCHDOG_SECONDS = 30;
    static final int RUN_FIXTURES = 1;
    static final int STALL_FIXTURE = 2;
    public static final int PLAYBACK_FIXTURE = 3;
    public static final int PLAYBACK_TIMEOUT = 4;
    static final int STALL_STARTED = 8;
    public static final int PLAYBACK_TIMED_OUT = 90;
    private static final int INTERNET_PERMISSION_GRANTED = 10;
    private static final int RUNNER_FAILURE = 11;
    private static final int CANARY_ACCESS_UNVERIFIED = 12;
    private static final int LOOPBACK_ACCESS_UNVERIFIED = 13;
    private static final int NO_OWNER = -1;
    private static final int SCRIPT_LIMIT = 768 * 1024;
    private static final int MESSAGE_LIMIT = 64 * 1024;
    private static final int PART_BYTES = 32 * 1024;

    private final AtomicInteger owner = new AtomicInteger(NO_OWNER);
    private final ScheduledExecutorService watchdog = Executors.newSingleThreadScheduledExecutor();
    private final IProbe.Stub endpoint = new IProbe.Stub() {
        @Override
        public void start(int fixture, String canary, int port, IProbeResult result,
                          IFixtureCatalog catalog) {
            final int caller = Binder.getCallingUid();
            if (fixture < RUN_FIXTURES || fixture > PLAYBACK_TIMEOUT
                    || (fixture >= PLAYBACK_FIXTURE && catalog == null)
                    || canary == null || canary.isEmpty() || canary.length() > 4096
                    || port < 1 || port > 65535 || result == null
                    || caller == Process.myUid() || !owner.compareAndSet(NO_OWNER, caller)) {
                return;
            }
            watchdog.schedule(ProbeService::stopProcess, 4, TimeUnit.SECONDS);
            new Thread(() -> runFixture(fixture, canary, port, result, catalog),
                    "motif-lx-fixture").start();
        }

        @Override
        public void stop() {
            if (Binder.getCallingUid() == owner.get()) stopProcess();
        }

        @Override
        public void startScript(String canary, int port, IProbeResult result,
                                IScriptBroker broker) {
            final int caller = Binder.getCallingUid();
            if (canary == null || canary.isEmpty() || canary.length() > 4096
                    || port < 1 || port > 65535 || result == null || broker == null
                    || caller == Process.myUid() || !owner.compareAndSet(NO_OWNER, caller)) {
                return;
            }
            watchdog.schedule(ProbeService::stopProcess, SCRIPT_WATCHDOG_SECONDS, TimeUnit.SECONDS);
            new Thread(() -> runScript(canary, port, result, broker),
                    "motif-lx-script").start();
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

    private void runFixture(int fixture, String canary, int port, IProbeResult result,
                            IFixtureCatalog catalog) {
        int code;
        try {
            code = checkIsolation(canary, port);
            if (code == 0) {
                if (fixture == STALL_FIXTURE) {
                    result.report(STALL_STARTED, Process.myUid());
                    new CountDownLatch(1).await();
                    return;
                }
                System.loadLibrary("motif_lx_probe");
                code = fixture >= PLAYBACK_FIXTURE
                        ? nativePlayback(fixture == PLAYBACK_TIMEOUT, catalog)
                        : nativeRunFixture();
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

    private void runScript(String canary, int port, IProbeResult result, IScriptBroker broker) {
        int code;
        try {
            code = checkIsolation(canary, port);
            if (code == 0) {
                System.loadLibrary("motif_lx_probe");
                final byte[] parameters = broker.part(-1);
                final ByteArrayOutputStream script = new ByteArrayOutputStream();
                boolean ended = false;
                for (int index = 0; index <= SCRIPT_LIMIT / PART_BYTES; index++) {
                    final byte[] part = broker.part(index);
                    if (part == null || part.length > PART_BYTES
                            || script.size() + part.length > SCRIPT_LIMIT) break;
                    if (part.length == 0) {
                        ended = true;
                        break;
                    }
                    script.write(part, 0, part.length);
                }
                code = RUNNER_FAILURE;
                if (ended && script.size() != 0 && parameters != null
                        && parameters.length != 0 && parameters.length <= MESSAGE_LIMIT) {
                    final byte[] reply = nativeScript(script.toByteArray(), parameters, broker);
                    if (reply != null && reply.length != 0 && reply.length <= MESSAGE_LIMIT) {
                        broker.publish(reply);
                        code = 0;
                    }
                }
            }
        } catch (LinkageError | RuntimeException | RemoteException error) {
            code = RUNNER_FAILURE;
        }
        try {
            result.report(code, Process.myUid());
        } catch (RemoteException ignored) {
            stopProcess();
        }
    }

    private int checkIsolation(String canary, int port) {
        if (checkSelfPermission(Manifest.permission.INTERNET) != PackageManager.PERMISSION_DENIED) {
            Log.w("MotifLxProbe", "Unexpected INTERNET permission in isolated UID");
            return INTERNET_PERMISSION_GRANTED;
        }
        final int fileStatus = canaryOpenStatus(canary);
        // ART can hide the app's private directory entirely. The host checks
        // that the exact same generated canary is readable, including after exit.
        if (!isAccessDenied(fileStatus) && fileStatus != OsConstants.ENOENT) {
            Log.w("MotifLxProbe", "Unexpected private canary open result " + fileStatus);
            return CANARY_ACCESS_UNVERIFIED;
        }
        final int networkStatus = loopbackConnectStatus(port);
        if (!isAccessDenied(networkStatus)) {
            Log.w("MotifLxProbe", "Unexpected isolated TCP result " + networkStatus);
            return LOOPBACK_ACCESS_UNVERIFIED;
        }
        Log.i("MotifLxProbe", "Private canary and TCP blocked (" + fileStatus
                + ", " + networkStatus + ")");
        return 0;
    }

    private static boolean isAccessDenied(int status) {
        return status == OsConstants.EACCES || status == OsConstants.EPERM;
    }

    private static int canaryOpenStatus(String canary) {
        final FileDescriptor fd;
        try {
            fd = Os.open(canary, OsConstants.O_RDONLY, 0);
        } catch (ErrnoException error) {
            return error.errno;
        }
        closeQuietly(fd);
        return 0;
    }

    private static int loopbackConnectStatus(int port) {
        FileDescriptor fd = null;
        try {
            fd = Os.socket(OsConstants.AF_INET, OsConstants.SOCK_STREAM, 0);
            Os.connect(fd, InetAddress.getByAddress(new byte[]{127, 0, 0, 1}), port);
            return 0;
        } catch (ErrnoException error) {
            return error.errno;
        } catch (SocketException error) {
            if (error.getCause() instanceof ErrnoException) {
                return ((ErrnoException) error.getCause()).errno;
            }
            return -1;
        } catch (UnknownHostException impossible) {
            return -1;
        } finally {
            if (fd != null) closeQuietly(fd);
        }
    }

    private static void closeQuietly(FileDescriptor fd) {
        try {
            Os.close(fd);
        } catch (ErrnoException ignored) {
            // The watchdog still owns process cleanup.
        }
    }

    private static void stopProcess() {
        Process.killProcess(Process.myPid());
    }

    private static native int nativeRunFixture();
    private static native int nativePlayback(boolean timeout, IFixtureCatalog catalog);
    private static native byte[] nativeScript(byte[] script, byte[] parameters, IScriptBroker broker);
}
