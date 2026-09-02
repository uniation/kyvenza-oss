#!/usr/bin/env bash
# 构建随 Kyvenza 分发的 QEMU。
#
# **GPLv2 合规**:我们分发这份二进制,就必须能提供与之对应的完整源码与构建方式。
# 这个脚本连同 `patches/` 就是「构建方式」,必须留在仓库里、随发布一起公开。
# 任何对 QEMU 源码的改动都要落成 `patches/*.patch` 由脚本自动施加 ——
# 手工改一遍的版本没人能复现,也就无法履行随附义务。
#
# 与 spike 里那份 `spike/win11arm/build-qemu.sh` 的区别:那份是为了验证,开了
# SPICE 和一堆调试便利;这份是**分发用的最小构建**。砍掉的每一项都对应一条理由,
# 见下面的 configure 段落 —— 别为了"以后可能用得上"把它们加回来,每一个都是要
# 随包分发、逐个签名、并承担其许可义务的动态库。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$(cd "$(dirname "$0")" && pwd)"

QEMU_VERSION="${QEMU_VERSION:-11.1.0}"
# 上游发布件的 sha256。换版本时必须一起更新,否则脚本会拒绝构建。
#
# 这一条回答的是"我们分发的到底是哪份源码" —— 任何人拿这个脚本重建,拿到的
# 都是同一份输入。**它不是对上游真实性的独立背书**:qemu.org 只发 GPG .sig、
# 不发 sha256 文件,这个值是我们自己算的(下载件已按体积 + 字节区间哈希与
# download.qemu.org 比对一致)。要更强的保证,应改成校验 .sig 与 QEMU 发布密钥。
QEMU_SHA256="${QEMU_SHA256:-6ee1d1a61f68212476b27108c26da5f449dc09b626d42f8279ba0dc2e08fa858}"

WORK="${QEMU_BUILD_DIR:-${ROOT}/.local/qemu}"
SRC="${WORK}/qemu-${QEMU_VERSION}"
BUILD="${WORK}/build"
PREFIX="${WORK}/install"
TARBALL="${WORK}/qemu-${QEMU_VERSION}.tar.xz"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

mkdir -p "$WORK"

# ── 取源码 ─────────────────────────────────────────────────────────
if [ ! -d "$SRC" ]; then
    if [ ! -f "$TARBALL" ]; then
        # 允许从本地已有的 spike 产物复制,省一次跨洋下载。spike 的 work/ 是
        # 临时目录、随时可能被清掉,所以这里只是机会主义的复用,缺了就下载。
        LOCAL="${ROOT}/spike/win11arm/work/build/qemu-${QEMU_VERSION}.tar.xz"
        if [ -f "$LOCAL" ]; then
            echo "==> 复用本地 tarball $LOCAL"
            cp "$LOCAL" "$TARBALL"
        else
            echo "==> 下载 qemu-${QEMU_VERSION}.tar.xz"
            curl -fL --retry 3 -o "$TARBALL" \
                "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz"
        fi
    fi
    echo "==> 校验 tarball"
    actual="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
    if [ "$actual" != "$QEMU_SHA256" ]; then
        echo "sha256 不匹配,拒绝构建" >&2
        echo "  期望 ${QEMU_SHA256}" >&2
        echo "  实际 ${actual}" >&2
        exit 1
    fi
    echo "==> 解包"
    tar -xf "$TARBALL" -C "$WORK"
fi

# ── 打补丁 ─────────────────────────────────────────────────────────
# `patch -N` 让脚本可以反复跑(已打过的跳过)。
shopt -s nullglob
for p in "${DIR}"/patches/*.patch; do
    if patch -p1 -N -s --dry-run -d "$SRC" < "$p" >/dev/null 2>&1; then
        echo "==> 打补丁 $(basename "$p")"
        patch -p1 -N -s -d "$SRC" < "$p"
    elif patch -p1 -R -s --dry-run -d "$SRC" < "$p" >/dev/null 2>&1; then
        echo "==> 已打过,跳过 $(basename "$p")"
    else
        echo "补丁打不上(源码版本可能变了): $p" >&2
        exit 1
    fi
done
shopt -u nullglob

# ── configure ──────────────────────────────────────────────────────
mkdir -p "$BUILD"
cd "$BUILD"

if [ ! -f config-host.mak ]; then
    echo "==> configure(分发用最小特性集)"
    # ⚠️ TCG 不能关(踩过)。Win11 ARM 走 HVF、确实用不到 TCG 翻译,但
    #    `--disable-tcg` 会让 meson 的 `specific_ss`(按目标编译的那组源码)整个
    #    不落地,`hw/intc/arm_gicv3_hvf.c` 只剩 stub(build.ninja 里只有
    #    arm_gicv3_hvf_stub.c.o),启动直接报 "unknown type 'hvf-arm-gicv3'"。
    #    TCG 本身不引入任何动态库(capstone 已单独关掉),留着只是二进制大一些。
    #
    # ⚠️ spice 与 spice-protocol 必须分开看,别一起关(踩过):
    #   --disable-spice          关掉 SPICE server,省下 libspice-server 与整套
    #                            gstreamer 依赖(显示走我们自己的 RFB 客户端)
    #   --enable-spice-protocol  只是一组头文件,不引入任何动态库,但**剪贴板依赖它** ——
    #                            `-chardev qemu-vdagent` 是按 SPICE vdagent 协议实现的,
    #                            两个一起关会得到 "'qemu-vdagent' is not a valid char
    #                            driver name",剪贴板直接没了。
    # 系统自带 python3(3.9)缺 tomli,configure 会直接罢工;用 Homebrew 的。
    "${SRC}/configure" \
        --python="$(command -v /opt/homebrew/bin/python3 || command -v python3)" \
        --prefix="$PREFIX" \
        --target-list=aarch64-softmmu \
        --enable-hvf \
        --enable-slirp \
        --enable-vnc \
        --enable-tpm \
        --audio-drv-list=coreaudio \
        --enable-tcg \
        --disable-spice \
        --enable-spice-protocol \
        --disable-cocoa --disable-gtk --disable-sdl --disable-curses --disable-vte \
        --disable-opengl --disable-virglrenderer \
        --disable-capstone \
        --disable-libssh --disable-libusb --disable-usb-redir \
        --disable-smartcard --disable-u2f --disable-canokey \
        --disable-gnutls --disable-nettle --disable-gcrypt \
        --disable-vnc-jpeg --disable-vnc-sasl --disable-png \
        --disable-curl --disable-libiscsi --disable-libnfs --disable-rbd \
        --disable-zstd --disable-lzo --disable-snappy --disable-bzip2 --disable-lzfse \
        --disable-guest-agent \
        --disable-gio --disable-dbus-display \
        --disable-seccomp \
        --disable-virtfs --disable-vde --disable-netmap --disable-l2tpv3 \
        --disable-attr --disable-brlapi --disable-auth-pam \
        --disable-libdaxctl --disable-libpmem \
        --disable-fuse --disable-fuse-lseek \
        --disable-plugins --disable-replication --disable-libcbor \
        --disable-docs --disable-debug-info
fi

echo "==> build (-j${JOBS})"
ninja -j "$JOBS"

echo "==> install → ${PREFIX}"
ninja install

echo
"${PREFIX}/bin/qemu-system-aarch64" --version | head -1
echo
echo "非系统动态库依赖(每一个都要随包分发并签名):"
otool -L "${PREFIX}/bin/qemu-system-aarch64" | tail -n +2 | awk '{print $1}' \
    | grep -v -e '^/usr/lib/' -e '^/System/' || echo "  (无)"
