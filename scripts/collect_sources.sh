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
#   义务  QEMU(GPLv2)、glib 系(LGPL-2.1+:glib/gobject/gio/gmodule)、
#         json-glib(LGPL-2.1+)、gettext 的 libintl(LGPL-2.1+)
#   好意  pixman(MIT)、libslirp / PCRE2 / libtpms / swtpm(BSD)、OpenSSL(Apache-2.0)、
#         edk2(BSD-2-Clause-Patent)、virtio-win 驱动(BSD-3)
#         —— 这些许可不要求我们提供源码,声明里给出上游地址即可,不收进包里。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${ROOT}/dist/oss-sources"

QEMU_VERSION="${QEMU_VERSION:-11.1.0}"
QEMU_SHA256="6ee1d1a61f68212476b27108c26da5f449dc09b626d42f8279ba0dc2e08fa858"

# LGPL 组件。版本必须与随包 dylib 实际构建自的版本一致 —— 我们用的是 Homebrew 的
# 二进制,所以这里的版本、URL、sha256 全部取自对应 formula 的 stable 段
# (`brew info --json=v2 <formula>`)。**升级 Homebrew 依赖后必须回来更新这三行**,
# 否则交付的源码对不上实际分发的二进制,义务没有履行。
LGPL_SPECS="
glib|2.88.3|https://download.gnome.org/sources/glib/2.88/glib-2.88.3.tar.xz|ab24d24e698dfa1e408b7bcdb508f4aafc906185a8b8ce72fdf79bbbdc9b383b
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
    curl -fsSL --retry 3 -o "$dest" "$url"
    local have; have="$(shasum -a 256 "$dest" | awk '{print $1}')"
    [ "$have" = "$want" ] || die "$(basename "$dest") sha256 不匹配
  期望 $want
  实际 $have"
}

rm -rf "$OUT"
mkdir -p "${OUT}/qemu" "${OUT}/scripts" "${OUT}/lgpl"

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

# 补丁目录。**当前为空 —— 这是有意的,不是漏了**:我们没有对 QEMU 源码做任何改动,
# 全部差异都在 configure 开关上。将来一旦加补丁,build_qemu.sh 会自动施加,
# 这里也会自动带上。
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

# ── 构建方式(GPLv2 §3 明文要求)────────────────────────────────
echo "==> 构建脚本"
for s in build_qemu.sh build_firmware.sh stage_helpers.sh sign_helpers.sh; do
    cp "${DIR}/${s}" "${OUT}/scripts/"
    echo "    ${s}"
done

# ── LGPL 组件 ──────────────────────────────────────────────────────
# 随包的是 Homebrew 构建的 dylib,所以"对应源码"= 上游 tarball + Homebrew formula
# (里面写着构建参数,glib 还带一个把硬编码路径改成 Homebrew 路径的补丁)。
# 只给上游 tarball 是不够的 —— formula 才是我们这份二进制的实际构建方式。
echo "==> LGPL 组件"
echo "$LGPL_SPECS" | while IFS='|' read -r name version url sha; do
    [ -n "$name" ] || continue
    echo "  ${name} ${version}"
    fetch "$url" "${OUT}/lgpl/$(basename "$url")" "$sha"
    FORMULA="/opt/homebrew/opt/${name}/.brew/${name}.rb"
    if [ -f "$FORMULA" ]; then
        cp "$FORMULA" "${OUT}/lgpl/${name}.rb"
        echo "    formula ${name}.rb"
    else
        echo "    ⚠ 找不到 ${FORMULA},交付包缺少该组件的实际构建方式" >&2
    fi
done

# glib 的 formula 引用了 homebrew-core 里的一个补丁文件,本地 API 安装模式下
# 不存在,从上游仓库取。少了它,交付的就不是我们这份 dylib 的完整对应源码。
GLIB_PATCH_URL="https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Patches/glib/hardcoded-paths.diff"
echo "  glib Homebrew 补丁"
if curl -fsL --retry 3 -o "${OUT}/lgpl/glib-homebrew-hardcoded-paths.diff" "$GLIB_PATCH_URL"; then
    echo "    hardcoded-paths.diff"
else
    echo "    ⚠ 取不到 ${GLIB_PATCH_URL},请手工补上" >&2
fi

cp "${ROOT}/docs/oss-sources-README.md" "${OUT}/README.md"

# ── 清单 ───────────────────────────────────────────────────────────
cd "$OUT"
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS
echo
echo "==> 完成:${OUT}"
du -sh "$OUT" | sed 's/^/  /'
wc -l < SHA256SUMS | sed 's/^/  文件数 /'
