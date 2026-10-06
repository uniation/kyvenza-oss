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
#   好意  pixman(MIT)、libslirp / PCRE2 / libtpms / swtpm(BSD)、OpenSSL(Apache-2.0)、
#         edk2(BSD-2-Clause-Patent)、virtio-win 驱动(BSD-3)
#         —— 这些许可不要求我们提供源码,声明里给出上游地址即可,不收进包里。
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

# LGPL 组件。版本必须与随包 dylib 实际构建自的版本一致 —— 我们用的是 Homebrew 的
# 二进制,所以这里的版本、URL、sha256 全部取自对应 formula 的 stable 段
# (`brew info --json=v2 <formula>`)。**升级 Homebrew 依赖后必须回来更新这三行**,
# 否则交付的源码对不上实际分发的二进制,义务没有履行。
#
# 以前「必须回来更新」只靠人记得:2026-09-20 Homebrew 把 glib 升到 2.90.0,
# 9-23 打的 MAS 3.0.2 就带着 2.90.0 出去了,而这里还写着 2.88.3。现在下面会逐个
# 比对 Homebrew 实际装的版本,不一致直接失败。
LGPL_SPECS="
glib|2.90.0|https://download.gnome.org/sources/glib/2.90/glib-2.90.0.tar.xz|17d15cac2af80a33271127408e0abc2748eb297c595c2a26409e81e14e7d1b8f
json-glib|1.10.8|https://download.gnome.org/sources/json-glib/1.10/json-glib-1.10.8.tar.xz|55c5c141a564245b8f8fbe7698663c87a45a7333c2a2c56f06f811ab73b212dd
gettext|1.0|https://ftpmirror.gnu.org/gnu/gettext/gettext-1.0.tar.gz|85d99b79c981a404874c02e0342176cf75c7698e2b51fe41031cf6526d974f1a
"

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
mkdir -p "${OUT}/qemu" "${OUT}/scripts" "${OUT}/lgpl" "${OUT}/vdagent"

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
for s in build_qemu.sh build_firmware.sh stage_helpers.sh sign_helpers.sh; do
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

# ── LGPL 组件 ──────────────────────────────────────────────────────
# 随包的是 Homebrew 构建的 dylib,所以"对应源码"= 上游 tarball + Homebrew formula
# (里面写着构建参数,glib 还带一个把硬编码路径改成 Homebrew 路径的补丁)。
# 只给上游 tarball 是不够的 —— formula 才是我们这份二进制的实际构建方式。
echo "==> LGPL 组件"
echo "$LGPL_SPECS" | while IFS='|' read -r name version url sha; do
    [ -n "$name" ] || continue
    echo "  ${name} ${version}"
    # 随包的 dylib 就是 Homebrew 此刻装着的那份(stage_helpers.sh 从这里拷)。
    # keg 目录名形如 2.90.0 或 2.90.0_1,下划线后是 formula 修订号,上游源码相同。
    KEG="$(realpath "/opt/homebrew/opt/${name}" 2>/dev/null)" || die "Homebrew 里没装 ${name}"
    INSTALLED="$(basename "$KEG")"
    INSTALLED="${INSTALLED%%_*}"
    [ "$INSTALLED" = "$version" ] || die "${name}: Homebrew 装的是 ${INSTALLED},这里写的是 ${version}。
  随包 dylib 来自 Homebrew,交付的源码必须与之对应。按下面的输出更新 LGPL_SPECS 那一行:
  brew info --json=v2 ${name} | python3 -c \"import json,sys;u=json.load(sys.stdin)['formulae'][0]['urls']['stable'];print(u['url'],u['checksum'])\""
    fetch "$url" "${OUT}/lgpl/$(basename "$url")" "$sha"
    FORMULA="${KEG}/.brew/${name}.rb"
    [ -f "$FORMULA" ] || die "找不到 ${FORMULA}:formula 是这份二进制的实际构建方式,缺了就不是完整对应源码"
    cp "$FORMULA" "${OUT}/lgpl/${name}.rb"
    echo "    formula ${name}.rb"
done

# glib 的 formula 引用了 homebrew-core 里的一个补丁文件,本地 API 安装模式下
# 不存在,从上游仓库取。少了它,交付的就不是我们这份 dylib 的完整对应源码。
#
# 取的是 HEAD,所以**哈希钉死**:API 安装模式不记录 tap 的 commit,没法按构建时的
# 版本去取;上游一旦改了这个补丁,这里就失败,由人确认随包那份 glib 用的是哪一版
# 再更新哈希。2025-10-15 之后它没变过,3.0.1 交付的也是这一份。
GLIB_PATCH_URL="https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Patches/glib/hardcoded-paths.diff"
GLIB_PATCH_SHA256="d846efd0bf62918350da94f850db33b0f8727fece9bfaf8164566e3094e80c97"
echo "  glib Homebrew 补丁"
fetch "$GLIB_PATCH_URL" "${OUT}/lgpl/glib-homebrew-hardcoded-paths.diff" "$GLIB_PATCH_SHA256"

cp "${ROOT}/docs/oss-sources-README.md" "${OUT}/README.md"

# ── 清单 ───────────────────────────────────────────────────────────
cd "$OUT"
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS
echo
echo "==> 完成:${OUT}"
du -sh "$OUT" | sed 's/^/  /'
wc -l < SHA256SUMS | sed 's/^/  文件数 /'
