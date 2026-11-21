"""Repair the pinned Windows WebView plugin's C++ header defects for CI."""

import json
from pathlib import Path
import re
import sys
from urllib.parse import urlparse
from urllib.request import url2pathname


PACKAGE_NAME = "flutter_inappwebview_windows"


def _rewrite(data, old, new, newline):
    old = old.replace(b"\n", newline)
    new = new.replace(b"\n", newline)
    if data.count(new) == 1 and data.replace(new, b"", 1).count(old) == 0:
        return data
    if data.count(new) == 0 and data.count(old) == 1:
        return data.replace(old, new, 1)
    raise ValueError("Unexpected WebView header layout; review the pinned plugin patch")


def patch_windows_webview(package_config):
    config_path = Path(package_config).resolve()
    config = json.loads(config_path.read_text(encoding="utf-8-sig"))
    if config.get("configVersion") != 2:
        raise ValueError("Unsupported package configuration; run flutter pub get first")
    packages = [package for package in config["packages"] if package["name"] == PACKAGE_NAME]
    if len(packages) != 1:
        raise ValueError("Expected one resolved Windows WebView package")
    uri = urlparse(packages[0]["rootUri"])
    if uri.scheme not in ("", "file") or uri.netloc not in ("", "localhost"):
        raise ValueError("The Windows WebView package must have a local file URI")
    package_root = Path(url2pathname(uri.path))
    if not package_root.is_absolute():
        package_root = config_path.parent / package_root
    manifest = (package_root / "pubspec.yaml").read_text(encoding="utf-8")
    if not re.search(r"(?m)^version:\s*0\.6\.0\s*$", manifest):
        raise ValueError("Windows WebView compatibility patch requires version 0.6.0")

    replacements = {
        "utils/util.h": [
            (b"#include <variant>\n#include <Windows.h>",
             b"#include <variant>\n#include <cstdint>\n#include <type_traits>\n#include <Windows.h>"),
            (b"namespace flutter_inappwebview_plugin\n{\n",
             b"namespace flutter_inappwebview_plugin\n{\n"
             b"  template<typename>\n"
             b"  inline constexpr bool always_false_v = false;\n\n"),
        ],
        "utils/string.h": [
            (b"std::basic_string<T>{ \"\" }", b"std::basic_string<T>{}"),
            (b"[delim](auto& a, auto& b) { return a + delim + b; }",
             b"[delim](const auto& a, const auto& b) { return a + delim + b; }"),
            (b"void to_lowercase(const std::basic_string<T>& s)",
             b"void to_lowercase(std::basic_string<T>& s)"),
            (b"void to_uppercase(const std::basic_string<T>& s)\n"
             b"  {\n"
             b"    std::transform(s.begin(), s.end(), s.begin(),\n"
             b"      [](const T v) { return static_cast<T>(std::toupper(v)); });\n"
             b"    return s2;\n"
             b"  }",
             b"void to_uppercase(std::basic_string<T>& s)\n"
             b"  {\n"
             b"    std::transform(s.begin(), s.end(), s.begin(),\n"
             b"      [](const T v) { return static_cast<T>(std::toupper(v)); });\n"
             b"  }"),
        ],
        "types/rect.h": [
            (b"bool Rect::operator==", b"bool operator=="),
            (b"bool Rect::operator!=", b"bool operator!="),
        ],
        "types/size_2d.h": [
            (b"bool Size2D::operator==", b"bool operator=="),
            (b"bool Size2D::operator!=", b"bool operator!="),
        ],
        "types/permission_response.h": [
            (b"bool PermissionResponse::operator==", b"bool operator=="),
            (b"bool PermissionResponse::operator!=", b"bool operator!="),
        ],
        "types/web_resource_response.h": [
            (b"ICoreWebView2WebResourceResponse* WebResourceResponse::toWebView2Response",
             b"ICoreWebView2WebResourceResponse* toWebView2Response"),
        ],
    }

    updates = []
    # Validate every header before writing any part of the patch.
    for name, rules in replacements.items():
        path = package_root / "windows" / name
        original = path.read_bytes()
        newline = b"\r\n" if b"\r\n" in original else b"\n"
        updated = original
        for old, new in rules:
            updated = _rewrite(updated, old, new, newline)
        if updated != original:
            updates.append((path, updated))
    for path, updated in updates:
        path.write_bytes(updated)
    return len(updates)


if __name__ == "__main__":
    if len(sys.argv) > 2:
        raise SystemExit("Usage: patch_windows_webview.py [package_config.json]")
    config_path = sys.argv[1] if len(sys.argv) == 2 else ".dart_tool/package_config.json"
    try:
        changed = patch_windows_webview(config_path)
    except (ValueError, KeyError, TypeError, OSError) as error:
        raise SystemExit("Windows WebView compatibility setup failed: " + str(error)) from None
    print(f"Windows WebView: repaired {changed} headers (version 0.6.0).")
