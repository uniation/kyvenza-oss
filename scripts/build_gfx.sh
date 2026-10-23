#!/usr/bin/env bash
# 构建 Windows 客体图形加速要随包的那一组库:ANGLE、libepoxy、virglrenderer(含 render
# server)、DXMT(静态链接 LLVM 15)。build_qemu.sh 链接其中的 libepoxy 与 virglrenderer,
# 所以这个脚本必须先跑(`make qemu` 会先跑它)。
#
# 整条链路(spike 报告 docs/2026-10-19-windows-3d-spike-report.md):
#   客体 D3D11 → Triton 驱动 → virtio-gpu → QEMU → virgl_render_server(独立进程)
#   → virglrenderer 的 Neptune 后端 → dlopen 的 DXMT → Metal
#   QEMU 自己的显示上下文走 libepoxy → dlopen 的 ANGLE(Metal 后端)。
#
# 版本钉在 UTM 5.0.8 的 patches/sources 上(那是 spike 实测过的组合)。四个仓库都是
# git 提交哈希,LLVM 是发布 tarball + sha256。换任何一个都要重跑 spike 报告 5.2 的场景。
#
# 许可(stage_helpers.sh 的白名单与 collect_sources.sh 要与这里一致):
#   ANGLE          BSD-3-Clause        libEGL.dylib、libGLESv2.dylib
#   libepoxy       MIT                 libepoxy.0.dylib
#   virglrenderer  MIT                 libvirglrenderer.1.dylib、virgl_render_server
#   DXMT           LGPL-2.1            libdxmt-native.dylib → 必须交付源码与我们的补丁
#   LLVM 15        Apache-2.0 WITH LLVM-exception,静态链接进 DXMT
#   directx-native Apache-2.0          DXMT 与 virglrenderer 之间的接口,两边各自静态编入
#
# 我们的补丁在 gfx-patches/<组件>/,与 QEMU 的补丁一样随源码交付:
#   angle          libEGL 在自己旁边找 libGLESv2.dylib(原来只认 framework 相对路径,
#                  hardened runtime 直接拒绝相对路径)
#   libepoxy       按 @loader_path 加载 ANGLE(hardened runtime 会剥掉 DYLD_FRAMEWORK_PATH)
#   virglrenderer  按 @rpath 加载 DXMT(同理,DYLD_LIBRARY_PATH 也会被剥掉);
#                  stage_helpers.sh 给 render server 加 LC_RPATH 指向 Frameworks
#   dxmt           设备拆除时先等命令队列排空(Office 退出时 render server 的释放后使用)
#
# render server 的路径不在这里决定:virglrenderer 编进去的是构建目录里的绝对路径,
# 随包后由启动 QEMU 时的 RENDER_SERVER_EXEC_PATH 环境变量指到 Contents/Helpers。
#
# 用法: bash scripts/qemu/build_gfx.sh           (输入没变就跳过)
#       FORCE=1 bash scripts/qemu/build_gfx.sh   (强制重编)
#       bash scripts/qemu/build_gfx.sh --check   (只比对指纹,组包时用)
# 产物: .local/qemu/gfx/{lib,libexec,include}
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

DEPLOYMENT_TARGET="26.0"
# 与 build_qemu.sh 同一个 SDK:换 SDK 就不是同一份产物。
SDK_VERSION="${QEMU_SDK_VERSION:-26.5}"
# ANGLE 例外:xcodebuild 只认 Xcode 自带的 SDK,不认 Command Line Tools 里那份 26.5,
# 所以它用 Xcode 的默认 SDK,靠部署目标 26.0 保证 macOS 26 能加载(spike 即如此)。
# 实际版本记进指纹,换了 Xcode 就会重编。
ANGLE_SDK_VERSION="$(xcodebuild -version -sdk macosx SDKVersion 2>/dev/null || echo unknown)"

ANGLE_REPO="https://github.com/utmapp/WebKit.git"
ANGLE_COMMIT="ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10"
ANGLE_SUBDIRS="Source/ThirdParty/ANGLE Configurations Tools/ccache"
EPOXY_REPO="https://github.com/utmapp/libepoxy.git"
EPOXY_COMMIT="bf98587477fe68d07b93319ece7b40a7d0e2eabe"
VIRGL_REPO="https://github.com/utmapp/virglrenderer.git"
VIRGL_COMMIT="451505ad0aa449290f2c0672da6877d57ee770e5"
DXMT_REPO="https://github.com/utmapp/dxmt.git"
DXMT_COMMIT="66e27f3759ff79e41a791ec40e2a70ef6d0c964c"
LLVM_VERSION="15.0.7"
LLVM_URL="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/llvm-project-${LLVM_VERSION}.src.tar.xz"
LLVM_SHA256="8b5fcb24b4128cf04df1b0b9410ce8b1a729cb3c544e6da885d234280dedeac6"

WORK="${ROOT}/.local/qemu/gfx-build"
SRC="${ROOT}/.local/qemu/gfx-src"
PREFIX="${ROOT}/.local/qemu/gfx"
# LLVM 只是 DXMT 的构建依赖,不随包。单独放,免得它的几百个头文件和静态库混进 PREFIX。
LLVM_PREFIX="${ROOT}/.local/qemu/gfx-llvm"
STAMP="${PREFIX}/build.stamp"
PATCHES="${DIR}/gfx-patches"
JOBS="$(sysctl -n hw.ncpu)"

die() { echo "build_gfx: $*" >&2; exit 1; }

# 指纹:版本、目标、SDK、本脚本与每个补丁的哈希。任何一项变了都整套重编。
want_stamp() {
    echo "target=${DEPLOYMENT_TARGET} sdk=${SDK_VERSION} angle_sdk=${ANGLE_SDK_VERSION}"
    echo "angle=${ANGLE_COMMIT} epoxy=${EPOXY_COMMIT} virgl=${VIRGL_COMMIT} dxmt=${DXMT_COMMIT} llvm=${LLVM_SHA256}"
    echo "script=$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')"
    find "$PATCHES" -name '*.patch' | sort | while read -r p; do
        echo "patch=${p#"${PATCHES}/"} $(shasum -a 256 "$p" | awk '{print $1}')"
    done
}
WANT_STAMP="$(want_stamp)"

if [ "${1:-}" = "--check" ]; then
    [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT_STAMP" ] && exit 0
    echo "图形加速依赖不是由当前的 build_gfx.sh 与 gfx-patches/ 建出来的,先跑 make gfx。" >&2
    exit 1
fi
if [ "${FORCE:-0}" != "1" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT_STAMP" ]; then
    echo "build_gfx: 已是最新,跳过"
    exit 0
fi

command -v meson >/dev/null || die "缺 meson(brew install meson)"
command -v ninja >/dev/null || die "缺 ninja(brew install ninja)"
command -v cmake >/dev/null || die "缺 cmake(brew install cmake)"
command -v pkg-config >/dev/null || die "缺 pkg-config(brew install pkgconf)"
command -v xcodebuild >/dev/null || die "缺 Xcode:ANGLE 用 xcodebuild 构建"
# ANGLE 构建时要把内置的 Metal 着色器预编译成 metallib。Xcode 26 起 Metal 编译器是
# 单独下载的组件,没装时 xcodebuild 会在构建中途才失败。运行时不需要它。
xcrun -f metal >/dev/null 2>&1 || die "缺 Metal Toolchain:xcodebuild -downloadComponent MetalToolchain"

SDKROOT=""
for candidate in \
    "/Library/Developer/CommandLineTools/SDKs/MacOSX${SDK_VERSION}.sdk" \
    "$(xcrun --show-sdk-platform-path 2>/dev/null)/Developer/SDKs/MacOSX${SDK_VERSION}.sdk"; do
    if [ -d "$candidate" ]; then SDKROOT="$candidate"; break; fi
done
[ -n "$SDKROOT" ] || die "找不到 macOS ${SDK_VERSION} SDK"
export SDKROOT
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
# 不让 Homebrew 的 pkg-config 目录混进来:这几个组件只该看到彼此。
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
# install_name_tool 在组包时要把绝对路径改成 @loader_path,留够头部空间。
export LDFLAGS="-Wl,-headerpad_max_install_names"
# libepoxy 的 EGL 头文件 include 的是 ANGLE 装进 PREFIX 的 <EGL/eglplatform.h>。
export CPPFLAGS="-I${PREFIX}/include"

# 浅取一个提交:四个仓库都按哈希钉死,哈希本身就是内容校验。
# 已有同一提交的检出就复用(补丁打在副本上,见 prepare)。
fetch_git() {
    local name="$1" repo="$2" commit="$3" subdirs="${4:-}" dir="${SRC}/$1"
    if [ -d "${dir}/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then
        return
    fi
    echo "  取 ${name} @ ${commit:0:12}"
    rm -rf "$dir"; mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$repo"
    if [ -n "$subdirs" ]; then
        git -C "$dir" sparse-checkout set $subdirs
        git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$commit"
    else
        git -C "$dir" fetch -q --depth 1 origin "$commit"
    fi
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    git -C "$dir" submodule update -q --init --recursive --depth 1
    [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || die "${name} 取到的不是 ${commit}"
}

fetch_tarball() {
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

# 把检出拷进构建目录再打补丁,src 里始终是干净的上游提交。
prepare() {
    local name="$1" dest="${WORK}/$1" p
    rsync -a --delete --exclude .git "${SRC}/${name}/" "$dest/"
    if [ -d "${PATCHES}/${name}" ]; then
        for p in "${PATCHES}/${name}"/*.patch; do
            echo "  打补丁 ${name}/$(basename "$p")"
            patch -p1 -s -d "$dest" < "$p" || die "补丁打不上: $p"
        done
    fi
}

meson_build() {
    local name="$1"; shift
    local b="${WORK}/${name}-build"
    meson setup "$b" "${WORK}/${name}" --prefix="$PREFIX" --libdir=lib \
        --buildtype=release --wrap-mode=nofallback "$@" > "${WORK}/${name}-setup.log" 2>&1 \
        || { tail -30 "${WORK}/${name}-setup.log" >&2; die "${name} 的 meson setup 失败"; }
    meson compile -C "$b" -j "$JOBS" > "${WORK}/${name}-build.log" 2>&1 \
        || { grep -E "error|FAILED" "${WORK}/${name}-build.log" | head -20 >&2; die "${name} 编译失败"; }
    meson install -C "$b" >/dev/null
}

rm -rf "$PREFIX" "$WORK"
mkdir -p "$PREFIX" "$WORK" "$SRC"

echo "==> 取源码"
fetch_git angle "$ANGLE_REPO" "$ANGLE_COMMIT" "$ANGLE_SUBDIRS"
fetch_git libepoxy "$EPOXY_REPO" "$EPOXY_COMMIT"
fetch_git virglrenderer "$VIRGL_REPO" "$VIRGL_COMMIT"
fetch_git dxmt "$DXMT_REPO" "$DXMT_COMMIT"
fetch_tarball "$LLVM_URL" "${SRC}/llvm-project-${LLVM_VERSION}.src.tar.xz" "$LLVM_SHA256"

echo "==> ANGLE"
prepare angle
(
    cd "${WORK}/angle/Source/ThirdParty/ANGLE"
    # 与 UTM 的构建同一套参数。Xcode 27 的 libc++ 删掉了 _LIBCPP_ENABLE_ASSERTIONS,
    # WebKit 的配置还在用它,换成等价的 hardening 模式。env -i:别让上面为 meson 设的
    # PKG_CONFIG/LDFLAGS 漏进 xcodebuild。
    env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" DEVELOPER_DIR="$(xcode-select -p)" \
    xcodebuild archive -archivePath "${WORK}/ANGLE" \
        -scheme ANGLE -sdk macosx -arch arm64 -configuration Release \
        WEBCORE_LIBRARY_DIR=/usr/local/lib NORMAL_UMBRELLA_FRAMEWORKS_DIR="" \
        CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO \
        MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        WK_LIBCPP_ASSERTIONS_CFLAGS_MACOS_SINCE_1400="-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE" \
        > "${WORK}/angle.log" 2>&1 || { tail -40 "${WORK}/angle.log" >&2; die "ANGLE 构建失败"; }
    mkdir -p "${PREFIX}/lib" "${PREFIX}/include"
    cp "${WORK}/ANGLE.xcarchive/Products/usr/local/lib/libEGL.dylib" \
       "${WORK}/ANGLE.xcarchive/Products/usr/local/lib/libGLESv2.dylib" "${PREFIX}/lib/"
    rsync -a include/ "${PREFIX}/include/"
)
# libEGL 按「自己所在目录」dlopen libGLESv2,两者必须放在一起(组包时同进 Frameworks)。
for lib in libEGL libGLESv2; do
    install_name_tool -id "@loader_path/${lib}.dylib" "${PREFIX}/lib/${lib}.dylib"
done

echo "==> libepoxy"
prepare libepoxy
meson_build libepoxy -Dtests=false -Dglx=no -Degl=yes -Dx11=false

echo "==> virglrenderer"
prepare virglrenderer
# Neptune(D3D)上下文,render server 以独立进程运行;不要 Venus,所以不需要 MoltenVK。
# Neptune 只用 directx-native 的头文件(与 DXMT 之间的接口定义)。它是 virglrenderer 自带的
# meson wrap,按提交钉在 subprojects/directx-native.wrap 里,所以唯独它允许回退去取。
meson_build virglrenderer -Dtests=false -Dcheck-gl-errors=false -Dvenus=false -Dneptune=true \
    -Drender-server-mode=process --force-fallback-for=directx-native-headers

echo "==> LLVM ${LLVM_VERSION}(静态库,只给 DXMT 的着色器转换用,不随包)"
# 它是整个脚本里最慢的一步(半小时上下),而且只取决于这几个输入,所以单独记戳、
# 输入没变就复用,不跟着别的组件一起重编。
LLVM_STAMP_WANT="llvm=${LLVM_SHA256} target=${DEPLOYMENT_TARGET} sdk=${SDK_VERSION}"
if [ -f "${LLVM_PREFIX}/build.stamp" ] && [ "$(cat "${LLVM_PREFIX}/build.stamp")" = "$LLVM_STAMP_WANT" ]; then
    echo "  复用已建好的 ${LLVM_PREFIX}"
else
tar -xf "${SRC}/llvm-project-${LLVM_VERSION}.src.tar.xz" -C "$WORK"
rm -rf "$LLVM_PREFIX"
cmake -G Ninja -S "${WORK}/llvm-project-${LLVM_VERSION}.src/llvm" -B "${WORK}/llvm-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$LLVM_PREFIX" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" -DCMAKE_OSX_SYSROOT="$SDKROOT" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DLLVM_ENABLE_ZSTD=Off -DLLVM_TARGETS_TO_BUILD="" -DLLVM_BUILD_TOOLS=Off \
    -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off -DLLVM_ENABLE_TERMINFO=Off \
    -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_EXAMPLES=Off -DLLVM_INCLUDE_BENCHMARKS=Off \
    > "${WORK}/llvm-setup.log" 2>&1 || { tail -30 "${WORK}/llvm-setup.log" >&2; die "LLVM 的 cmake 配置失败"; }
cmake --build "${WORK}/llvm-build" --parallel "$JOBS" >/dev/null
cmake --install "${WORK}/llvm-build" >/dev/null
echo "$LLVM_STAMP_WANT" > "${LLVM_PREFIX}/build.stamp"
fi

echo "==> DXMT"
prepare dxmt
# DXMT 的 meson 默认按 Windows 交叉编译,原生构建要一份 darwin 的 cross file。
cat > "${WORK}/darwin.cross" <<CROSS
[properties]
needs_exe_wrapper = true
[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
[binaries]
c = ['/usr/bin/clang', '-arch', 'arm64']
cpp = ['/usr/bin/clang++', '-arch', 'arm64']
objc = ['/usr/bin/clang', '-arch', 'arm64']
objcpp = ['/usr/bin/clang++', '-arch', 'arm64']
ar = ['/usr/bin/ar']
strip = ['/usr/bin/strip', '-x']
pkg-config = ['pkg-config']
CROSS
# directx-native(D3D 的 native 侧接口与共享内存实现)同样是钉在 subprojects/ 里按提交取的 wrap,
# 与 virglrenderer 用的是同一个提交。
meson_build dxmt --cross-file "${WORK}/darwin.cross" -Dnative_llvm_path="$LLVM_PREFIX" \
    --force-fallback-for=directx-native

echo "==> 校验产物"
BAD=0
for f in lib/libEGL.dylib lib/libGLESv2.dylib lib/libepoxy.0.dylib lib/libvirglrenderer.1.dylib \
         lib/libdxmt-native.dylib libexec/virgl_render_server; do
    [ -f "${PREFIX}/${f}" ] || { echo "  缺 ${f}" >&2; BAD=1; continue; }
    minos="$(otool -l "${PREFIX}/${f}" | awk '/LC_BUILD_VERSION/{x=1} x && $1=="minos"{print $2; exit}')"
    echo "  $(basename "$f"): minos ${minos}"
    [ "$(printf '%s\n%s\n' "$minos" "$DEPLOYMENT_TARGET" | sort -V | tail -1)" = "$DEPLOYMENT_TARGET" ] || BAD=1
done
# DXMT 必须是静态链接 LLVM:要是链到了 libLLVM.dylib,那是一个我们没打算随包的 60 MB 依赖。
if otool -L "${PREFIX}/lib/libdxmt-native.dylib" | grep -qi llvm; then
    die "libdxmt-native 动态链接了 LLVM"
fi
[ "$BAD" = "0" ] || die "产物缺失或最低系统版本高于 ${DEPLOYMENT_TARGET}"

echo "$WANT_STAMP" > "$STAMP"
rm -rf "$WORK"
echo "build_gfx: 完成 → ${PREFIX}"
