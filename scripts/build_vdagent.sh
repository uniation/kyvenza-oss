#!/usr/bin/env bash
# 为 Windows on ARM 客体构建 SPICE vdagent(vdagent.exe + vdservice.exe)。
#
# **为什么需要这个脚本:全世界没有现成的 ARM64 版本。** 上游 spice-space 只发
# x86/x64;flexVDI 的 rpm spec 只构建 mingw32/mingw64;UTM 的 NSIS 安装器里 ARM64
# 分支写好了,但同仓库 Makefile 那一行是 `# TODO: not available`;virtio-win ISO
# 全盘没有任何 vdagent。所以只能自己交叉编译。
#
# **GPLv2 合规**:vd_agent 是 GPLv2+,我们把二进制放进驱动光盘分发,就必须能提供
# 对应的完整源码与构建方式。这个脚本连同 `patches/` 就是「构建方式」
# (GPLv2 §3 明确包含"用于控制编译的脚本"),必须留在仓库里、随发布一起公开。
# 对上游源码的任何改动都要落成 `patches/*.patch` 由脚本自动施加 —— 手工改一遍的
# 版本没人能复现,也就无法履行随附义务。
#
# 与 QEMU 的关系:两者都是 GPLv2、都以独立程序的形式分发,合规叙事完全同构。
# 区别在于 vdagent 跑在**客体里**,连宿主进程都不是,聚合的论证只会更强。
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"
WORK="${VDAGENT_BUILD_DIR:-${ROOT}/.local/vdagent}"
PREFIX="${WORK}/out"
SRC="${WORK}/src"
HOST=aarch64-w64-mingw32
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# ── 上游发布件与校验和 ─────────────────────────────────────────────
# 换版本时 sha256 必须一起更新,否则脚本会拒绝构建。任何人拿这个脚本重建,
# 拿到的都是同一份输入。
#
# llvm-mingw 是**唯一**能 target aarch64-w64-mingw32 的工具链:Homebrew 的
# mingw-w64 只有 x86,GCC 根本没有这个 target,没有替代品。
LLVM_MINGW_VER=20260826
LLVM_MINGW_DIR="llvm-mingw-${LLVM_MINGW_VER}-ucrt-macos-universal"
LLVM_MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VER}/${LLVM_MINGW_DIR}.tar.xz"
LLVM_MINGW_SHA=48bedd161f14ae25a3646cb750b57ee3188e97e34bd3c52240c1810aa74d6a7f

VDAGENT_VER=0.10.0
VDAGENT_URL="https://www.spice-space.org/download/windows/vdagent/vdagent-win-${VDAGENT_VER}/vdagent-win-${VDAGENT_VER}.tar.xz"
# 与上游同目录下 sha256sum 文件里的值一致(已核对)。
VDAGENT_SHA=918be9638164212d1787f9a9107584c5445adc638e592ae9260ec0797b25020d

ZLIB_VER=1.3.2
ZLIB_URL="https://zlib.net/zlib-${ZLIB_VER}.tar.gz"
ZLIB_SHA=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16

LIBPNG_VER=1.6.58
LIBPNG_URL="https://download.sourceforge.net/libpng/libpng-${LIBPNG_VER}.tar.xz"
LIBPNG_SHA=28eb403f51f0f7405249132cecfe82ea5c0ef97f1b32c5a65828814ae0d34775

die() { echo "$*" >&2; exit 1; }

fetch() {
    local url="$1" out="$2" want="$3"
    if [ ! -f "$out" ]; then
        echo "==> 下载 $(basename "$out")"
        curl -fL --retry 3 -o "$out" "$url"
    fi
    local got
    got="$(shasum -a 256 "$out" | awk '{print $1}')"
    [ "$got" = "$want" ] || die "sha256 不匹配,拒绝构建: $out
  期望 $want
  实际 $got"
}

mkdir -p "${SRC}" "${PREFIX}/lib/pkgconfig" "${PREFIX}/include"

# ── 工具链 ─────────────────────────────────────────────────────────
fetch "$LLVM_MINGW_URL" "${WORK}/${LLVM_MINGW_DIR}.tar.xz" "$LLVM_MINGW_SHA"
[ -d "${WORK}/${LLVM_MINGW_DIR}" ] || tar -xf "${WORK}/${LLVM_MINGW_DIR}.tar.xz" -C "${WORK}"

export PATH="${WORK}/${LLVM_MINGW_DIR}/bin:${PATH}"
# 只让 pkg-config 看见我们自己交叉编译的那几个 .pc。不隔离的话它会找到宿主
# Homebrew 里的 zlib/libpng,链接阶段才炸,而且报错完全指不到成因。
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig"

command -v "${HOST}-clang" >/dev/null || die "工具链里没有 ${HOST}-clang"

# ── zlib(静态)────────────────────────────────────────────────────
if [ ! -f "${PREFIX}/lib/libz.a" ]; then
    fetch "$ZLIB_URL" "${SRC}/zlib-${ZLIB_VER}.tar.gz" "$ZLIB_SHA"
    rm -rf "${SRC}/zlib-${ZLIB_VER}"
    tar -xf "${SRC}/zlib-${ZLIB_VER}.tar.gz" -C "${SRC}"
    (
        cd "${SRC}/zlib-${ZLIB_VER}"
        # 注意 win32/Makefile.gcc 里的 PREFIX 是**工具前缀**(拼成 $(PREFIX)gcc),
        # 不是安装路径。传成安装路径会得到 "gcc: command not found"。
        make -f win32/Makefile.gcc PREFIX="${HOST}-" libz.a -j"${JOBS}"
        cp libz.a "${PREFIX}/lib/"
        cp zlib.h zconf.h "${PREFIX}/include/"
    )
    # win32/Makefile.gcc 不生成 .pc,而 vd_agent 的 configure 用 pkg-config 找它。
    cat > "${PREFIX}/lib/pkgconfig/zlib.pc" <<EOF
prefix=${PREFIX}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library
Version: ${ZLIB_VER}
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF
fi

# ── libpng(静态)──────────────────────────────────────────────────
if [ ! -f "${PREFIX}/lib/libpng16.a" ]; then
    fetch "$LIBPNG_URL" "${SRC}/libpng-${LIBPNG_VER}.tar.xz" "$LIBPNG_SHA"
    rm -rf "${SRC}/libpng-${LIBPNG_VER}"
    tar -xf "${SRC}/libpng-${LIBPNG_VER}.tar.xz" -C "${SRC}"
    (
        cd "${SRC}/libpng-${LIBPNG_VER}"
        ./configure --host="${HOST}" --prefix="${PREFIX}" \
            --enable-static --disable-shared \
            CPPFLAGS="-I${PREFIX}/include" LDFLAGS="-L${PREFIX}/lib"
        make -j"${JOBS}"
        make install
    )
fi

# ── vd_agent ───────────────────────────────────────────────────────
fetch "$VDAGENT_URL" "${SRC}/vdagent-win-${VDAGENT_VER}.tar.xz" "$VDAGENT_SHA"
rm -rf "${SRC}/vdagent-win-${VDAGENT_VER}"
tar -xf "${SRC}/vdagent-win-${VDAGENT_VER}.tar.xz" -C "${SRC}"
(
    cd "${SRC}/vdagent-win-${VDAGENT_VER}"
    for patch in "${DIR}"/patches/*.patch; do
        echo "==> 施加 $(basename "$patch")"
        patch -p1 --no-backup-if-mismatch < "$patch"
    done
    ./configure --host="${HOST}" --prefix="${PREFIX}" \
        CPPFLAGS="-I${PREFIX}/include" LDFLAGS="-L${PREFIX}/lib"
    make -j"${JOBS}"
)

# ── 产物 ───────────────────────────────────────────────────────────
OUT="${PREFIX}/bin"
mkdir -p "${OUT}"
cp "${SRC}/vdagent-win-${VDAGENT_VER}/vdagent.exe" "${OUT}/"
cp "${SRC}/vdagent-win-${VDAGENT_VER}/vdservice.exe" "${OUT}/"
"${HOST}-strip" "${OUT}/vdagent.exe" "${OUT}/vdservice.exe"

# 架构必须是 arm64,不能想当然。工具链目录名里带 universal,搞错 target 一样能编
# 出 x86_64 的 exe,而客体里要到运行时才报错。
for exe in "${OUT}/vdagent.exe" "${OUT}/vdservice.exe"; do
    arch="$(llvm-objdump -f "$exe" | awk '/architecture:/{print $2}')"
    [ "$arch" = "aarch64" ] || die "$(basename "$exe") 架构是 ${arch},不是 aarch64"
done

echo
echo "==> 完成:"
# 只列我们要的两个。libpng 的 pngfix 之类也装在同一个 prefix 的 bin 下,
# 用通配符会把它们一起列出来,看着像产物。
ls -lh "${OUT}/vdagent.exe" "${OUT}/vdservice.exe"
echo
echo "两个 exe 只依赖 UCRT 的 api-ms-win-crt-* 系列,Windows 10 以上自带,"
echo "不需要随包附带 VC++ 运行库。"
