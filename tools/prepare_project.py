#!/usr/bin/env python3
"""
Cave Crawler - Android port (The Soim): project preparation tool.

The game is a Godot 3.5 project, so the Android runtime has to be Godot 3.5's own. This tool builds a
complete Gradle project from Godot's official Android template (the same one the Godot editor uses for
"custom build" exports) and puts the game on top of it:

  1. gets  android_source.zip  from the official Godot 3.5.3 export templates
     (downloads only that one file from the .tpz, or use --template <android_source.zip>)
  2. unpacks the original game pack (game/CaveCrawler.pck) into the template's assets (what the editor does)
  3. adds the port layer (overlay/android_port) and registers it as an autoload; turns off the engine's
     touch->mouse emulation (the game's "fire" action is bound to the mouse)
  4. icon, app name, permissions, landscape, immersive mode, notch support, package id, version, signing key

Usage:
    python3 tools/prepare_project.py                      # download the template, create build/android-project
    python3 tools/prepare_project.py --template android_source.zip
Then build (JDK 11 is what Godot 3.5's Gradle setup expects):
    cd build/android-project && ./gradlew assembleRelease
"""
import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import urllib.request
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GODOT_TAG = "3.5.3-stable"
TPZ_URL = "https://github.com/godotengine/godot/releases/download/%s/Godot_v3.5.3-stable_export_templates.tpz" % GODOT_TAG
TPZ_MEMBER = "templates/android_source.zip"
PACKAGE_ID = "thesoim.cavecrawler"
VERSION_NAME = "1.0.0"
VERSION_CODE = 1
APP_NAME = "Cave Crawler"
AUTOLOAD_KEY = "autoload/AndroidPort"
AUTOLOAD_VALUE = "*res://android_port/port_layer.gd"
EMULATE_KEY = "input_devices/pointing/emulate_mouse_from_touch"


# ----------------------------------------------------------------------------- game pack (Godot 3 PCK, format 1)

def read_pck1(path):
    d = open(path, "rb").read()
    magic, ver, ma, mi, pa = struct.unpack_from("<4sIIII", d, 0)
    if magic != b"GDPC" or ver != 1 or (ma, mi) != (3, 5):
        raise SystemExit("Expected a Godot 3.5 pack (format 1), got %r v%d %d.%d" % (magic, ver, ma, mi))
    p = 20 + 64
    (count,) = struct.unpack_from("<I", d, p)
    p += 4
    out = []
    for _ in range(count):
        (n,) = struct.unpack_from("<I", d, p)
        p += 4
        name = d[p:p + n].rstrip(b"\0").decode("utf-8")
        p += n
        ofs, size = struct.unpack_from("<QQ", d, p)
        p += 16 + 16  # offset/size + md5
        out.append((name, d[ofs:ofs + size]))
    return out


def _entry(key, variant):
    k = key.encode()
    return struct.pack("<I", len(k)) + k + struct.pack("<I", len(variant)) + variant


def patch_project_binary(data):
    """Godot 3 'ECFG' project.binary: append two settings (autoload + touch->mouse emulation off)."""
    if data[:4] != b"ECFG":
        raise SystemExit("project.binary: bad magic")
    if AUTOLOAD_KEY.encode() in data or EMULATE_KEY.encode() in data:
        raise SystemExit("project.binary already patched")
    (count,) = struct.unpack_from("<I", data, 4)
    val = AUTOLOAD_VALUE.encode()
    pad = (len(val) + 3) // 4 * 4
    s = struct.pack("<II", 4, len(val)) + val + b"\0" * (pad - len(val))      # STRING
    b = struct.pack("<II", 1, 0)                                              # BOOL false
    return data[:4] + struct.pack("<I", count + 2) + data[8:] + _entry(AUTOLOAD_KEY, s) + _entry(EMULATE_KEY, b)


# ----------------------------------------------------------------------------- template download (only one file of the .tpz)

def _range(url, start, end):
    req = urllib.request.Request(url, headers={"Range": "bytes=%d-%d" % (start, end)})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read()
        cr = r.headers.get("Content-Range", "")
    return data, cr


def fetch_member(url, member, dest):
    """Read one member out of a remote zip with HTTP range requests (the .tpz is ~600 MB, the member ~50 MB)."""
    _, cr = _range(url, 0, 0)
    total = int(cr.rsplit("/", 1)[1])
    tail_len = min(total, 1 << 20)
    tail, _ = _range(url, total - tail_len, total - 1)
    e = tail.rfind(b"PK\x05\x06")
    if e < 0:
        raise RuntimeError("zip end record not found")
    cd_size, cd_off = struct.unpack_from("<II", tail, e + 12)
    cd, _ = _range(url, cd_off, cd_off + cd_size - 1)
    p = 0
    while p < len(cd) and cd[p:p + 4] == b"PK\x01\x02":
        method, = struct.unpack_from("<H", cd, p + 10)
        crc, csize, usize = struct.unpack_from("<III", cd, p + 16)
        nlen, elen, clen = struct.unpack_from("<HHH", cd, p + 28)
        loff, = struct.unpack_from("<I", cd, p + 42)
        name = cd[p + 46:p + 46 + nlen].decode()
        if name == member:
            lh, _ = _range(url, loff, loff + 29)
            ln, le = struct.unpack_from("<HH", lh, 26)
            start = loff + 30 + ln + le
            raw = b""
            step = 8 << 20
            for a in range(start, start + csize, step):
                chunk, _ = _range(url, a, min(a + step, start + csize) - 1)
                raw += chunk
                print("  downloaded %d / %d MB" % (len(raw) >> 20, csize >> 20), end="\r")
            print()
            data = raw if method == 0 else zlib.decompressobj(-15).decompress(raw)
            if zlib.crc32(data) & 0xFFFFFFFF != crc:
                raise RuntimeError("CRC mismatch")
            with open(dest, "wb") as f:
                f.write(data)
            return
        p += 46 + nlen + elen + clen
    raise RuntimeError("%s not found in the archive" % member)


# ----------------------------------------------------------------------------- helpers

def find_one(root, pattern):
    rx = re.compile(pattern)
    for dp, dn, fn in os.walk(root):
        for f in fn:
            if rx.search(os.path.join(dp, f).replace("\\", "/")):
                return os.path.join(dp, f)
    return None


def find_all(root, pattern):
    rx = re.compile(pattern)
    out = []
    for dp, dn, fn in os.walk(root):
        for f in fn:
            p = os.path.join(dp, f)
            if rx.search(p.replace("\\", "/")):
                out.append(p)
    return out


def warn(msg):
    print("WARNING: " + msg)


def write(path, data, mode="wb"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode) as f:
        f.write(data)


# ----------------------------------------------------------------------------- staging steps

def fix_title_particles(assets):
    """Title background: the red particles used to fill the screen only after ~6 s (visible build-up when the game
    starts) and stopped at x=256. Start fully populated, spawn further right and live longer (same density)."""
    p = os.path.join(assets, "effects", "BG.tscn")
    s = open(p, "rb").read().decode("utf-8")
    nl = "\r\n" if "\r\n" in s else "\n"
    a = "position = Vector2( 264, 72 )"
    if a not in s:
        warn("effects/BG.tscn has an unexpected layout: title particles left as they were")
        return
    s = s.replace(a, "position = Vector2( 400, 72 )").replace("amount = 512", "amount = 683")
    s = s.replace("lifetime = 6.0", "lifetime = 8.0" + nl + "preprocess = 8.0" + nl + "visibility_rect = Rect2( -500, -100, 600, 200 )")
    open(p, "wb").write(s.encode("utf-8"))


def stage_assets(proj):
    assets = os.path.join(proj, "assets")
    os.makedirs(assets, exist_ok=True)
    files = read_pck1(os.path.join(ROOT, "game", "CaveCrawler.pck"))
    for name, data in files:
        rel = name.replace("res://", "")
        if rel == "project.binary":
            data = patch_project_binary(data)
        write(os.path.join(assets, rel), data)
    fix_title_particles(assets)
    src = os.path.join(ROOT, "overlay", "android_port")
    dst = os.path.join(assets, "android_port")
    os.makedirs(dst, exist_ok=True)
    for f in sorted(os.listdir(src)):
        shutil.copy(os.path.join(src, f), os.path.join(dst, f))
    print("assets: %d game files + port layer" % len(files))


def stage_icons(proj):
    """Launcher icon = the supplied artwork (overlay/icons/icon_square_1080.png), byte-for-byte, no resampling.

    The artwork is 1080x1008 (not square); icon_square_1080.png is the same pixels, centred on a black 1080x1080 canvas
    (the artwork's own background colour), so nothing is cropped, stretched or recoloured.
    * Android 7 and older: mipmap-nodpi/<name>.png (single full-resolution file, scaled by the launcher).
    * Android 8+: adaptive icon, black background + the same file as foreground, inset so the whole artwork stays inside
      the 66dp safe zone (round / squircle / teardrop masks never cut it).
    Every other launcher image of the template (all densities, old adaptive xml) is removed, so only this icon exists.
    """
    res = os.path.join(proj, "res")
    art = os.path.join(ROOT, "overlay", "icons", "icon_square_1080.png")
    manifest = find_one(proj, r"AndroidManifest\.xml$")
    main = "icon"
    if manifest:
        m = re.search(r'android:icon="@(?:mipmap|drawable)/(\w+)"', open(manifest, encoding="utf-8").read())
        if m:
            main = m.group(1)
    names = {main, "icon", "ic_launcher", "ic_launcher_round", "ic_launcher_foreground", "ic_launcher_background"}
    removed = 0
    for xml in find_all(res, r"(mipmap|drawable)[^/]*/[^/]+\.xml$"):
        txt = open(xml, encoding="utf-8", errors="ignore").read()
        if "<adaptive-icon" in txt:
            names |= set(re.findall(r"@(?:mipmap|drawable)/(\w+)", txt))
            os.remove(xml)
            removed += 1
    for p in find_all(res, r"(mipmap|drawable)[^/]*/[^/]+\.(png|webp|jpg|jpeg)$"):
        base = os.path.splitext(os.path.basename(p))[0]
        if base in names or re.search(r"(^icon|launcher)", base, re.I):
            os.remove(p)
            removed += 1
    data = open(art, "rb").read()
    write(os.path.join(res, "mipmap-nodpi", main + ".png"), data)
    write(os.path.join(res, "drawable-nodpi", main + "_art.png"), data)
    xmlhead = '<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
    body = ('    <background android:drawable="@android:color/black" />\n'
            '    <foreground>\n'
            '        <inset android:drawable="@drawable/%s_art" android:inset="20%%" />\n'
            '    </foreground>\n'
            '</adaptive-icon>\n') % main
    write(os.path.join(res, "mipmap-anydpi-v26", main + ".xml"), xmlhead + body, "w")
    write(os.path.join(res, "mipmap-anydpi-v26", main + "_round.xml"), xmlhead + body, "w")
    if manifest:
        t = open(manifest, encoding="utf-8").read()
        t = re.sub(r'\s+android:roundIcon="[^"]*"', "", t)
        t = t.replace('android:icon="@mipmap/%s"' % main, 'android:icon="@mipmap/%s"\n        android:roundIcon="@mipmap/%s_round"' % (main, main), 1)
        open(manifest, "w", encoding="utf-8").write(t)
    print("launcher icon: exact artwork installed (nodpi + adaptive), %d old template icon files removed (icon name: @%s)" % (removed, main))
    return main


def stage_name(proj):
    p = find_one(os.path.join(proj, "res"), r"values[^/]*/godot_project_name_string\.xml$")
    if p:
        write(p, '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <string name="godot_project_name_string">%s</string>\n</resources>\n' % APP_NAME, "w")
        print("app name set")
    else:
        warn("godot_project_name_string.xml not found: the app keeps the template's name")


def stage_theme(proj):
    """Black window background (no white strip while the app starts / rotates) for every Godot theme of the template."""
    n = 0
    for xml in find_all(os.path.join(proj, "res"), r"values[^/]*/[^/]+\.xml$"):
        txt = open(xml, encoding="utf-8", errors="ignore").read()
        if "<style" not in txt:
            continue
        def fix(m):
            nonlocal n
            body = m.group(0)
            if "godot" not in m.group(1).lower() and "splash" not in m.group(1).lower():
                return body
            body = re.sub(r'\s*<item name="android:(windowBackground|navigationBarColor|statusBarColor)">[^<]*</item>', "", body)
            items = ('\n        <item name="android:windowBackground">@android:color/black</item>'
                     '\n        <item name="android:navigationBarColor">@android:color/black</item>'
                     '\n        <item name="android:statusBarColor">@android:color/black</item>')
            n += 1
            return body.replace("</style>", items + "\n    </style>")
        new = re.sub(r'<style\s+name="([^"]+)"[^>]*>.*?</style>', fix, txt, flags=re.S)
        if new != txt:
            open(xml, "w", encoding="utf-8").write(new)
    print("themes with black window background: %d" % n)


def stage_manifest(proj):
    p = os.path.join(proj, "AndroidManifest.xml")
    if not os.path.isfile(p):
        p = find_one(proj, r"AndroidManifest\.xml$")
    if not p:
        warn("AndroidManifest.xml not found")
        return
    s = open(p, encoding="utf-8").read()
    if "android.permission.VIBRATE" not in s:
        s = s.replace("<application", '<uses-permission android:name="android.permission.VIBRATE" />\n\n    <application', 1)
    s = re.sub(r'android:screenOrientation="[^"]*"', 'android:screenOrientation="sensorLandscape"', s)
    open(p, "w", encoding="utf-8").write(s)
    print("manifest: VIBRATE permission, sensorLandscape")


PLUGIN_JAVA = """package thesoim.cavecrawler;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

/** Cave Crawler - Android port by The Soim: opens Telegram directly through its own package. */
public class PortPlugin extends GodotPlugin {
    private static final String[] TELEGRAM_PACKAGES = {
            "org.telegram.messenger",       // Telegram
            "org.telegram.messenger.web",   // Telegram (direct download build)
            "org.thunderdog.challegram",    // Telegram X
            "org.telegram.plus",
            "nekox.messenger"
    };

    public PortPlugin(Godot godot) {
        super(godot);
    }

    @Override
    public String getPluginName() {
        return "TheSoimPort";
    }

    @UsedByGodot
    public boolean openTelegram() {
        Activity activity = getActivity();
        if (activity == null) {
            return false;
        }
        Uri uri = Uri.parse("tg://resolve?domain=thesoim");
        for (String pkg : TELEGRAM_PACKAGES) {
            try {
                Intent intent = new Intent(Intent.ACTION_VIEW, uri);
                intent.setPackage(pkg);
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                activity.startActivity(intent);
                return true;
            } catch (Exception ignored) {
                // this Telegram build is not installed: try the next one
            }
        }
        try {
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse("https://t.me/thesoim"));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity.startActivity(intent);
            return true;
        } catch (Exception e) {
            return false;
        }
    }
}
"""


def _aar_has(proj, class_path):
    import io
    for aar in find_all(proj, r"godot-lib[^/]*\.aar$"):
        try:
            with zipfile.ZipFile(aar) as z:
                if "classes.jar" in z.namelist():
                    with zipfile.ZipFile(io.BytesIO(z.read("classes.jar"))) as j:
                        if class_path in j.namelist():
                            return True
        except Exception:
            pass
    return False


def stage_plugin(proj):
    app = find_one(proj, r"GodotApp\.java$")
    if not app:
        warn("GodotApp.java not found: Telegram plugin not added (the app falls back to the tg:// link)")
        return
    if not _aar_has(proj, "org/godotengine/godot/plugin/GodotPlugin.class"):
        warn("this Godot library has no plugin API: Telegram plugin not added (the app falls back to the tg:// link)")
        return
    pkg = re.search(r"^\s*package\s+([\w.]+)\s*;", open(app, encoding="utf-8").read(), re.M).group(1)
    src_root = os.path.dirname(app)
    for _ in pkg.split("."):
        src_root = os.path.dirname(src_root)
    write(os.path.join(src_root, "thesoim", "cavecrawler", "PortPlugin.java"), PLUGIN_JAVA, "w")
    manifest = find_one(proj, r"AndroidManifest\.xml$")
    s = open(manifest, encoding="utf-8").read()
    if "org.godotengine.plugin.v1.TheSoimPort" not in s:
        meta = '<meta-data android:name="org.godotengine.plugin.v1.TheSoimPort" android:value="thesoim.cavecrawler.PortPlugin" />\n        '
        s = s.replace("</application>", "    " + meta + "</application>", 1)
        open(manifest, "w", encoding="utf-8").write(s)
    print("Telegram plugin added (org.telegram.messenger first)")


GODOTAPP = """package %(pkg)s;

import android.os.Build;
import android.os.Bundle;
import android.view.View;
import android.view.WindowManager;

/** Cave Crawler - Android port by The Soim. Stock Godot activity + immersive full screen + notch support. */
public class GodotApp extends %(sup)s {
    @Override
    public void onCreate(Bundle savedInstanceState) {
%(theme)s        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (Build.VERSION.SDK_INT >= 28) {
            WindowManager.LayoutParams lp = getWindow().getAttributes();
            lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            getWindow().setAttributes(lp);
        }
        super.onCreate(savedInstanceState);
        hideSystemUi();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            hideSystemUi();
        }
    }

    private void hideSystemUi() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
    }
}
"""


def stage_activity(proj):
    p = find_one(proj, r"GodotApp\.java$")
    if not p:
        warn("GodotApp.java not found: immersive mode / notch support not added (the game still runs)")
        return
    s = open(p, encoding="utf-8").read()
    pkg = re.search(r"^\s*package\s+([\w.]+)\s*;", s, re.M)
    sup = re.search(r"class\s+GodotApp\s+extends\s+([\w.]+)", s)
    if not pkg or not sup:
        warn("unexpected GodotApp.java layout: left untouched")
        return
    theme = re.search(r"^\s*(setTheme\([^;]*\);)", s, re.M)
    theme_line = ("        " + theme.group(1) + "\n") if theme else ""
    write(p, GODOTAPP % {"pkg": pkg.group(1), "sup": sup.group(1), "theme": theme_line}, "w")
    print("GodotApp.java regenerated (extends %s)" % sup.group(1))


def make_keystore(proj):
    ks = os.path.join(proj, "thesoim.keystore")
    if os.path.isfile(ks):
        return ks
    try:
        subprocess.check_call(["keytool", "-genkey", "-v", "-keystore", ks, "-storepass", "thesoim", "-alias", "thesoim",
                               "-keypass", "thesoim", "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000",
                               "-dname", "CN=The Soim"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return ks
    except Exception:
        warn("keytool (JDK) not found: create a keystore yourself and set release_keystore_* in gradle.properties")
        return None


def stage_gradle(proj, keystore):
    gradle = find_one(proj, r"(^|/)build\.gradle$")
    text = open(gradle, encoding="utf-8").read() if gradle else ""
    props = [("export_package_name", PACKAGE_ID), ("export_version_code", str(VERSION_CODE)), ("export_version_name", VERSION_NAME)]
    if keystore:
        props += [("release_keystore_file", os.path.basename(keystore)), ("release_keystore_alias", "thesoim"),
                  ("release_keystore_password", "thesoim")]
    gp = os.path.join(proj, "gradle.properties")
    existing = open(gp, encoding="utf-8").read() if os.path.isfile(gp) else ""
    add = ""
    for k, v in props:
        if k in text:
            add += "%s=%s\n" % (k, v)
        else:
            warn("build.gradle does not mention %s: check that setting by hand" % k)
    if add:
        write(gp, existing.rstrip("\n") + "\n\n# Cave Crawler port (The Soim)\n" + add, "w")
    print("gradle.properties: package %s, version %s" % (PACKAGE_ID, VERSION_NAME))


def verify(proj):
    from_proj = os.path.join(proj, "assets", "project.binary")
    d = open(from_proj, "rb").read()
    assert d[:4] == b"ECFG" and AUTOLOAD_KEY.encode() in d and EMULATE_KEY.encode() in d
    assert os.path.isfile(os.path.join(proj, "assets", "android_port", "port_layer.gd"))
    assert os.path.isfile(os.path.join(proj, "assets", ".import")) or os.path.isdir(os.path.join(proj, "assets", ".import"))
    if not find_all(proj, r"godot-lib[^/]*\.aar$"):
        warn("no godot-lib*.aar found in the template: the build will fail")
    print("verification OK")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--template", help="path to android_source.zip from the Godot 3.5.x export templates")
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "android-project"))
    ap.add_argument("--no-keystore", action="store_true")
    a = ap.parse_args()

    tpl = a.template
    if not tpl:
        tpl = os.path.join(ROOT, "build", "android_source.zip")
        if not os.path.isfile(tpl):
            os.makedirs(os.path.dirname(tpl), exist_ok=True)
            print("downloading %s from %s" % (TPZ_MEMBER, TPZ_URL))
            fetch_member(TPZ_URL, TPZ_MEMBER, tpl)
    if os.path.isdir(a.out):
        shutil.rmtree(a.out)
    os.makedirs(a.out)
    with zipfile.ZipFile(tpl) as z:
        z.extractall(a.out)
    manifest = find_one(a.out, r"AndroidManifest\.xml$")
    if not manifest:
        raise SystemExit("AndroidManifest.xml not found in the template")
    proj = os.path.dirname(manifest)
    print("template project: %s" % proj)

    stage_assets(proj)
    stage_icons(proj)
    stage_name(proj)
    stage_theme(proj)
    stage_manifest(proj)
    stage_activity(proj)
    stage_plugin(proj)
    stage_gradle(proj, None if a.no_keystore else make_keystore(proj))
    verify(proj)
    print("\nDone. Build with:\n  cd %s\n  ./gradlew assembleRelease    (JDK 11)\nAPK: build/outputs/apk/release/" % proj)


if __name__ == "__main__":
    main()
