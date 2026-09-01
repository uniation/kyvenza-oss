#!/usr/bin/env bash
# 构建随 Kyvenza 分发的 UEFI 固件与 NVRAM 模板(Windows 客体用)。
#
# 产出两个文件,`stage_helpers.sh` 会把它们装进 .app:
#   .local/qemu/firmware/secboot-code.fd   带 Secure Boot 的固件本体(只读挂载)
#   .local/qemu/firmware/secboot-vars.fd   预置了微软 PK/KEK/db 的 NVRAM 模板
#
# **为什么必须自建固件**(两条都是实测排除的,别再试发行版 prebuilt):
#  - QEMU 自带的 edk2 prebuilt 在 HVF 下能跑,但 `SECURE_BOOT_ENABLE` 默认 FALSE,
#    Win11 的「必须支持安全启动」过不去。
#  - Debian 的 AAVMF 有 Secure Boot,但在 HVF 下死循环(2026.05 与 2025.02 都试过,
#    零设备最小配置也复现;同一份固件在 TCG 下正常)。
#
# 做法是照抄 QEMU 自己那份「已知能在 HVF 上跑」的配置(`roms/edk2-build.config` 的
# `build.armvirt.aa64`),只加 `SECURE_BOOT_ENABLE=TRUE`。其中
# `PcdUninstallMemAttrProtocol=TRUE` 必须照搬 —— 怀疑正是它让 QEMU 那份固件能在
# HVF 下工作(Debian 的 secboot 变体启用了 EFI_MEMORY_ATTRIBUTE_PROTOCOL)。
#
# **为什么还要注入密钥**:自建产出的 VARS 是空白的,PK/KEK 都不存在,Secure Boot
# 处于 setup mode(实测 `dmpstore` 报 "No matching variables found")。这种状态下
# Windows 安装器的硬件检查会判定"该电脑必须支持安全启动"并拦下,只能靠改注册表
# 绕过 —— 而产品明确不走那条路。
#
# 自己用 virt-firmware 生成 PK、装入微软公开发布的 KEK 与 db,而不是抄 Debian 的
# `AAVMF_VARS.ms.fd`:那份文件能用(spike 验过),但我们要随包分发它,许可上得单独
# 确认。自己生成来源清楚、可复现,不引入第三方二进制的分发问题。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

QEMU_VERSION="${QEMU_VERSION:-11.1.0}"
WORK="${QEMU_BUILD_DIR:-${ROOT}/.local/qemu}"
EDK2="${WORK}/qemu-${QEMU_VERSION}/roms/edk2"
OUT="${WORK}/firmware"

# PK 的 CN。用我们自己的名字而不是微软的:PK 是「平台所有者」的密钥,平台是我们造的。
# KEK/db 才该是微软的 —— 那决定客体能不能引导微软签名的东西。
PLATFORM_KEY_CN="${PLATFORM_KEY_CN:-Kyvenza Platform Key}"

die() { echo "build_firmware: $*" >&2; exit 1; }

[ -d "$EDK2" ] || die "缺 edk2 源码 ${EDK2} —— 它在 QEMU 的 tarball 里,先跑 scripts/qemu/build_qemu.sh"
command -v aarch64-elf-gcc >/dev/null || die "缺交叉工具链:brew install aarch64-elf-gcc"
# ASL(ACPI 表)编译需要 iasl
command -v iasl >/dev/null || die "缺 iasl:brew install acpica"

VIRT_FW_VARS="${VIRT_FW_VARS:-$(command -v virt-fw-vars || ls "$HOME"/Library/Python/*/bin/virt-fw-vars 2>/dev/null | head -1)}"
[ -n "${VIRT_FW_VARS}" ] && [ -x "${VIRT_FW_VARS}" ] || \
    die "缺 virt-fw-vars:python3 -m pip install --user virt-firmware"

mkdir -p "$OUT"

# ── 1. 编译 edk2 ───────────────────────────────────────────────────
# edk2 的 BinWrappers 脚本硬调 `python`,而 macOS 只有 python3 —— 不设这个会在
# Trim/ASL 环节报 "exec: python: not found"。
export PYTHON_COMMAND="$(command -v python3)"

cd "$EDK2"

# BaseTools:macOS 上 edk2 自定义的 UINT8_MAX 与系统 SDK 头文件冲突,
# 而 CFLAGS 里有 -Werror → 必须放宽,否则 Decompress.c 直接编译失败。
if [ ! -x BaseTools/Source/C/bin/GenFw ]; then
    echo "==> 编译 BaseTools"
    make -C BaseTools -j"$(sysctl -n hw.ncpu)" \
        EXTRA_OPTFLAGS="-Wno-macro-redefined -Wno-error"
fi

# brew 的交叉编译器前缀是 aarch64-elf-,不是 QEMU 脚本里假设的 aarch64-linux-gnu-
export GCC5_AARCH64_PREFIX=aarch64-elf-
export GCC_AARCH64_PREFIX=aarch64-elf-
export WORKSPACE="$EDK2"
export PACKAGES_PATH="$EDK2"
export EDK_TOOLS_PATH="${EDK2}/BaseTools"

set +u
source ./edksetup.sh BaseTools >/dev/null
set -u

# edksetup.sh 之后必须**再 export 一次**:生成的 GNUmakefile 用 $(WORKSPACE) 引用
# 源文件,这个变量没传到 make 环境时路径会退化成 /MdePkg/… 并报
# "No rule to make target"(实测踩过)。
export WORKSPACE="$EDK2"
export PACKAGES_PATH="$EDK2"

# Homebrew 的 aarch64-elf-gcc 是 GCC 16,默认按 C23 编译,而 C23 把 bool 变成关键字 ——
# edk2-stable202408 里 `typedef BOOLEAN bool;`(LibFdtSupport.h)直接编译失败。
# Conf/tools_def.txt 由 edksetup.sh 生成、已存在则不覆盖,所以这里做成幂等的。
TOOLS_DEF="${EDK2}/Conf/tools_def.txt"
if ! grep -q "std=gnu11" "$TOOLS_DEF"; then
    sed -i '' 's|^DEFINE GCC5_AARCH64_CC_FLAGS *= *DEF(GCC49_AARCH64_CC_FLAGS)|DEFINE GCC5_AARCH64_CC_FLAGS         = DEF(GCC49_AARCH64_CC_FLAGS) -std=gnu11|' "$TOOLS_DEF"
    grep -q "std=gnu11" "$TOOLS_DEF" || die "未能给 GCC5 工具链加 -std=gnu11"
fi

echo "==> build ArmVirtQemu (AARCH64, Secure Boot 开启)"
build -a AARCH64 -t GCC5 -b RELEASE \
    -p ArmVirtPkg/ArmVirtQemu.dsc \
    -n "$(sysctl -n hw.ncpu)" \
    -D SECURE_BOOT_ENABLE=TRUE \
    -D NETWORK_HTTP_BOOT_ENABLE=TRUE \
    -D NETWORK_IP6_ENABLE=TRUE \
    -D NETWORK_TLS_ENABLE=TRUE \
    -D NETWORK_ISCSI_ENABLE=TRUE \
    -D NETWORK_ALLOW_HTTP_CONNECTIONS=TRUE \
    -D TPM2_ENABLE=TRUE \
    -D TPM2_CONFIG_ENABLE=TRUE \
    -D CAVIUM_ERRATUM_27456=TRUE \
    -D DEBUG_PRINT_ERROR_LEVEL=0x80000000 \
    --pcd gEfiMdeModulePkgTokenSpaceGuid.PcdDxeNxMemoryProtectionPolicy=0xC000000000007FD1 \
    --pcd gUefiOvmfPkgTokenSpaceGuid.PcdUninstallMemAttrProtocol=TRUE

FV="${EDK2}/Build/ArmVirtQemu-AARCH64/RELEASE_GCC5/FV"
[ -f "${FV}/QEMU_EFI.fd" ] || die "没产出 QEMU_EFI.fd"
[ -f "${FV}/QEMU_VARS.fd" ] || die "没产出 QEMU_VARS.fd"

# ── 2. 填充到 64 MiB ───────────────────────────────────────────────
# pflash 要求文件大小与 flash 一致,不足 QEMU 直接拒绝启动。
# 填充值用 0xFF(擦除态),与 QEMU 自己的构建脚本一致。
pad64() {
    python3 - "$1" <<'PY'
import sys
path = sys.argv[1]
size = 64 * 1024 * 1024
with open(path, 'r+b') as f:
    f.seek(0, 2)
    n = f.tell()
    if n > size:
        raise SystemExit(f'{path} 比 64 MiB 还大: {n}')
    f.write(b'\xff' * (size - n))
PY
}

cp "${FV}/QEMU_EFI.fd" "${OUT}/secboot-code.fd"
pad64 "${OUT}/secboot-code.fd"
cp "${FV}/QEMU_VARS.fd" "${OUT}/secboot-vars-blank.fd"
pad64 "${OUT}/secboot-vars-blank.fd"

# ── 3. 注入 Secure Boot 密钥 ───────────────────────────────────────
echo "==> 注入 Secure Boot 密钥(PK=${PLATFORM_KEY_CN})"
# --microsoft-kek all  : 2011 与 2023 两代 KEK,老 ISO 与新 ISO 都能验
# --microsoft-db win11 : Windows 引导链的签名证书(win11 含 2011 + 2023)
# --secure-boot        : 把 SecureBootEnable 置上,否则装好密钥也不强制
"${VIRT_FW_VARS}" \
    --input "${OUT}/secboot-vars-blank.fd" \
    --output "${OUT}/secboot-vars.fd" \
    --enroll-generate "${PLATFORM_KEY_CN}" \
    --microsoft-kek all \
    --microsoft-db win11 \
    --secure-boot

echo
echo "==> 产出"
ls -la "${OUT}/secboot-code.fd" "${OUT}/secboot-vars.fd" | awk '{printf "  %8.1f MB  %s\n", $5/1048576, $9}'
echo
echo "客体内验证方法(UEFI Shell):"
echo "    dmpstore -all SecureBoot   应为 01"
echo "    dmpstore -all SetupMode    应为 00"
echo "    dmpstore PK / KEK / db     都应存在"
