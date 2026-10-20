#!/usr/bin/env bash
# 组装「开源源码交付包」—— 随包分发的 GPL/LGPL 组件对应的完整源码与构建方式。
#
# **为什么必须有这个东西**:GPLv2 §3 与 LGPL-2.1 §4 要求,分发这些库的二进制形式时,
# 必须一并提供(或提供获取途径)与之对应的完整源码,GPLv2 §3 明文包括
# "scripts used to control compilation and installation"。app 内的开源声明只写
# 「来信索取」是 §3(b) 的书面要约,能成立但不够稳妥 —— 这个脚本产出的是稳定下载点
# 上真正要放的东西。
#
# 产出:dist/oss-sources/<组件>/... 加一份 SHA256SUMS。
# 上传用 `make publish-oss-source`。
#
# **哪些是义务、哪些是好意,分清楚**:
#   义务  QEMU(GPLv2)、SPICE vd_agent(GPLv2+,随驱动光盘进客体)、
#         glib 系(LGPL-2.1+:glib/gobject/gio/gmodule)、
#         json-glib(LGPL-2.1+)、gettext 的 libintl(LGPL-2.1+)
#   好意  pixman(MIT)、libslirp / PCRE2 / libtpms / swtpm(BSD)、OpenSSL(Apache-2.0)
#         —— 许可不要求交付源码。但随包的这些全是 build_deps26.sh 从固定 tarball 编的,
#         交付包里已经有那个脚本,不给它的输入就复现不出我们发的字节,所以一并放进 permissive/。
#   不收  edk2(BSD-2-Clause-Patent,构建脚本已附)、virtio-win 驱动(BSD-3,上游二进制)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${ROOT}/dist/oss-sources"

# 版本与 sha256 **只在构建脚本里写一份**,这里读出来用。以前两边各抄一份、互不校验:
# 只改了构建脚本的默认版本时 `--check` 照样通过,交付包却还是旧版本的源码。
# 构建脚本是「构建方式」,这里是「对应源码」,两者必须是同一个数。
read_default() {  # read_default <文件> <变量名>:取 VAR="${VAR:-x}" 或 VAR=x 里的 x
    local value
    value="$(sed -nE "s/^$2=\"?\\$\{$2:-([^}]+)\}\"?$/\1/p; s/^$2=\"?([^\"$]+)\"?$/\1/p" "$1" | head -n1)"
    [ -n "$value" ] || die "从 $1 读不出 $2"
    echo "$value"
}
QEMU_VERSION="${QEMU_VERSION:-$(read_default "${DIR}/build_qemu.sh" QEMU_VERSION)}"
QEMU_SHA256="$(read_default "${DIR}/build_qemu.sh" QEMU_SHA256)"

# SPICE vd_agent(GPLv2+)。跑在**客体里**,随驱动光盘分发。同样取自构建脚本。
VDAGENT_VERSION="$(read_default "${ROOT}/scripts/guest-tools/build_vdagent.sh" VDAGENT_VER)"
VDAGENT_SHA256="$(read_default "${ROOT}/scripts/guest-tools/build_vdagent.sh" VDAGENT_SHA)"

# 随包的 dylib 与 swtpm 全部是 build_deps26.sh 按 macOS 26.0 部署目标从固定 tarball 编的
# (Homebrew 只给最新系统出 bottle,在 macOS 27 上新装/升级后都会变成要求 27.0)。
# 版本、URL、sha256 与许可只在那个脚本里写一份,这里用 `--print-sources` 读出来。
#
# 以前 json-glib / gettext 用的是 Homebrew 的二进制,这里另抄一份版本,靠逐个比对 Homebrew
# 实际装的版本来防漂移:2026-09-20 Homebrew 把 glib 升到 2.90.0,9-23 打的 MAS 3.0.2 就带着
# 2.90.0 出去了,而这里还写着 2.88.3。现在随包的不再取自 Homebrew,对应关系改由下面核对
# 重编产物的戳来保证。
DEPS26_SCRIPT="${DIR}/build_deps26.sh"
DEPS26_SOURCES="$(bash "$DEPS26_SCRIPT" --print-sources)"
DEPS26_STAMP="${ROOT}/.local/qemu/deps26/build.stamp"

die() { echo "collect_sources: $*" >&2; exit 1; }

# 下载并校验。已存在且哈希正确就跳过(这个脚本会被反复跑)。
fetch() {
    local url="$1" dest="$2" want="$3"
    if [ -f "$dest" ]; then
        local have; have="$(shasum -a 256 "$dest" | awk '{print $1}')"
        [ "$have" = "$want" ] && { echo "    已有 $(basename "$dest")"; return; }
        echo "    $(basename "$dest") 哈希不符,重新下载"
        rm -f "$dest"
    fi
    echo "    下载 $(basename "$dest")"
    # **ftpmirror.gnu.org 排到后面。** 它是随机轮询,轮到挂掉的镜像就完蛋:
    # 2026-09-06 发布时先返回 502/504,后来变成"连上了但一个字节都不传"。
    # 而这一步是 GPLv2 §3 的义务,取不到源码就不能发版,所以先走 ftp.gnu.org
    # 这个固定站点,ftpmirror 留作回退。
    #
    # 换源是安全的:sha256 在下面钉死,取到的字节不一致一样会被拒。
    #
    # 2026-10-07 重传 3.1.0 源码时 ftp.gnu.org 与 ftpmirror 都在 TLS 握手阶段失败,
    # kernel.org 的 GNU 镜像正常,所以把它排在最后兜底。
    local urls="$url"
    case "$url" in
        https://ftpmirror.gnu.org/*)
            urls="${url/ftpmirror.gnu.org/ftp.gnu.org} $url ${url/ftpmirror.gnu.org/mirrors.kernel.org}"
            ;;
    esac
    local ok=0 u
    for u in $urls; do
        # 两道闸都必要:--retry-max-time 挡住"持续 502 时带退避重试很久",
        # --speed-limit/--speed-time 挡住"连上了却一个字节都不传"。只有前者时
        # 后一种情况仍会无限期挂住 —— 实测踩过。
        if curl -fsSL --retry 2 --retry-max-time 30 --connect-timeout 15 \
                --speed-limit 2048 --speed-time 20 -o "$dest" "$u"; then
            ok=1
            break
        fi
        echo "    取不到 $u,换下一个源" >&2
    done
    [ "$ok" = 1 ] || die "$(basename "$dest") 所有源都取不到"
    local have; have="$(shasum -a 256 "$dest" | awk '{print $1}')"
    [ "$have" = "$want" ] || die "$(basename "$dest") sha256 不匹配
  期望 $want
  实际 $have"
}

rm -rf "$OUT"
mkdir -p "${OUT}/qemu" "${OUT}/scripts" "${OUT}/lgpl" "${OUT}/permissive" "${OUT}/vdagent"

# ── QEMU:我们分发的那份二进制的完整对应源码 ──────────────────────
echo "==> QEMU ${QEMU_VERSION}"
TARBALL="${ROOT}/.local/qemu/qemu-${QEMU_VERSION}.tar.xz"
if [ -f "$TARBALL" ]; then
    # 本地构建用的就是这一份,直接复用并复核哈希,保证交付的与构建的同源
    have="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
    [ "$have" = "$QEMU_SHA256" ] || die "本地 QEMU tarball 哈希不符,拒绝打包"
    cp "$TARBALL" "${OUT}/qemu/"
    echo "    复用本地 tarball"
else
    fetch "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz" \
        "${OUT}/qemu/qemu-${QEMU_VERSION}.tar.xz" "$QEMU_SHA256"
fi

# 补丁目录。交付包里放在 `qemu/patches/`,build_qemu.sh 在 `scripts/` 下会自动
# 找到 `../qemu/patches`(仓库里则是脚本旁的 `patches/`)。没有补丁时写一份 README 说明。
mkdir -p "${OUT}/qemu/patches"
shopt -s nullglob
PATCHES=("${DIR}"/patches/*.patch)
shopt -u nullglob
if [ ${#PATCHES[@]} -gt 0 ]; then
    cp "${PATCHES[@]}" "${OUT}/qemu/patches/"
    echo "    补丁 ${#PATCHES[@]} 个"
else
    cat > "${OUT}/qemu/patches/README.txt" <<'EOF'
No patches are applied to QEMU.

Kyvenza builds the upstream qemu-11.1.0 release unmodified; every difference
from a stock build comes from the configure flags in build_qemu.sh. If a patch
is ever added, it will appear in this directory and build_qemu.sh will apply it
automatically.
EOF
fi

# ── SPICE vd_agent:客体里那个剪贴板代理 ──────────────────────────
# 上游只发 x86/x64,ARM64 这一份是我们自己交叉编译的,所以除了源码之外
# **必须**给出我们施加的补丁与构建脚本,否则拿到源码也复现不出这两个 exe。
echo "==> SPICE vd_agent ${VDAGENT_VERSION}"
VDAGENT_TARBALL="${ROOT}/.local/vdagent/src/vdagent-win-${VDAGENT_VERSION}.tar.xz"
if [ -f "$VDAGENT_TARBALL" ]; then
    have="$(shasum -a 256 "$VDAGENT_TARBALL" | awk '{print $1}')"
    [ "$have" = "$VDAGENT_SHA256" ] || die "本地 vd_agent tarball 哈希不符,拒绝打包"
    cp "$VDAGENT_TARBALL" "${OUT}/vdagent/"
    echo "    复用本地 tarball"
else
    fetch "https://www.spice-space.org/download/windows/vdagent/vdagent-win-${VDAGENT_VERSION}/vdagent-win-${VDAGENT_VERSION}.tar.xz" \
        "${OUT}/vdagent/vdagent-win-${VDAGENT_VERSION}.tar.xz" "$VDAGENT_SHA256"
fi

VDAGENT_DIR="${ROOT}/scripts/guest-tools"
mkdir -p "${OUT}/vdagent/patches"
shopt -s nullglob
VDAGENT_PATCHES=("${VDAGENT_DIR}"/patches/*.patch)
shopt -u nullglob
[ ${#VDAGENT_PATCHES[@]} -gt 0 ] || die "scripts/guest-tools/patches 是空的 —— 那些补丁是编出 ARM64 版本的必要条件"
cp "${VDAGENT_PATCHES[@]}" "${OUT}/vdagent/patches/"
echo "    补丁 ${#VDAGENT_PATCHES[@]} 个"

# ── 构建方式(GPLv2 §3 明文要求)────────────────────────────────
echo "==> 构建脚本"
for s in build_qemu.sh build_deps26.sh build_firmware.sh stage_helpers.sh sign_helpers.sh; do
    cp "${DIR}/${s}" "${OUT}/scripts/"
    echo "    ${s}"
done
cp "${VDAGENT_DIR}/build_vdagent.sh" "${OUT}/scripts/"
echo "    build_vdagent.sh"

# 脚本引用的素材也要一起给。`build_firmware.sh` 会把 assets/boot-logo.bmp 盖到
# edk2 的 Logo.bmp 上,少了它照着脚本编出来的固件和我们发的那份不一致 ——
# edk2 是 BSD 没有开源义务,但"发出去的字节和公开的配方一致"这条是我们自己立的。
if [ -d "${DIR}/assets" ]; then
    mkdir -p "${OUT}/scripts/assets"
    cp "${DIR}/assets/"* "${OUT}/scripts/assets/"
    echo "    assets/ ($(ls -1 "${DIR}/assets" | wc -l | tr -d ' ') 个文件)"
fi

# ── build_deps26.sh 编的库(LGPL 与宽松许可)──────────────────────
# 随包的 dylib 与 swtpm 不是 Homebrew 的二进制,而是 build_deps26.sh 用下面这些上游 tarball
# 编的,所以"对应源码"= 这些 tarball + build_deps26.sh(已随脚本一起交付)。
# 核对重编产物的戳,防止交付的源码与实际打进包里的不是同一个版本。
echo "==> build_deps26.sh 的依赖库"
[ -f "$DEPS26_STAMP" ] || die "没有 ${DEPS26_STAMP}:先跑 make deps26 并重新组包,随包的库才是这份源码对应的那些"
echo "$DEPS26_SOURCES" | while IFS='|' read -r name version url sha license file; do
    [ -n "$name" ] || continue
    grep -q " ${name}=${version} " "$DEPS26_STAMP" || die "deps26 产物的戳里 ${name} 不是 ${version}:${DEPS26_STAMP}
  先 FORCE=1 make deps26 并重新组包"
    case "$license" in
        LGPL-*|GPL-*) sub=lgpl ;;
        *) sub=permissive ;;
    esac
    echo "  ${name} ${version}(${license})"
    LOCAL_TARBALL="${ROOT}/.local/qemu/deps26-src/${file}"
    if [ -f "$LOCAL_TARBALL" ] && [ "$(shasum -a 256 "$LOCAL_TARBALL" | awk '{print $1}')" = "$sha" ]; then
        # 本地构建用的就是这一份,直接复用(哈希已复核)
        cp "$LOCAL_TARBALL" "${OUT}/${sub}/${file}"
        echo "    复用本地 tarball"
    else
        fetch "$url" "${OUT}/${sub}/${file}" "$sha"
    fi
done

cp "${ROOT}/docs/oss-sources-README.md" "${OUT}/README.md"

# ── 清单 ───────────────────────────────────────────────────────────
cd "$OUT"
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS
echo
echo "==> 完成:${OUT}"
du -sh "$OUT" | sed 's/^/  /'
wc -l < SHA256SUMS | sed 's/^/  文件数 /'
