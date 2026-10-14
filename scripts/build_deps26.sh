#!/usr/bin/env bash
# 把随包 dylib 里「Homebrew 只给新系统出 bottle」的那几个,按 macOS 26.0 部署目标从源码重编。
#
# 为什么要有这个脚本:
#   Homebrew 现在只为最新的 macOS 出 bottle(glib 的 bottle 列表里只有 arm64_golden_gate)。
#   在 macOS 27 的机器上 `brew upgrade` 之后,libglib / libgobject / libgmodule / libgio /
#   libpcre2-8 / libcrypto 的 Mach-O `minos` 都成了 27.0,而 QEMU 本体和 Info.plist 的
#   KyvenzaWindowsMinimumSystemVersion 是 26.0 —— macOS 26 上 dyld 直接拒绝加载,
#   用户能建 Windows 虚拟机却起不来。stage_helpers.sh 末尾的守卫会拦住这种打包。
#
# 为什么不是改 minos 头:vtool 能把数字改成 26.0,但那只是改标签,不保证这些库没用到
# 27 才有的符号。用 MACOSX_DEPLOYMENT_TARGET=26.0 重编,由编译器按可用性给新 API 加弱链接
# 或直接报错,这才是「26 上能跑」的依据。
#
# 产物:.local/qemu/deps26/lib/*.dylib。stage_helpers.sh 组包时按文件名覆盖进 Frameworks。
# 版本与 sha256 在下面钉死;换版本要同步 collect_sources.sh 与 Open Source Notices。
#
# 用法: bash scripts/qemu/build_deps26.sh        (已有同版本产物就跳过)
#       FORCE=1 bash scripts/qemu/build_deps26.sh (强制重编)

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

DEPLOYMENT_TARGET="26.0"
GLIB_VERSION="2.90.1"
GLIB_URL="https://download.gnome.org/sources/glib/2.90/glib-${GLIB_VERSION}.tar.xz"
GLIB_SHA256="93c941aa17d5eb1d53fe838365f29a8b4e539c222a256d974ec8f30fc413e396"
PCRE2_VERSION="10.49"
PCRE2_URL="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.bz2"
PCRE2_SHA256="53c156e1ba416a20da8e65395daa132da0d80e76910424caca3fcdae7831d384"
OPENSSL_VERSION="4.0.3"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_SHA256="325b5c806167c13b40b1ffeadfe0248197c00eccc4cf123ec1e28d2d2fd216d9"

WORK="${ROOT}/.local/qemu/deps26-build"
PREFIX="${ROOT}/.local/qemu/deps26"
STAMP="${PREFIX}/build.stamp"

die() { echo "build_deps26: $*" >&2; exit 1; }

# 戳里写版本与目标,以及本脚本自身的哈希:脚本改了(编译参数变了)就必须重编。
WANT_STAMP="target=${DEPLOYMENT_TARGET} glib=${GLIB_VERSION} pcre2=${PCRE2_VERSION} openssl=${OPENSSL_VERSION} script=$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')"
if [ "${FORCE:-0}" != "1" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT_STAMP" ]; then
    echo "build_deps26: 已是最新(${WANT_STAMP%% script=*}),跳过"
    exit 0
fi

command -v meson >/dev/null || die "缺 meson(brew install meson)"
command -v ninja >/dev/null || die "缺 ninja(brew install ninja)"
command -v pkg-config >/dev/null || die "缺 pkg-config(brew install pkgconf)"
GETTEXT_PREFIX="$(brew --prefix gettext 2>/dev/null)" || die "缺 gettext(brew install gettext):glib 要链 libintl"

# libintl 不重编:Homebrew 的 gettext 1.0 是 minos 26.0,可以直接用。这里再核一遍,
# 哪天它也升到 27 了,在这里就停下,而不是等到组包守卫才发现。
LIBINTL_MINOS="$(otool -l "${GETTEXT_PREFIX}/lib/libintl.8.dylib" | awk '/LC_BUILD_VERSION/{x=1} x && $1=="minos"{print $2; exit}')"
case "$LIBINTL_MINOS" in
    26.*|15.*|14.*|13.*) ;;
    *) die "Homebrew 的 libintl 要求 macOS ${LIBINTL_MINOS},高于 ${DEPLOYMENT_TARGET},需要把 gettext 也纳入这个脚本" ;;
esac

# 下载并校验。已存在且哈希正确就复用。
fetch() {
    local url="$1" dest="$2" want="$3"
    if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | awk '{print $1}')" = "$want" ]; then
        return
    fi
    rm -f "$dest"
    echo "  下载 $(basename "$dest")"
    curl -fsSL --retry 3 -o "$dest" "$url"
    local have; have="$(shasum -a 256 "$dest" | awk '{print $1}')"
    [ "$have" = "$want" ] || { rm -f "$dest"; die "$(basename "$dest") 的 sha256 不符(期望 ${want},实际 ${have})"; }
}

rm -rf "$PREFIX" "${WORK}"
mkdir -p "$PREFIX" "$WORK" "${ROOT}/.local/qemu/deps26-src"
SRC="${ROOT}/.local/qemu/deps26-src"

echo "==> 下载源码"
fetch "$PCRE2_URL" "${SRC}/pcre2-${PCRE2_VERSION}.tar.bz2" "$PCRE2_SHA256"
fetch "$GLIB_URL" "${SRC}/glib-${GLIB_VERSION}.tar.xz" "$GLIB_SHA256"
fetch "$OPENSSL_URL" "${SRC}/openssl-${OPENSSL_VERSION}.tar.gz" "$OPENSSL_SHA256"

# 所有目标一致:部署目标 26.0,只出 arm64(app 本身只支持 Apple Silicon)。
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export CFLAGS="-mmacosx-version-min=${DEPLOYMENT_TARGET} -arch arm64 -O2"
export LDFLAGS="-mmacosx-version-min=${DEPLOYMENT_TARGET} -arch arm64"
# 不让 Homebrew 的 pkg-config 目录混进来:否则 glib 会去链 Homebrew 的 pcre2(minos 27)。
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR || true

JOBS="$(sysctl -n hw.ncpu)"

echo "==> pcre2 ${PCRE2_VERSION}"
tar -xf "${SRC}/pcre2-${PCRE2_VERSION}.tar.bz2" -C "$WORK"
(
    cd "${WORK}/pcre2-${PCRE2_VERSION}"
    ./configure --prefix="$PREFIX" --disable-static --enable-shared --enable-jit >/dev/null
    make -j"$JOBS" >/dev/null
    make install >/dev/null
)

echo "==> glib ${GLIB_VERSION}"
tar -xf "${SRC}/glib-${GLIB_VERSION}.tar.xz" -C "$WORK"
(
    cd "${WORK}/glib-${GLIB_VERSION}"
    # libffi 用系统那份(/usr/lib/libffi.dylib),和之前 Homebrew 版 glib 一样。SDK 里只有
    # libffi.tbd 与头文件、没有 .pc,meson 找不到就会**悄悄**回退去编一份自己的 libffi
    # (多出一个 libffi.8.dylib 进包),所以这里手写一个 .pc,并用 --wrap-mode=nofallback
    # 禁止任何子项目回退:找不到依赖时直接失败,而不是换一个别的库。
    SDK="$(xcrun --show-sdk-path)"
    PC_DIR="${WORK}/pc"
    mkdir -p "$PC_DIR"
    cat > "${PC_DIR}/libffi.pc" <<PC
Name: libffi
Description: Library supporting Foreign Function Interfaces (system)
Version: 3.4
Libs: -L${SDK}/usr/lib -lffi
Cflags: -I${SDK}/usr/include/ffi
PC
    # libintl 同理:用 Homebrew 的 gettext(真的 libintl),不要 glib 自带的 proxy-libintl。
    PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig:${PC_DIR}" \
    meson setup _build \
        --prefix="$PREFIX" --libdir=lib \
        --buildtype=release --wrap-mode=nofallback \
        -Dc_args="-mmacosx-version-min=${DEPLOYMENT_TARGET} -I${GETTEXT_PREFIX}/include" \
        -Dc_link_args="-mmacosx-version-min=${DEPLOYMENT_TARGET} -L${GETTEXT_PREFIX}/lib" \
        -Dcpp_args="-mmacosx-version-min=${DEPLOYMENT_TARGET} -I${GETTEXT_PREFIX}/include" \
        -Dcpp_link_args="-mmacosx-version-min=${DEPLOYMENT_TARGET} -L${GETTEXT_PREFIX}/lib" \
        -Dobjc_args="-mmacosx-version-min=${DEPLOYMENT_TARGET} -I${GETTEXT_PREFIX}/include" \
        -Dobjc_link_args="-mmacosx-version-min=${DEPLOYMENT_TARGET} -L${GETTEXT_PREFIX}/lib" \
        -Dtests=false -Dintrospection=disabled -Dglib_debug=disabled \
        -Dnls=enabled -Dman-pages=disabled -Ddocumentation=false \
        -Dsysprof=disabled -Dlibmount=disabled -Dselinux=disabled -Dxattr=false \
        > "${WORK}/meson-setup.log" 2>&1 || { tail -30 "${WORK}/meson-setup.log" >&2; die "glib 的 meson setup 失败"; }
    meson compile -C _build -j "$JOBS" >/dev/null
    meson install -C _build >/dev/null
)

echo "==> openssl ${OPENSSL_VERSION}(只要 libcrypto,swtpm 用)"
tar -xf "${SRC}/openssl-${OPENSSL_VERSION}.tar.gz" -C "$WORK"
(
    cd "${WORK}/openssl-${OPENSSL_VERSION}"
    ./Configure darwin64-arm64-cc shared no-tests --prefix="$PREFIX" --openssldir="${PREFIX}/ssl" \
        "-mmacosx-version-min=${DEPLOYMENT_TARGET}" >/dev/null
    make -j"$JOBS" build_libs >/dev/null
    make install_dev install_runtime_libs >/dev/null 2>&1 || make install_sw >/dev/null
)

echo "==> 校验产物的最低系统版本"
BAD=0
for lib in libglib-2.0.0 libgobject-2.0.0 libgmodule-2.0.0 libgio-2.0.0 libpcre2-8.0 libcrypto.4; do
    f="${PREFIX}/lib/${lib}.dylib"
    [ -f "$f" ] || { echo "  缺 ${lib}.dylib" >&2; BAD=1; continue; }
    minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{x=1} x && $1=="minos"{print $2; exit}')"
    echo "  ${lib}: minos ${minos}"
    case "$minos" in
        26.*|15.*|14.*|13.*) ;;
        *) BAD=1 ;;
    esac
done
# 回退检查:glib 不该链到我们自己目录里的 libintl / libffi(那是 meson 子项目回退的征兆)。
if otool -L "${PREFIX}/lib/libglib-2.0.0.dylib" "${PREFIX}/lib/libgobject-2.0.0.dylib" | grep -qE "${PREFIX}/lib/(libintl|libffi)"; then
    die "glib 链到了自己目录里的 libintl/libffi,说明 meson 回退去编了子项目"
fi
[ "$BAD" = "0" ] || die "产物的最低系统版本不是 ${DEPLOYMENT_TARGET},检查编译参数"

echo "$WANT_STAMP" > "$STAMP"
rm -rf "$WORK"
echo "build_deps26: 完成 → ${PREFIX}/lib"
