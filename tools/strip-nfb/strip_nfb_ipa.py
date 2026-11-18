#!/usr/bin/env python3
"""Turn an IPA that already has NeoFreeBird injected back into a plain X IPA.

The Build Tweak workflow injects with cyan, which always *adds* a weak load
command for each dylib, even when one with the same name is already there.
Building from a NeoFreeBird release IPA would therefore load BHTwitter.dylib
(and FLEX, zxPluginsInject) twice. This removes everything a NeoFreeBird
build adds, so the input behaves like a clean decrypted X IPA:

  * LC_LOAD_WEAK_DYLIB @rpath/{BHTwitter,libbhFLEX,zxPluginsInject}.dylib
    from the main executable. Only the Mach-O header changes: the entries
    are dropped from the load-command table, later commands move up, the
    freed bytes are zeroed and ncmds/sizeofcmds updated. No segment, code or
    data byte moves (a full rewrite with lief would shift __LINKEDIT);
  * Frameworks/{BHTwitter,libbhFLEX,zxPluginsInject}.dylib and
    Frameworks/CydiaSubstrate.framework (cyan adds it for the tweak);
  * BHTwitter.bundle and PlugIns/OpenTwitterSafariExtension.appex.

Every other zip entry is copied unchanged (attributes and compression kept).
A plain X IPA passes through untouched.

    python3 tools/strip-nfb/strip_nfb_ipa.py IN.ipa [OUT.ipa]   # OUT defaults to IN
"""

import os
import plistlib
import shutil
import struct
import sys
import tempfile
import zipfile

INJECTED_DYLIBS = ("BHTwitter.dylib", "libbhFLEX.dylib", "zxPluginsInject.dylib")
INJECTED_COMMANDS = {f"@rpath/{name}" for name in INJECTED_DYLIBS}

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
HEADER_64 = 32  # sizeof(struct mach_header_64)


def removed_prefixes(app_root):
    prefixes = [f"{app_root}Frameworks/{name}" for name in INJECTED_DYLIBS]
    prefixes += [
        f"{app_root}Frameworks/CydiaSubstrate.framework/",
        f"{app_root}BHTwitter.bundle/",
        f"{app_root}PlugIns/OpenTwitterSafariExtension.appex/",
    ]
    return prefixes


def strip_executable(data):
    """Return (new executable bytes, removed command names).

    Thin little-endian arm64 Mach-O only (what X ships); anything else stops
    the build rather than guessing.
    """
    magic, _, _, _, ncmds, sizeofcmds = struct.unpack_from("<IiiIII", data, 0)
    if magic != MH_MAGIC_64:
        sys.exit(f"[!] expected a thin 64-bit Mach-O executable, magic {magic:#x}")
    end = HEADER_64 + sizeofcmds

    kept, removed = [], []
    offset = HEADER_64
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmdsize < 8 or offset + cmdsize > end:
            sys.exit(f"[!] malformed load command at {offset:#x}")
        raw = data[offset:offset + cmdsize]
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            name_offset = struct.unpack_from("<I", raw, 8)[0]
            name = raw[name_offset:].split(b"\0", 1)[0].decode("utf-8", "replace")
            if name in INJECTED_COMMANDS:
                removed.append(name)
                offset += cmdsize
                continue
        kept.append(raw)
        offset += cmdsize

    if not removed:
        return data, removed

    table = b"".join(kept)
    out = bytearray(data)
    struct.pack_into("<II", out, 16, len(kept), len(table))
    out[HEADER_64:end] = table + b"\0" * (sizeofcmds - len(table))
    return bytes(out), removed


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    source = sys.argv[1]
    target = sys.argv[2] if len(sys.argv) == 3 else source

    with zipfile.ZipFile(source) as z:
        names = z.namelist()
        app = next((n.split("/")[1] for n in names
                    if n.startswith("Payload/") and n.split("/")[1].endswith(".app")), None)
        if not app:
            sys.exit("[!] no Payload/*.app in the IPA")
        root = f"Payload/{app}/"
        exe_path = root + plistlib.loads(z.read(root + "Info.plist"))["CFBundleExecutable"]

        new_exe, removed_commands = strip_executable(z.read(exe_path))
        prefixes = removed_prefixes(root)
        dropped = [n for n in names if any(n == p or n.startswith(p) for p in prefixes)]

        if not removed_commands and not dropped:
            print("[*] no NeoFreeBird injection found; IPA left as is")
            if target != source:
                shutil.copyfile(source, target)
            return

        fd, tmp_out = tempfile.mkstemp(suffix=".ipa", dir=os.path.dirname(os.path.abspath(target)))
        os.close(fd)
        with zipfile.ZipFile(tmp_out, "w", allowZip64=True) as out:
            for info in z.infolist():
                if info.filename in dropped:
                    continue
                data = new_exe if info.filename == exe_path else z.read(info)
                out.writestr(info, data, compress_type=info.compress_type)
        os.replace(tmp_out, target)

    top_level = sorted({n[len(root):].split("/")[0] if not n[len(root):].startswith(("Frameworks/", "PlugIns/"))
                        else "/".join(n[len(root):].split("/")[:2]) for n in dropped})
    print(f"[*] removed load commands: {', '.join(removed_commands) or 'none'}")
    print(f"[*] removed {len(dropped)} files: {', '.join(top_level)}")


if __name__ == "__main__":
    main()
