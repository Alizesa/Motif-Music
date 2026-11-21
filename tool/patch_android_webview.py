"""Use AGP 9-compatible ProGuard defaults in the Android WebView plugin."""

import json
from pathlib import Path
import sys
from urllib.parse import urlparse
from urllib.request import url2pathname


PACKAGE_NAME = "flutter_inappwebview_android"
LEGACY_CALL = b"getDefaultProguardFile('proguard-android.txt')"
OPTIMIZED_CALL = b"getDefaultProguardFile('proguard-android-optimize.txt')"


def patch_android_webview(package_config):
    package_config = Path(package_config).resolve()
    config = json.loads(package_config.read_text(encoding="utf-8-sig"))
    if config.get("configVersion") != 2:
        raise ValueError("Unsupported package configuration; run flutter pub get first")
    packages = [
        package for package in config["packages"] if package["name"] == PACKAGE_NAME
    ]
    if len(packages) != 1:
        raise ValueError("Expected one Android WebView package; run flutter pub get first")

    uri = urlparse(packages[0]["rootUri"])
    if uri.scheme not in ("", "file") or uri.netloc not in ("", "localhost"):
        raise ValueError("The Android WebView package must have a local file URI")
    package_root = Path(url2pathname(uri.path))
    if not package_root.is_absolute():
        package_root = package_config.parent / package_root

    build_file = package_root / "android" / "build.gradle"
    original = build_file.read_bytes()
    legacy_count = original.count(LEGACY_CALL)
    optimized_count = original.count(OPTIMIZED_CALL)
    if legacy_count == 0 and optimized_count == 2:
        return False
    if legacy_count != 2 or optimized_count != 0:
        raise ValueError(
            "Unexpected Android WebView ProGuard configuration; "
            "review the plugin before applying the compatibility patch"
        )
    build_file.write_bytes(original.replace(LEGACY_CALL, OPTIMIZED_CALL))
    return True


if __name__ == "__main__":
    if len(sys.argv) > 2:
        raise SystemExit("Usage: patch_android_webview.py [package_config.json]")
    config_path = sys.argv[1] if len(sys.argv) == 2 else ".dart_tool/package_config.json"
    try:
        changed = patch_android_webview(config_path)
    except (ValueError, KeyError, TypeError, OSError) as error:
        raise SystemExit("Android WebView compatibility setup failed: " + str(error)) from None
    print(
        "Android WebView: updated debug/release ProGuard defaults for AGP 9."
        if changed
        else "Android WebView: optimized ProGuard defaults are already configured."
    )
