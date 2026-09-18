package com.oney.WebRTCModule;

import android.view.View;

import java.lang.ref.WeakReference;
import java.util.HashMap;
import java.util.Map;

/**
 * A process-wide map of integer keys -> native Views that {@link GetUserMediaImpl#getWhiteboardMedia}
 * can sample when the view is NOT React-managed. getWhiteboardMedia normally resolves its
 * {@code sourceTag} through the UIManager ({@code resolveView}), which only knows views RN mounted.
 * A host whose UI is native (Jetpack Compose / Android Views) has no such tag for its drawing
 * surface, so it registers that view here under a key it then hands to
 * {@code GetWhiteboardMedia({ sourceTag: key })}; the capture path falls back to this registry when
 * the React lookup misses.
 *
 * <p>Views are held WEAKLY -- the host owns the view's lifetime, and a collected view simply
 * resolves to null (the same NotFoundError a stale React tag gives). Keys are the host's to choose;
 * pick a range that will not collide with React tags (which are small positive integers).
 */
public final class SiperbCaptureViewRegistry {
    private static final Map<Integer, WeakReference<View>> VIEWS = new HashMap<>();

    private SiperbCaptureViewRegistry() {}

    public static synchronized void registerView(int key, View view) {
        if (view == null) {
            return;
        }
        VIEWS.put(key, new WeakReference<>(view));
    }

    public static synchronized void removeKey(int key) {
        VIEWS.remove(key);
    }

    public static synchronized View viewForKey(int key) {
        WeakReference<View> ref = VIEWS.get(key);
        if (ref == null) {
            return null;
        }
        View view = ref.get();
        if (view == null) {
            VIEWS.remove(key);
        }
        return view;
    }
}
