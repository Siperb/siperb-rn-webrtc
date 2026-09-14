package com.oney.WebRTCModule;

import android.app.Notification;
import android.app.Service;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import java.util.Random;
import java.util.concurrent.CompletableFuture;

/**
 * This class implements an Android {@link Service}, a foreground one specifically, and it's
 * responsible for presenting an ongoing notification when a conference is in progress.
 * The service will help keep the app running while in the background.
 *
 * See: https://developer.android.com/guide/components/services
 */
public class MediaProjectionService extends Service {
    private static final String TAG = MediaProjectionService.class.getSimpleName();

    static final int NOTIFICATION_ID = new Random().nextInt(99999) + 10000;

    /**
     * API 34's name for the permission, spelled out so this compiles against any compileSdk
     * the consuming app pins. Unknown to older platforms, where the check is skipped.
     */
    private static final String PERMISSION_MEDIA_PROJECTION = "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION";

    private static volatile CompletableFuture<Void> startFuture;

    public static CompletableFuture<Void> launch(Context context) {
        if (!WebRTCModuleOptions.getInstance().enableMediaProjectionService) {
            return CompletableFuture.completedFuture(null);
        }

        CompletableFuture<Void> future = new CompletableFuture<>();

        startFuture = future;

        MediaProjectionNotification.createNotificationChannel(context);
        Intent intent = new Intent(context, MediaProjectionService.class);
        ComponentName componentName;

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                componentName = context.startForegroundService(intent);
            } else {
                componentName = context.startService(intent);
            }
        } catch (RuntimeException e) {
            // Avoid crashing due to ForegroundServiceStartNotAllowedException (API level 31).
            // See: https://developer.android.com/guide/components/foreground-services#background-start-restrictions
            Log.w(TAG, "Media projection service not started", e);
            startFuture = null;
            future.completeExceptionally(e);

            return future;
        }

        if (componentName == null) {
            Log.w(TAG, "Media projection service not started");
            startFuture = null;
            future.completeExceptionally(new RuntimeException("Media projection service not started"));
        } else {
            Log.i(TAG, "Media projection service started");
        }

        return future;
    }

    /** Whether this build declares what the service needs; false is a guaranteed failure to start. */
    public static boolean hasRequiredPermissions(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return true;
        }
        if (context.checkSelfPermission(android.Manifest.permission.FOREGROUND_SERVICE) != PackageManager.PERMISSION_GRANTED) {
            return false;
        }
        if (Build.VERSION.SDK_INT >= 34
                && context.checkSelfPermission(PERMISSION_MEDIA_PROJECTION) != PackageManager.PERMISSION_GRANTED) {
            return false;
        }
        return true;
    }

    public static void abort(Context context) {
        if (!WebRTCModuleOptions.getInstance().enableMediaProjectionService) {
            return;
        }

        Intent intent = new Intent(context, MediaProjectionService.class);
        context.stopService(intent);
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // Checked BEFORE startForeground rather than caught after: on API 34+ a missing
        // FOREGROUND_SERVICE_MEDIA_PROJECTION is a SecurityException thrown out of
        // startForeground, and an exception out of onStartCommand takes the whole process down.
        // The library manifest declares the permission, so this only fires when an app has
        // stripped it - and then it is a logged refusal, not a crash. Failing the start future
        // is what makes getDisplayMedia() reject instead of building a capturer that cannot work.
        if (!hasRequiredPermissions(this)) {
            Log.e(TAG, "Missing FOREGROUND_SERVICE / FOREGROUND_SERVICE_MEDIA_PROJECTION permission; "
                    + "screen capture cannot start on this build");

            CompletableFuture<Void> fut = startFuture;

            if (fut != null) {
                startFuture = null;
                fut.completeExceptionally(new SecurityException("Missing media projection foreground service permission"));
            }

            stopSelf();
            return START_NOT_STICKY;
        }

        Notification notification = MediaProjectionNotification.buildMediaProjectionNotification(this);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }

        CompletableFuture<Void> fut = startFuture;

        if (fut != null) {
            startFuture = null;
            fut.complete(null);
        }

        return START_NOT_STICKY;
    }
}
