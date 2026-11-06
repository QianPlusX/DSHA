package com.deepseekharness.app.core;

import com.deepseekharness.app.runtime.StoredWebSession;

/** 有界只读识别；未知证据不启动、不停止，也不擦除任何现场。 */
final class WebSessionRecovery {
  enum Result {
    NONE,
    RESTORED,
    UNKNOWN,
    STALE
  }

  interface Ports {
    StoredWebSession.Record read() throws Exception;

    boolean current();

    boolean compatible(StoredWebSession.Record record) throws Exception;

    boolean verify(StoredWebSession.Record record) throws Exception;

    boolean authenticate(StoredWebSession.Record record) throws Exception;

    boolean adopt(StoredWebSession.Record record) throws Exception;

    /** 记录里的启动器已确认退出（宿主被杀、覆盖安装、机器重启后）。 */
    default boolean exited(StoredWebSession.Record record) throws Exception {
      return false;
    }
  }

  static Result recover(Ports ports) {
    try {
      var saved = ports.read();
      if (!ports.current()) return Result.STALE;
      if (saved == null) return Result.NONE;
      // 宿主进程被替换（覆盖安装、强杀）后，旧启动器已退出就是明确结束，不再当未知挡住启动。
      try {
        if (ports.exited(saved)) return Result.STALE;
      } catch (Exception unreadable) {
        // 读不到进程状态时保持原有保守判定。
      }
      if (!ports.compatible(saved) || !ports.verify(saved)) return Result.UNKNOWN;
      if (!ports.current()) return Result.STALE;
      if (!ports.authenticate(saved)) return Result.UNKNOWN;
      if (!ports.current()) return Result.STALE;
      if (!ports.verify(saved)) return Result.UNKNOWN;
      return ports.current() && ports.adopt(saved) ? Result.RESTORED : Result.STALE;
    } catch (Exception unavailable) {
      return Result.UNKNOWN;
    }
  }
}
