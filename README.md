# kyvenza-oss

Build recipes and patches for the open source components that
[Kyvenza](https://kyvenza.com) distributes inside its application bundle.

## What this repository is

Kyvenza is a commercial, closed-source virtual machine app for Apple Silicon.
To run Windows guests it bundles QEMU, which is licensed under the GPL, along
with a few LGPL-licensed libraries. Those licenses oblige us to hand over the
corresponding source code **and the scripts used to control compilation**
(GPLv2 section 3). This repository is the second half of that: the scripts, the
patches, and a per-release record of exactly what we shipped.

**This is not Kyvenza's source code.** Kyvenza itself is closed source and none
of it is here. What is here is how we build the third-party components we
redistribute, so that anyone can reproduce them and replace them in an
installed copy of the app.

## Where the actual sources are

The upstream tarballs are large and are not stored in git. Complete source
archives are published per release, at:

```
https://download.kyvenza.com/source/<version>/
```

Each directory contains the exact QEMU release we built, the LGPL library
sources, the Homebrew formulae we built them with, these scripts, and a
`SHA256SUMS` covering everything. The `releases/` directory in this repository
keeps a git-tracked copy of each release's `SHA256SUMS`, so the delivered bytes
can be checked against a record we cannot quietly rewrite.

You can also request the sources by writing to support@kyvenza.com; we honour
that offer (GPLv2 section 3(b)) for at least three years after we stop
distributing the release in question.

## Layout

```
scripts/build_qemu.sh        configure and build the QEMU we ship
scripts/build_firmware.sh    build the guest UEFI firmware (EDK II, Secure Boot)
scripts/stage_helpers.sh     lay the binaries out inside Kyvenza.app
scripts/sign_helpers.sh      code sign them
scripts/collect_sources.sh   assemble the source archive published per release
qemu/patches/                patches applied to QEMU, in filename order
releases/<version>/          SHA256SUMS for that release's source archive
```

Tags are named `v<app version>` and mark the state of these scripts for that
release of Kyvenza.

## Rebuilding

`build_qemu.sh` expects a Homebrew toolchain on Apple Silicon: `meson`,
`ninja`, `pkg-config`, `glib`, `pixman`, `libslirp`, and a Python 3.10+
interpreter (macOS's system Python 3.9 lacks `tomli` and QEMU's configure will
refuse it).

```
QEMU_BUILD_DIR=/some/work/dir ./scripts/build_qemu.sh
```

To use your own build inside an installed copy of Kyvenza, copy the resulting
`qemu-system-aarch64` over `Kyvenza.app/Contents/Helpers/`, then re-sign the
bundle:

```
codesign --force --deep --sign - /Applications/Kyvenza.app
```

The same works for the LGPL dylibs in `Contents/Frameworks/`; their install
names are rewritten to `@loader_path`, so a replacement is picked up with no
further changes. This applies to copies downloaded from kyvenza.com. Mac App
Store builds are re-signed by Apple and validated against a receipt, so a
modified bundle will not launch as a Mac App Store app.

## How QEMU relates to Kyvenza

Kyvenza runs QEMU as a separate process, started with fork/exec. It is never
linked into the Kyvenza binary, and the two communicate only over QEMU's own
published protocols: QMP for control and RFB (VNC) for the display, plus
command-line arguments and standard I/O. Kyvenza's RFB client is our own code
and links no GPL library.

Nothing in Kyvenza's license terms restricts the rights the GPL and LGPL grant
you over these components. If you find a gap in any of this, please open an
issue or write to support@kyvenza.com — incomplete compliance is a bug and we
want to fix it.

---

© Uniation Software Co., Ltd. The scripts in this repository are published to
satisfy our obligations under the GPL and LGPL. The components they build are
governed by their own licenses.
