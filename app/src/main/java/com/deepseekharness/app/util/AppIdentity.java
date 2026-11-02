package com.deepseekharness.app.util;

/** Product identity for the production application. */
public final class AppIdentity {
  private AppIdentity() {}

  public static String applicationId() {
    return "dsh.android.client.plus";
  }

  public static String displayName() {
    return "DSHA Plus";
  }

  public static String publicDirectoryName() {
    return "DSHA";
  }

  public static String defaultUpdateFeed() {
    return "";
  }

  public static boolean isExperimental() {
    return false;
  }
}
