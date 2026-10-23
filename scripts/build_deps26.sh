#!/usr/bin/env bash
# 把随包的全部 dylib 与 swtpm,按 macOS 26.0 部署目标从固定的上游 tarball 重编。
#
# 为什么要有这个脚本:
#   Homebrew 现在只为最新的 macOS 出 bottle(glib 的 bottle 列表里只有 arm64_golden_gate)。
#   在 macOS 27 的机器上 `brew upgrade` / 新装之后,随包的每一个 Homebrew 二进制 Mach-O `minos`
#   都会成为 27.0,而 QEMU 本体和 Info.plist 的 KyvenzaWindowsMinimumSystemVersion 是 26.0 ——
#   macOS 26 上 dyld 直接拒绝加载,用户能建 Windows 虚拟机却起不来。stage_helpers.sh 末尾的
#   守卫会拦住这种打包。
#   起初只重编了 glib / pcre2 / libcrypto。2026-10-20 在一台新装 Homebrew 的 macOS 27 机器上,
#   pixman、libslirp、libtpms、json-glib、gettext、swtpm 也全是 27.0,当时只能从别的机器拷
#   升级前的旧 keg 过去,哪台机器 brew upgrade 一次就复发。所以现在随包的东西**一个都不再取自
#   Homebrew 的二进制**:stage_helpers.sh 会核对 Frameworks 里每个库、以及 swtpm,都是这里的产物。
#
# 为什么不是改 minos 头:vtool 能把数字改成 26.0,但那只是改标签,不保证这些库没用到
# 27 才有的符号。用 MACOSX_DEPLOYMENT_TARGET=26.0 重编,由编译器按可用性给新 API 加弱链接
# 或直接报错,这才是「26 上能跑」的依据。
#
# 产物:.local/qemu/deps26/{lib,bin}。stage_helpers.sh 组包时按文件名覆盖进 Frameworks,
# swtpm 直接取 bin/swtpm。
# 版本与 sha256 在下面钉死,collect_sources.sh 通过 `--print-sources` 读同一份,不另抄;
# 换版本要同步 Open Source Notices。
#
# 用法: bash scripts/qemu/build_deps26.sh                 (已有同版本产物就跳过)
#       FORCE=1 bash scripts/qemu/build_deps26.sh          (强制重编)
#       bash scripts/qemu/build_deps26.sh --print-sources  (给 collect_sources.sh 用)

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
# 下面六个的 URL 与 sha256 取自对应 Homebrew formula 的 stable 段(和以前随包的 bottle 同一份源码)。
GETTEXT_VERSION="1.0"
GETTEXT_URL="https://ftpmirror.gnu.org/gnu/gettext/gettext-${GETTEXT_VERSION}.tar.gz"
GETTEXT_SHA256="85d99b79c981a404874c02e0342176cf75c7698e2b51fe41031cf6526d974f1a"
PIXMAN_VERSION="0.46.4"
PIXMAN_URL="https://cairographics.org/releases/pixman-${PIXMAN_VERSION}.tar.gz"
PIXMAN_SHA256="d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c"
LIBSLIRP_VERSION="4.9.5"
LIBSLIRP_URL="https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v${LIBSLIRP_VERSION}/libslirp-v${LIBSLIRP_VERSION}.tar.gz"
LIBSLIRP_SHA256="f43e68b60b580647574ec4a0e2b6c600a56281e6c39f79426510832dc810f483"
JSON_GLIB_VERSION="1.10.8"
JSON_GLIB_URL="https://download.gnome.org/sources/json-glib/1.10/json-glib-${JSON_GLIB_VERSION}.tar.xz"
JSON_GLIB_SHA256="55c5c141a564245b8f8fbe7698663c87a45a7333c2a2c56f06f811ab73b212dd"
# GitHub 的 tag 归档,不带 configure,要 autoreconf(两个项目自己的 autogen.sh 就是这么做的)。
LIBTPMS_VERSION="0.10.2"
LIBTPMS_URL="https://github.com/stefanberger/libtpms/archive/refs/tags/v${LIBTPMS_VERSION}.tar.gz"
LIBTPMS_SHA256="edac03680f8a4a1c5c1d609a10e3f41e1a129e38ff5158f0c8deaedc719fb127"
SWTPM_VERSION="0.10.2"
SWTPM_URL="https://github.com/stefanberger/swtpm/archive/refs/tags/v${SWTPM_VERSION}.tar.gz"
SWTPM_SHA256="f61cf6f1e9bbcb4cefb30b70cafaf1c4df54c6961e65cfa63830e8ad0e220134"
# 只有头文件,不随包任何二进制。QEMU 的 qemu-vdagent(剪贴板与拖放)编译时要它,以前一直
# 靠构建机上碰巧装着的 Homebrew 版或 3d-spike 前缀,干净环境里 configure 直接失败。
# sha256 与上游发布的 .sha256sum 一致。
SPICE_PROTOCOL_VERSION="0.14.4"
SPICE_PROTOCOL_URL="https://www.spice-space.org/download/releases/spice-protocol-${SPICE_PROTOCOL_VERSION}.tar.xz"
SPICE_PROTOCOL_SHA256="04ffba610d9fd441cfc47dfaa135d70096e60b1046d2119d8db2f8ea0d17d912"

# 源码清单:名字|版本|URL|sha256|许可|本地文件名。collect_sources.sh 只认这一份。
# 本地文件名单列出来,是因为 GitHub 的 tag 归档 URL 末尾只有 v0.10.2.tar.gz,
# libtpms 与 swtpm 会撞名。
SOURCES="
pcre2|${PCRE2_VERSION}|${PCRE2_URL}|${PCRE2_SHA256}|BSD-3-Clause|pcre2-${PCRE2_VERSION}.tar.bz2
gettext|${GETTEXT_VERSION}|${GETTEXT_URL}|${GETTEXT_SHA256}|LGPL-2.1-or-later|gettext-${GETTEXT_VERSION}.tar.gz
glib|${GLIB_VERSION}|${GLIB_URL}|${GLIB_SHA256}|LGPL-2.1-or-later|glib-${GLIB_VERSION}.tar.xz
openssl|${OPENSSL_VERSION}|${OPENSSL_URL}|${OPENSSL_SHA256}|Apache-2.0|openssl-${OPENSSL_VERSION}.tar.gz
pixman|${PIXMAN_VERSION}|${PIXMAN_URL}|${PIXMAN_SHA256}|MIT|pixman-${PIXMAN_VERSION}.tar.gz
libslirp|${LIBSLIRP_VERSION}|${LIBSLIRP_URL}|${LIBSLIRP_SHA256}|BSD-3-Clause|libslirp-v${LIBSLIRP_VERSION}.tar.gz
json-glib|${JSON_GLIB_VERSION}|${JSON_GLIB_URL}|${JSON_GLIB_SHA256}|LGPL-2.1-or-later|json-glib-${JSON_GLIB_VERSION}.tar.xz
libtpms|${LIBTPMS_VERSION}|${LIBTPMS_URL}|${LIBTPMS_SHA256}|BSD-3-Clause|libtpms-${LIBTPMS_VERSION}.tar.gz
swtpm|${SWTPM_VERSION}|${SWTPM_URL}|${SWTPM_SHA256}|BSD-3-Clause|swtpm-${SWTPM_VERSION}.tar.gz
spice-protocol|${SPICE_PROTOCOL_VERSION}|${SPICE_PROTOCOL_URL}|${SPICE_PROTOCOL_SHA256}|BSD-3-Clause|spice-protocol-${SPICE_PROTOCOL_VERSION}.tar.xz
"

if [ "${1:-}" = "--print-sources" ]; then
    echo "$SOURCES" | sed '/^$/d'
    exit 0
fi

WORK="${ROOT}/.local/qemu/deps26-build"
PREFIX="${ROOT}/.local/qemu/deps26"
STAMP="${PREFIX}/build.stamp"
SRC="${ROOT}/.local/qemu/deps26-src"

die() { echo "build_deps26: $*" >&2; exit 1; }

# 戳里写版本与目标,以及本脚本自身的哈希:脚本改了(编译参数变了)就必须重编。
# collect_sources.sh 按 `<名字>=<版本> ` 在戳里核对,所以每项后面都要有空格。
WANT_STAMP="target=${DEPLOYMENT_TARGET} $(echo "$SOURCES" | awk -F'|' 'NF{printf "%s=%s ", $1, $2}')script=$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')"
if [ "${FORCE:-0}" != "1" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT_STAMP" ]; then
    echo "build_deps26: 已是最新(${WANT_STAMP%% script=*}),跳过"
    exit 0
fi

command -v meson >/dev/null || die "缺 meson(brew install meson)"
command -v ninja >/dev/null || die "缺 ninja(brew install ninja)"
command -v pkg-config >/dev/null || die "缺 pkg-config(brew install pkgconf)"
# libtpms / swtpm 的 GitHub 归档不带 configure。这些只是构建工具,不进包,minos 无所谓。
command -v autoreconf >/dev/null || die "缺 autoconf(brew install autoconf automake libtool)"
command -v automake >/dev/null || die "缺 automake(brew install automake)"
command -v glibtoolize >/dev/null || command -v libtoolize >/dev/null || die "缺 libtoolize(brew install libtool)"

# 下载并校验。已存在且哈希正确就复用。
fetch() {
    local url="$1" dest="$2" want="$3"
    if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | awk '{print $1}')" = "$want" ]; then
        return
    fi
    rm -f "$dest"
    echo "  下载 $(basename "$dest")"
    # ftpmirror.gnu.org 是随机轮询,轮到坏镜像就挂(collect_sources.sh 里踩过),先走固定站点。
    local urls="$url" u
    case "$url" in
        https://ftpmirror.gnu.org/*)
            urls="${url/ftpmirror.gnu.org/ftp.gnu.org} $url ${url/ftpmirror.gnu.org/mirrors.kernel.org}" ;;
    esac
    for u in $urls; do
        curl -fsSL --retry 3 --connect-timeout 15 --speed-limit 2048 --speed-time 20 -o "$dest" "$u" && break
        rm -f "$dest"
    done
    [ -f "$dest" ] || die "$(basename "$dest") 所有源都取不到"
    local have; have="$(shasum -a 256 "$dest" | awk '{print $1}')"
    [ "$have" = "$want" ] || { rm -f "$dest"; die "$(basename "$dest") 的 sha256 不符(期望 ${want},实际 ${have})"; }
}

rm -rf "$PREFIX" "${WORK}"
mkdir -p "$PREFIX" "$WORK" "$SRC"

echo "==> 下载源码"
echo "$SOURCES" | while IFS='|' read -r name version url sha license file; do
    [ -n "$name" ] || continue
    fetch "$url" "${SRC}/${file}" "$sha"
done

# 所有目标一致:部署目标 26.0,只出 arm64(app 本身只支持 Apple Silicon)。
# 头文件与库一律先找我们自己的前缀:后面的库都要链前面重编出来的那几个。
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export CFLAGS="-mmacosx-version-min=${DEPLOYMENT_TARGET} -arch arm64 -O2"
export CPPFLAGS="-I${PREFIX}/include"
export LDFLAGS="-mmacosx-version-min=${DEPLOYMENT_TARGET} -arch arm64 -L${PREFIX}/lib"

# pkg-config 只看我们自己的前缀和下面这个手写目录。**不让 Homebrew 的 pkg-config 目录混进来**:
# 否则 glib 会去链 Homebrew 的 pcre2,json-glib 会去链 Homebrew 的 glib(都是 minos 27)。
PC_DIR="${WORK}/pc"
mkdir -p "$PC_DIR"
SDK="$(xcrun --show-sdk-path)"
# libffi 用系统那份(/usr/lib/libffi.dylib),和之前 Homebrew 版 glib 一样。SDK 里只有
# libffi.tbd 与头文件、没有 .pc,meson 找不到就会**悄悄**回退去编一份自己的 libffi
# (多出一个 libffi.8.dylib 进包),所以这里手写一个 .pc,并用 --wrap-mode=nofallback
# 禁止任何子项目回退:找不到依赖时直接失败,而不是换一个别的库。
cat > "${PC_DIR}/libffi.pc" <<PC
Name: libffi
Description: Library supporting Foreign Function Interfaces (system)
Version: 3.4
Libs: -L${SDK}/usr/lib -lffi
Cflags: -I${SDK}/usr/include/ffi
PC
# swtpm 的 configure 无条件执行 `pkg-config --libs libtasn1`,但用到 libtasn1 的只有
# swtpm_cert,而它只在 --with-gnutls 时才编(我们 --without-gnutls,也不随包)。
# 所以给一个空的 .pc 让 configure 过去,不为一个不编的工具去装/编 libtasn1。
# 下面的产物检查会确认 swtpm 没有链到任何不在清单里的库。
cat > "${PC_DIR}/libtasn1.pc" <<PC
Name: libtasn1
Description: placeholder; only swtpm_cert uses it and swtpm_cert is not built
Version: 4.21.0
Libs:
Cflags:
PC
export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig:${PC_DIR}"
unset PKG_CONFIG_PATH || true

JOBS="$(sysctl -n hw.ncpu)"

# meson 项目的通用流程。所有 meson 项目都 --wrap-mode=nofallback,理由同上面的 libffi。
meson_build() {  # meson_build <源码目录> <日志名> [meson 选项...]
    local dir="$1" log="$2"; shift 2
    (
        cd "$dir"
        meson setup _build \
            --prefix="$PREFIX" --libdir=lib \
            --buildtype=release --wrap-mode=nofallback --default-library=shared \
            "$@" > "${WORK}/${log}-setup.log" 2>&1 \
            || { tail -30 "${WORK}/${log}-setup.log" >&2; die "${log} 的 meson setup 失败"; }
        meson compile -C _build -j "$JOBS" > "${WORK}/${log}-build.log" 2>&1 \
            || { tail -30 "${WORK}/${log}-build.log" >&2; die "${log} 编译失败"; }
        meson install -C _build >/dev/null
    )
}

# autotools 项目的通用流程。BUILD_SUBDIRS 可以只编其中几个子目录(按顺序),默认整个项目。
configure_build() {  # [BUILD_SUBDIRS="a b"] configure_build <源码目录> <日志名> [configure 选项...]
    local dir="$1" log="$2" sub; shift 2
    (
        cd "$dir"
        ./configure --prefix="$PREFIX" --disable-static --enable-shared "$@" \
            > "${WORK}/${log}-configure.log" 2>&1 \
            || { tail -30 "${WORK}/${log}-configure.log" >&2; die "${log} 的 configure 失败"; }
        for sub in ${BUILD_SUBDIRS:-.}; do
            make -C "$sub" -j"$JOBS" >> "${WORK}/${log}-build.log" 2>&1 \
                || { tail -30 "${WORK}/${log}-build.log" >&2; die "${log} 编译失败(${sub})"; }
        done
        for sub in ${BUILD_SUBDIRS:-.}; do
            make -C "$sub" install >> "${WORK}/${log}-install.log" 2>&1 \
                || { tail -30 "${WORK}/${log}-install.log" >&2; die "${log} 安装失败(${sub})"; }
        done
    )
}

# ── gettext 的 libintl ─────────────────────────────────────────────
# 只编 gettext-runtime(libintl 就在里面),不编 msgfmt 那一大套工具:那是 GPLv3、也不随包。
# am_cv_func_iconv_works:macOS 的 iconv 从 Sonoma 起过不了 configure 的自检,
# Homebrew 的 formula 也是这样绕的(savannah bug 66541)。
echo "==> gettext ${GETTEXT_VERSION}(libintl)"
tar -xf "${SRC}/gettext-${GETTEXT_VERSION}.tar.gz" -C "$WORK"
am_cv_func_iconv_works=yes configure_build "${WORK}/gettext-${GETTEXT_VERSION}/gettext-runtime" gettext \
    --disable-java --disable-csharp --disable-libasprintf \
    --without-emacs --without-git --without-cvs --without-xz

echo "==> pcre2 ${PCRE2_VERSION}"
tar -xf "${SRC}/pcre2-${PCRE2_VERSION}.tar.bz2" -C "$WORK"
configure_build "${WORK}/pcre2-${PCRE2_VERSION}" pcre2 --enable-jit

# libintl 用上面编的那份(真的 libintl),不要 glib 自带的 proxy-libintl。
echo "==> glib ${GLIB_VERSION}"
tar -xf "${SRC}/glib-${GLIB_VERSION}.tar.xz" -C "$WORK"
meson_build "${WORK}/glib-${GLIB_VERSION}" glib \
    -Dc_args="-mmacosx-version-min=${DEPLOYMENT_TARGET} -I${PREFIX}/include" \
    -Dc_link_args="-mmacosx-version-min=${DEPLOYMENT_TARGET} -L${PREFIX}/lib" \
    -Dcpp_args="-mmacosx-version-min=${DEPLOYMENT_TARGET} -I${PREFIX}/include" \
    -Dcpp_link_args="-mmacosx-version-min=${DEPLOYMENT_TARGET} -L${PREFIX}/lib" \
    -Dobjc_args="-mmacosx-version-min=${DEPLOYMENT_TARGET} -I${PREFIX}/include" \
    -Dobjc_link_args="-mmacosx-version-min=${DEPLOYMENT_TARGET} -L${PREFIX}/lib" \
    -Dtests=false -Dintrospection=disabled -Dglib_debug=disabled \
    -Dnls=enabled -Dman-pages=disabled -Ddocumentation=false \
    -Dsysprof=disabled -Dlibmount=disabled -Dselinux=disabled -Dxattr=false

echo "==> openssl ${OPENSSL_VERSION}(只要 libcrypto,swtpm / libtpms 用)"
tar -xf "${SRC}/openssl-${OPENSSL_VERSION}.tar.gz" -C "$WORK"
(
    cd "${WORK}/openssl-${OPENSSL_VERSION}"
    ./Configure darwin64-arm64-cc shared no-tests --prefix="$PREFIX" --openssldir="${PREFIX}/ssl" \
        "-mmacosx-version-min=${DEPLOYMENT_TARGET}" >/dev/null
    make -j"$JOBS" build_libs >/dev/null
    make install_dev install_runtime_libs >/dev/null 2>&1 || make install_sw >/dev/null
)

# 参数与 Homebrew formula 一致(它只多编测试与静态库)。
echo "==> pixman ${PIXMAN_VERSION}"
tar -xf "${SRC}/pixman-${PIXMAN_VERSION}.tar.gz" -C "$WORK"
meson_build "${WORK}/pixman-${PIXMAN_VERSION}" pixman \
    -Dtests=disabled -Ddemos=disabled -Dgtk=disabled -Dlibpng=disabled -Dopenmp=disabled

echo "==> libslirp ${LIBSLIRP_VERSION}"
tar -xf "${SRC}/libslirp-v${LIBSLIRP_VERSION}.tar.gz" -C "$WORK"
meson_build "${WORK}/libslirp-v${LIBSLIRP_VERSION}" libslirp

# Homebrew 版开了 introspection 与 man,那两样只产出开发用文件,不影响 dylib。
echo "==> json-glib ${JSON_GLIB_VERSION}"
tar -xf "${SRC}/json-glib-${JSON_GLIB_VERSION}.tar.xz" -C "$WORK"
meson_build "${WORK}/json-glib-${JSON_GLIB_VERSION}" json-glib \
    -Dintrospection=disabled -Ddocumentation=disabled -Dgtk_doc=disabled -Dman=false \
    -Dtests=false -Dconformance=false -Dinstalled_tests=false -Dnls=enabled

echo "==> libtpms ${LIBTPMS_VERSION}"
tar -xf "${SRC}/libtpms-${LIBTPMS_VERSION}.tar.gz" -C "$WORK"
(cd "${WORK}/libtpms-${LIBTPMS_VERSION}" && autoreconf --force --install > "${WORK}/libtpms-autoreconf.log" 2>&1) \
    || { tail -30 "${WORK}/libtpms-autoreconf.log" >&2; die "libtpms 的 autoreconf 失败"; }
configure_build "${WORK}/libtpms-${LIBTPMS_VERSION}" libtpms --with-openssl --with-tpm2

# 只编随包的 swtpm 本体(src/swtpm,连同它的 libswtpm_libtpms)。swtpm_setup / swtpm_localca /
# swtpm_cert 这些建 TPM 证书的工具我们不用,它们还会额外拉进 gmp、gnutls、libtasn1。
# Homebrew 的 formula 另打了一个补丁把 swtpm_cert 从 GnuTLS 换到 OpenSSL。那个补丁只改
# swtpm_cert,我们不编它、也不随包,所以用的是未改动的上游源码。
echo "==> swtpm ${SWTPM_VERSION}"
tar -xf "${SRC}/swtpm-${SWTPM_VERSION}.tar.gz" -C "$WORK"
(cd "${WORK}/swtpm-${SWTPM_VERSION}" && mkdir -p m4 && autoreconf --force --install > "${WORK}/swtpm-autoreconf.log" 2>&1) \
    || { tail -30 "${WORK}/swtpm-autoreconf.log" >&2; die "swtpm 的 autoreconf 失败"; }
BUILD_SUBDIRS="include src/utils src/swtpm" configure_build "${WORK}/swtpm-${SWTPM_VERSION}" swtpm \
    --with-openssl --without-gnutls --without-cuse --without-selinux --disable-tests

# 装到 share/pkgconfig 与 include/spice-1,build_qemu.sh 只把前者加进 PKG_CONFIG_PATH。
echo "==> spice-protocol ${SPICE_PROTOCOL_VERSION}(只有头文件)"
tar -xf "${SRC}/spice-protocol-${SPICE_PROTOCOL_VERSION}.tar.xz" -C "$WORK"
meson_build "${WORK}/spice-protocol-${SPICE_PROTOCOL_VERSION}" spice-protocol
[ -f "${PREFIX}/share/pkgconfig/spice-protocol.pc" ] || die "spice-protocol 没有装出 share/pkgconfig/spice-protocol.pc"

echo "==> 校验产物"
# 随包会用到的每一个产物。stage_helpers.sh 只会从这里取,少一个就是有个库还在用 Homebrew 的。
PRODUCTS="
lib/libintl.8.dylib
lib/libglib-2.0.0.dylib
lib/libgobject-2.0.0.dylib
lib/libgmodule-2.0.0.dylib
lib/libgio-2.0.0.dylib
lib/libpcre2-8.0.dylib
lib/libcrypto.4.dylib
lib/libpixman-1.0.dylib
lib/libslirp.0.dylib
lib/libjson-glib-1.0.0.dylib
lib/libtpms.0.dylib
lib/swtpm/libswtpm_libtpms.0.dylib
bin/swtpm
"
BAD=0
for rel in $PRODUCTS; do
    f="${PREFIX}/${rel}"
    [ -f "$f" ] || { echo "  缺 ${rel}" >&2; BAD=1; continue; }
    minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{x=1} x && $1=="minos"{print $2; exit}')"
    echo "  ${rel}: minos ${minos}"
    case "$minos" in
        26.*|15.*|14.*|13.*) ;;
        *) echo "  ${rel} 的 minos 是 ${minos},高于 ${DEPLOYMENT_TARGET}" >&2; BAD=1 ;;
    esac
    # 不许链到本前缀以外的非系统库:那说明有个依赖是从 Homebrew 找到的,组包时会把它的
    # 27.0 拷贝一起带进去(或者在别的机器上根本找不到)。
    if otool -L "$f" | tail -n +2 | awk '{print $1}' \
            | grep -v -e '^/usr/lib/' -e '^/System/' -e "^${PREFIX}/lib/" | grep -q .; then
        echo "  ${rel} 链到了本前缀以外的库:" >&2
        otool -L "$f" | tail -n +2 | awk '{print $1}' \
            | grep -v -e '^/usr/lib/' -e '^/System/' -e "^${PREFIX}/lib/" | sed 's/^/    /' >&2
        BAD=1
    fi
done
# 回退检查:glib 必须链上面编的 libintl.8,而且不该链到自己目录里的 libffi(那是 meson
# 子项目回退的征兆;proxy-libintl 回退出来的也不叫 libintl.8)。
otool -L "${PREFIX}/lib/libglib-2.0.0.dylib" | grep -qF "${PREFIX}/lib/libintl.8.dylib" \
    || die "glib 没有链到 ${PREFIX}/lib/libintl.8.dylib"
if otool -L "${PREFIX}/lib/libglib-2.0.0.dylib" "${PREFIX}/lib/libgobject-2.0.0.dylib" | grep -qE "${PREFIX}/lib/libffi"; then
    die "glib 链到了自己目录里的 libffi,说明 meson 回退去编了子项目"
fi
[ "$BAD" = "0" ] || die "产物不合格(见上),检查编译参数"

echo "$WANT_STAMP" > "$STAMP"
rm -rf "$WORK"
echo "build_deps26: 完成 → ${PREFIX}"
