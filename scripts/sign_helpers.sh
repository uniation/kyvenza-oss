#!/usr/bin/env bash
# 给 .app 里随包的 QEMU 资源签名。
#
# 用法: scripts/qemu/sign_helpers.sh <app-bundle-path> [identity] [--standalone]
#   identity 缺省为 "-"(ad-hoc)。Apple Silicon 上没有有效签名的可执行文件会被
#   内核直接 SIGKILL(退出码 137),所以调试包也必须签。
#
# **--standalone 是给未签名的调试包用的**。默认给 helper 签
# `app-sandbox` + `inherit`,这是 MAS 对包内可执行文件的要求;但带这两个键的
# 二进制**必须由一个已沙盒化的父进程 spawn**,否则沙盒初始化失败、直接 SIGTRAP
# (退出码 133,实测)。`make manual-test-app` 产出的调试包不签 entitlements、
# 因而不在沙盒里,它的 helper 只能用 --standalone(去掉沙盒两键,
# qemu-system 保留 hypervisor)。
#
# 这个分野本身就是 CLAUDE.md 说的"沙盒行为只有签名包才准"的一个实例:
# 调试包验不了沙盒相关的行为,发布前必须用 make bundle && make sign 的产物复验。
#
# **必须由内向外签**:先库、再可执行文件、最后主 app。反过来签,
# 外层封上之后再改内层会让外层签名失效,公证与 MAS 都会拒。
# 这个脚本只管内层;外层由 Makefile 的 sign / sign-mas 目标负责。
set -euo pipefail

APP="${1:?用法: sign_helpers.sh <app-bundle-path> [identity] [--standalone]}"
IDENTITY="${2:--}"
STANDALONE=0
[ "${3:-}" = "--standalone" ] && STANDALONE=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER_ENTITLEMENTS="${ROOT}/Kyvenza/Kyvenza/Resources/QEMUHelper.entitlements"
HYPERVISOR_ENTITLEMENTS="${ROOT}/Kyvenza/Kyvenza/Resources/QEMUHypervisorHelper.entitlements"

HELPERS="${APP}/Contents/Helpers"
FRAMEWORKS="${APP}/Contents/Frameworks"

[ -d "$HELPERS" ] || { echo "sign_helpers: 没有 $HELPERS,先跑 stage_helpers.sh" >&2; exit 1; }

# hardened runtime(--options runtime)只对真实身份有意义,ad-hoc 加了会报错
RUNTIME_FLAG=""
[ "$IDENTITY" != "-" ] && RUNTIME_FLAG="--options runtime"

# --standalone:临时生成一份不带沙盒键的 entitlements。
# 它只服务于调试包,不该作为仓库里的文件存在 —— 免得有人误用于发布。
if [ "$STANDALONE" -eq 1 ]; then
    TMP_ENT="$(mktemp -d)"
    cat > "${TMP_ENT}/base.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST
    cat > "${TMP_ENT}/hv.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.hypervisor</key><true/>
</dict></plist>
PLIST
    HELPER_ENTITLEMENTS="${TMP_ENT}/base.entitlements"
    HYPERVISOR_ENTITLEMENTS="${TMP_ENT}/hv.entitlements"
    trap 'rm -rf "$TMP_ENT"' EXIT
fi

echo "sign_helpers: 身份 = ${IDENTITY}  standalone = ${STANDALONE}"

# 1) 动态库:不带 entitlements,库不是进程
for lib in "${FRAMEWORKS}"/*.dylib; do
    [ -e "$lib" ] || continue
    codesign --force --timestamp $RUNTIME_FLAG --sign "$IDENTITY" "$lib"
done

# 2) 可执行文件。只有 qemu-system-aarch64 需要 hypervisor entitlement ——
#    qemu-img 只读写磁盘镜像,swtpm 只跑 TPM 模拟,都不碰 Hypervisor.framework。
#    最小权限:不该给的不给。
codesign --force --timestamp $RUNTIME_FLAG \
    --entitlements "$HYPERVISOR_ENTITLEMENTS" \
    --sign "$IDENTITY" "${HELPERS}/qemu-system-aarch64"

for exe in qemu-img swtpm; do
    codesign --force --timestamp $RUNTIME_FLAG \
        --entitlements "$HELPER_ENTITLEMENTS" \
        --sign "$IDENTITY" "${HELPERS}/${exe}"
done

echo "sign_helpers: 完成"
