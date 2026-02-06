#!/usr/bin/env python
"""
SConstruct for yggdrasil-multiplayer-peer GDExtension.

Builds a GDExtension shared library that statically links libyggdrasil.a
(the Go/CGo yggdrasil network library).

Platforms: macOS, Linux, Windows, iOS, Android
macOS/iOS: creates .framework bundle, codesigns, and copies to netfox addon
Other:     codesigns (if applicable) and copies to netfox addon
"""
import os
import subprocess
import shutil

env = SConscript("godot-cpp/SConstruct")

env.Append(CPPPATH=["src/"])

# --------------------------------------------------------------------------
# Destination: auto-copy built artifacts to the netfox addon
# --------------------------------------------------------------------------
ADDON_DIR = os.path.abspath("../netfox/addons/yggdrasil")
ADDON_BIN = os.path.join(ADDON_DIR, "bin")

# --------------------------------------------------------------------------
# Static library: libyggdrasil.a
# --------------------------------------------------------------------------
ygg_lib = File("bin/libyggdrasil.a")

# Force static linking by passing the .a file directly (not -lyggdrasil)
# so the Go runtime is baked into the final shared library — no DLL-in-DLL.
env.Append(LINKFLAGS=[ygg_lib.abspath])

# Go runtime dependencies required when statically linking a c-archive
platform = env["platform"]

if platform == "macos":
    env.Append(LIBS=["pthread", "m", "resolv", "objc"])
    env.Append(LINKFLAGS=[
        "-framework", "CoreFoundation",
        "-framework", "Security",
        "-framework", "Foundation",
        "-framework", "SystemConfiguration",
    ])
elif platform == "ios":
    env.Append(LIBS=["pthread", "m", "resolv", "objc"])
    env.Append(LINKFLAGS=[
        "-framework", "CoreFoundation",
        "-framework", "Security",
        "-framework", "Foundation",
        "-framework", "SystemConfiguration",
    ])
elif platform == "linux":
    env.Append(LIBS=["pthread", "m", "resolv"])
elif platform == "android":
    env.Append(LIBS=["log"])
elif platform == "windows":
    env.Append(LIBS=["ws2_32", "winmm", "ntdll"])

# --------------------------------------------------------------------------
# Build the shared library
# --------------------------------------------------------------------------
sources = Glob("src/*.cpp")

lib_name = "libyggdrasil_peer{}{}".format(env["suffix"], env["SHLIBSUFFIX"])
library = env.SharedLibrary(
    "bin/{}".format(lib_name),
    source=sources,
)

Default(library)

# --------------------------------------------------------------------------
# Post-build: sign + copy to netfox addon with clean names
# --------------------------------------------------------------------------

# Map build target to simple deploy name
target = env["target"]
deploy_tag = "debug" if "debug" in target else "release"

if platform in ("macos", "ios"):
    # Simple deploy name: yggdrasil_peer.debug.framework / yggdrasil_peer.release.framework
    if platform == "ios":
        deploy_fw_name = "yggdrasil_peer.{}.ios".format(deploy_tag)
    else:
        deploy_fw_name = "yggdrasil_peer.{}".format(deploy_tag)
    framework_dir = "bin/{}.framework".format(deploy_fw_name)
    dest_framework = os.path.join(ADDON_BIN, "{}.framework".format(deploy_fw_name))

    def create_framework_and_deploy(target, source, env):
        src_dylib = str(source[0])
        fw_dir = framework_dir
        fw_bin = os.path.join(fw_dir, deploy_fw_name)

        if os.path.exists(fw_dir):
            shutil.rmtree(fw_dir)
        os.makedirs(fw_dir, exist_ok=True)

        shutil.copy2(src_dylib, fw_bin)

        subprocess.run([
            "install_name_tool", "-id",
            "@rpath/{}.framework/{}".format(deploy_fw_name, deploy_fw_name),
            fw_bin,
        ], check=True)

        plist = ('<?xml version="1.0" encoding="UTF-8"?>\n'
                 '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
                 ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                 '<plist version="1.0">\n<dict>\n'
                 '    <key>CFBundleExecutable</key>\n'
                 '    <string>{n}</string>\n'
                 '    <key>CFBundleIdentifier</key>\n'
                 '    <string>org.yggdrasil.gdextension.{n}</string>\n'
                 '    <key>CFBundleName</key>\n'
                 '    <string>{n}</string>\n'
                 '    <key>CFBundlePackageType</key>\n'
                 '    <string>FMWK</string>\n'
                 '    <key>CFBundleVersion</key>\n'
                 '    <string>1.0.0</string>\n'
                 '    <key>CFBundleShortVersionString</key>\n'
                 '    <string>1.0.0</string>\n'
                 '    <key>MinimumOSVersion</key>\n'
                 '    <string>12.0</string>\n'
                 '</dict>\n</plist>').format(n=deploy_fw_name)
        with open(os.path.join(fw_dir, "Info.plist"), "w") as f:
            f.write(plist)

        subprocess.run([
            "codesign", "--force", "--sign", "-",
            "--timestamp=none", fw_bin,
        ], check=True)
        print("[sign] {}".format(fw_bin))

        # Replace only this framework in addon bin dir
        os.makedirs(ADDON_BIN, exist_ok=True)
        if os.path.exists(dest_framework):
            shutil.rmtree(dest_framework)
        shutil.copytree(fw_dir, dest_framework)
        print("[deploy] {} -> {}".format(fw_dir, dest_framework))

        gdext_src = os.path.join(Dir("#").abspath, "yggdrasil_peer.gdextension")
        gdext_dst = os.path.join(ADDON_DIR, "yggdrasil.gdextension")
        if os.path.exists(gdext_src):
            shutil.copy2(gdext_src, gdext_dst)
            print("[deploy] gdextension -> {}".format(gdext_dst))

    deploy = env.Command(
        framework_dir, library, create_framework_and_deploy,
    )
    env.AlwaysBuild(deploy)
    Default(deploy)

else:
    # Simple deploy name: yggdrasil_peer.debug.x86_64.so / .dll etc.
    arch = env.get("arch", "x86_64")
    deploy_lib_name = "yggdrasil_peer.{}.{}{}".format(deploy_tag, arch, env["SHLIBSUFFIX"])
    dest_lib = os.path.join(ADDON_BIN, deploy_lib_name)

    def deploy_library(target, source, env):
        src = str(source[0])
        # Replace only this library in addon bin dir
        os.makedirs(ADDON_BIN, exist_ok=True)
        shutil.copy2(src, dest_lib)
        print("[deploy] {} -> {}".format(src, dest_lib))

        gdext_src = os.path.join(Dir("#").abspath, "yggdrasil_peer.gdextension")
        gdext_dst = os.path.join(ADDON_DIR, "yggdrasil.gdextension")
        if os.path.exists(gdext_src):
            shutil.copy2(gdext_src, gdext_dst)
            print("[deploy] gdextension -> {}".format(gdext_dst))

    deploy = env.Command(
        dest_lib, library, deploy_library,
    )
    env.AlwaysBuild(deploy)
    Default(deploy)
