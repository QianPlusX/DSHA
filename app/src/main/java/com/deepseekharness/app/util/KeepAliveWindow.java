package com.deepseekharness.app.util;

import android.content.Context;
import android.graphics.PixelFormat;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;

/**
 * 退到后台时挂一个 1×1 的不可见窗口，让进程保持「有可见窗口」的重要级别，
 * 降低被系统按后台优先级回收的概率；回到前台立刻移除。
 *
 * <p>窗口不可触摸、不可获得焦点，也不占布局空间，用户看不到它。
 * 需要「显示在其他应用上层」权限（{@link com.deepseekharness.app.OverlayController#permitted}）；
 * 没授权时静默跳过，不打断启动流程。
 */
public final class KeepAliveWindow {
  private static WindowManager windowManager;
  private static View view;

  private KeepAliveWindow() {}

  public static void show(Context context) {
    if (view != null || context == null) return;
    Context app = context.getApplicationContext();
    if (!com.deepseekharness.app.OverlayController.permitted(app)) return;
    try {
      WindowManager manager = (WindowManager) app.getSystemService(Context.WINDOW_SERVICE);
      if (manager == null) return;
      View pixel = new View(app);
      WindowManager.LayoutParams params =
          new WindowManager.LayoutParams(
              1,
              1,
              WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
              WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                  | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                  | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                  | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                  | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
              PixelFormat.TRANSLUCENT);
      params.gravity = Gravity.TOP | Gravity.START;
      manager.addView(pixel, params);
      windowManager = manager;
      view = pixel;
    } catch (RuntimeException unavailable) {
      hide();
    }
  }

  public static void hide() {
    View pixel = view;
    WindowManager manager = windowManager;
    view = null;
    windowManager = null;
    if (pixel == null || manager == null) return;
    try {
      manager.removeView(pixel);
    } catch (RuntimeException alreadyGone) {
      // 窗口已被系统回收，无需处理
    }
  }
}
