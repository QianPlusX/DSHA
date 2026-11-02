#!/usr/bin/env bash
# DSHA arm64（aarch64 手机/平板）构建入口。
#
# 与官方 build.sh 的区别（官方只在 x86_64 上验证过）：
#   1. aapt2 / aidl 用的是 arm64 原生二进制 —— Google 的 build-tools 只有 x86_64，
#      这里用 lzhiyong/android-sdk-tools 的静态 aarch64 版本（glibc/静态链接）。
#   2. AIDL 任务用 tools/aidl-stub 的等价产物（build.sh 已内置该 shim）。
#   3. AGP 9.1.1 在 aarch64 上会把 linked-resources-format .ap_ 排除在最终 APK 之外，
#      产物缺 AndroidManifest.xml / res/ / resources.arsc。这里在打包后把 .ap_ 合并回
#      APK（条目与官方 292 MB 包一致：1384 vs 1387，差的只有签名文件）。
#
# 用法：
#   bash build-arm64.sh                 # 构建 + 合并资源 + 签名，输出到 outputs/
#   bash build-arm64.sh --no-sign       # 只构建未签名包
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/tmp/android-sdk}}"
JAVA_HOME="${JAVA_HOME:-/opt/jdk17}"
ARM_BUILD_TOOLS="${ARM_BUILD_TOOLS:-/opt/sdk-tools-arm64/build-tools}"
KS="${DSHA_MOD_KEYSTORE:-$HOME/dsha-mod.keystore}"
KS_PASS="${DSHA_MOD_KEYSTORE_PASSWORD:-dshamod}"
KS_ALIAS="${DSHA_MOD_KEY_ALIAS:-dshamod}"
OUT_DIR="${OUT_DIR:-$ROOT/outputs}"
SIGN=1
[ "${1:-}" = "--no-sign" ] && SIGN=0

[ -x "$JAVA_HOME/bin/java" ] || { echo "ERROR: JAVA_HOME 不可用: $JAVA_HOME" >&2; exit 1; }
[ -x "$ARM_BUILD_TOOLS/aapt2" ] || { echo "ERROR: 缺少 arm64 aapt2: $ARM_BUILD_TOOLS/aapt2" >&2
  echo "  下载：https://github.com/lzhiyong/android-sdk-tools/releases/download/35.0.2/android-sdk-tools-static-aarch64.zip" >&2; exit 1; }

# AGP 只接受可执行文件且文件名必须正好是 aapt2。
AAPT2_DIR="$ROOT/.arm64-tools"
mkdir -p "$AAPT2_DIR"
cp -f "$ARM_BUILD_TOOLS/aapt2" "$AAPT2_DIR/aapt2"
cp -f "$ARM_BUILD_TOOLS/zipalign" "$AAPT2_DIR/zipalign" 2>/dev/null || true
chmod +x "$AAPT2_DIR/aapt2" "$AAPT2_DIR/zipalign" 2>/dev/null || true

export JAVA_HOME ANDROID_SDK_ROOT="$SDK" ANDROID_HOME="$SDK"
export DSHA_PYTHON="${DSHA_PYTHON:-python3}"

echo "==> JAVA_HOME=$JAVA_HOME"
echo "==> SDK=$SDK"
echo "==> aapt2=$AAPT2_DIR/aapt2 ($("$AAPT2_DIR/aapt2" version 2>&1 | head -1))"

# 改了 launcher 源码（StartupPipeline/AppIdentity 等）后，runtime descriptor 的字节证明要重算，
# 否则 verifyRuntimeDescriptorInputs 会以 DESCRIPTOR_LAUNCHER_BYTES 失败。
"$DSHA_PYTHON" tools/prepare-runtime-descriptor.py --write

echo "==> Gradle: assembleStandardRelease（未签名）"
./gradlew --no-daemon \
  -Dorg.gradle.jvmargs="-Xmx${DSHA_JVM_MB:-3g} -Dfile.encoding=UTF-8" \
  -Pandroid.aapt2FromMavenOverride="$AAPT2_DIR/aapt2" \
  -Pdsha.unsignedPackage=true \
  assembleStandardRelease

UNSIGNED="$(ls -1 app/build/outputs/apk/standard/release/*.apk | head -1)"
AP_="$(ls -1 app/build/intermediates/linked_resources_binary_format/standardRelease/*/*.ap_ | head -1)"
[ -f "$UNSIGNED" ] || { echo "ERROR: 没有未签名 APK" >&2; exit 1; }
[ -f "$AP_" ] || { echo "ERROR: 没有 linked resources .ap_（processResources 没跑）" >&2; exit 1; }

mkdir -p "$OUT_DIR"
MERGED="$OUT_DIR/dsha-arm64-merged.apk"
ALIGNED="$OUT_DIR/dsha-arm64-aligned.apk"

echo "==> 合并资源表（AGP 在 aarch64 上漏掉的那部分）"
"$DSHA_PYTHON" - "$UNSIGNED" "$AP_" "$MERGED" <<'PY'
import sys, zipfile
src, ap_, out = sys.argv[1:4]
zsrc, zres = zipfile.ZipFile(src), zipfile.ZipFile(ap_)
have = set(zsrc.namelist())
added = 0
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as dst:
    for info in zsrc.infolist():
        ni = zipfile.ZipInfo(info.filename, date_time=info.date_time)
        ni.compress_type, ni.external_attr = info.compress_type, info.external_attr
        dst.writestr(ni, zsrc.read(info.filename))
    for info in zres.infolist():
        if info.filename in have:
            continue
        ni = zipfile.ZipInfo(info.filename, date_time=(2026, 10, 22, 0, 0, 0))
        # resources.arsc 必须 STORED，否则安装后无法 mmap 对齐。
        ni.compress_type = zipfile.ZIP_STORED if info.filename == 'resources.arsc' else zipfile.ZIP_DEFLATED
        ni.external_attr = info.external_attr
        dst.writestr(ni, zres.read(info.filename))
        added += 1
print('merged %d entries' % added)
PY

echo "==> zipalign"
"$AAPT2_DIR/zipalign" -p -f 4 "$MERGED" "$ALIGNED"

if [ "$SIGN" = 1 ]; then
  if [ ! -f "$KS" ]; then
    echo "==> 生成签名用 keystore: $KS（与官方 debug 证书不同，安装需先卸载原 App）"
    "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KS" -alias "$KS_ALIAS" -keyalg RSA \
      -keysize 2048 -validity 10000 -storepass "$KS_PASS" -keypass "$KS_PASS" \
      -dname "CN=DSHA Local Mod" -noprompt >/dev/null 2>&1
  fi
  echo "==> 签名"
  FINAL="$OUT_DIR/dsha-0.2.1-rc.2-arm64-mod.apk"
  "$JAVA_HOME/bin/java" -Xmx6g -jar "$SDK/build-tools/36.0.0/lib/apksigner.jar" sign \
    --ks "$KS" --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" --ks-key-alias "$KS_ALIAS" \
    --out "$FINAL" "$ALIGNED"
  "$JAVA_HOME/bin/java" -jar "$SDK/build-tools/36.0.0/lib/apksigner.jar" verify "$FINAL" >/dev/null
  echo "==> 完成: $FINAL"
else
  FINAL="$ALIGNED"
  echo "==> 完成（未签名）: $FINAL"
fi

"$AAPT2_DIR/aapt2" dump badging "$FINAL" 2>/dev/null | head -1 | sed 's/^/    /'
