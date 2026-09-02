#!/usr/bin/env bash
# 把 QEMU 运行时资源装进 .app。
#
# 用法: scripts/qemu/stage_helpers.sh <app-bundle-path>
#
# 布局(与 `QEMURuntimeResources.locate()` 一一对应,改这里要同步改那边):
#   Contents/Helpers/qemu-system-aarch64      可执行文件
#   Contents/Helpers/qemu-img
#   Contents/Helpers/swtpm
#   Contents/Frameworks/*.dylib               动态库闭包
#   Contents/Resources/qemu/secboot-code.fd   带 Secure Boot 的 UEFI 固件(只读)
#   Contents/Resources/qemu/secboot-vars.fd   预置微软 PK/KEK/db 的 NVRAM 模板
#   Contents/Resources/qemu/share/…           QEMU 的 ROM 数据目录(-L)
#   Contents/Resources/qemu/drivers.iso        virtio-win ARM64 驱动光盘(挂给客体)
#
# **可执行文件与数据必须分开放,这不是洁癖(踩过)。**
# `Contents/Helpers` 与 `Contents/Frameworks` 都在 codesign 的 nested-code 路径里,
# 里面的东西会被当作代码逐个检查。virtio-win 的驱动是 Windows PE 文件,codesign
# 按内容认得出来,于是给外层 .app 签名时直接失败:
#     code object is not signed at all
#     In subcomponent: …/Contents/Helpers/drivers/NetKVM/netkvm.sys
# 我们既不能也不该用 Mac 身份去签客体驱动。去掉执行位没用 —— 识别看的是文件内容。
# 放进 `Contents/Resources` 就只按资源哈希,不再走嵌套代码那条路。
# QEMU 的 ROM(efi-virtio.rom 是 EFI PE)与固件同理,一并放 Resources。
#
# **为什么要改 install name**:Homebrew 的库记的是 /opt/homebrew/... 绝对路径,
# 用户机器上没有 Homebrew 就加载失败。全部改写成 @executable_path / @loader_path
# 相对路径,包才是自足的。
set -euo pipefail

APP="${1:?用法: stage_helpers.sh <app-bundle-path>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

QEMU_PREFIX="${QEMU_PREFIX:-${ROOT}/.local/qemu/install}"
SWTPM_BIN="${SWTPM_BIN:-$(command -v swtpm || true)}"
FIRMWARE_DIR="${FIRMWARE_DIR:-${ROOT}/.local/qemu/firmware}"
VIRTIO_WIN_ISO="${VIRTIO_WIN_ISO:-${ROOT}/.local/qemu/virtio-win.iso}"

HELPERS="${APP}/Contents/Helpers"
FRAMEWORKS="${APP}/Contents/Frameworks"
# 非可执行的随包数据。必须在 Resources 下,见文件头的说明。
DATA="${APP}/Contents/Resources/qemu"

die() { echo "stage_helpers: $*" >&2; exit 1; }

[ -d "$APP" ] || die "app bundle 不存在: $APP"
[ -x "${QEMU_PREFIX}/bin/qemu-system-aarch64" ] || \
    die "缺 QEMU,先跑 scripts/qemu/build_qemu.sh"
[ -n "$SWTPM_BIN" ] && [ -x "$SWTPM_BIN" ] || \
    die "缺 swtpm(brew install swtpm)。没有它 Windows 客体装不了"
[ -f "${FIRMWARE_DIR}/secboot-code.fd" ] || \
    die "缺固件 ${FIRMWARE_DIR}/secboot-code.fd,先跑 scripts/qemu/build_firmware.sh"
[ -f "${FIRMWARE_DIR}/secboot-vars.fd" ] || \
    die "缺 NVRAM 模板 ${FIRMWARE_DIR}/secboot-vars.fd,先跑 scripts/qemu/build_firmware.sh"

rm -rf "$HELPERS" "$DATA"
mkdir -p "$HELPERS" "$FRAMEWORKS" "$DATA"

# ── 可执行文件 ─────────────────────────────────────────────────────
for exe in qemu-system-aarch64 qemu-img; do
    cp "${QEMU_PREFIX}/bin/${exe}" "${HELPERS}/${exe}"
done
cp "$SWTPM_BIN" "${HELPERS}/swtpm"
chmod u+w "${HELPERS}"/*

# ── 动态库闭包 ─────────────────────────────────────────────────────
# 逐个展开依赖,直到没有新的非系统库为止。realpath 把 Homebrew 的
# opt/ 符号链接解开,否则同一个库会按两个路径各拷一份。
# 注意:macOS 自带的是 bash 3.2,没有 mapfile,数组语法也更挑剔 ——
# 这里一律走临时文件,别改成 bash 4 的写法。
QUEUE_FILE="$(mktemp)"; SEEN_FILE="$(mktemp)"
trap 'rm -f "$QUEUE_FILE" "$SEEN_FILE"' EXIT
for exe in qemu-system-aarch64 qemu-img swtpm; do
    echo "${HELPERS}/${exe}" >> "$QUEUE_FILE"
done
while [ -s "$QUEUE_FILE" ]; do
    cur="$(head -1 "$QUEUE_FILE")"
    sed -i '' '1d' "$QUEUE_FILE"
    [ -f "$cur" ] || continue
    # realpath 把 Homebrew 的 opt/ 符号链接解开,否则同一个库会按两个路径各拷一份
    cur="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$cur")"
    grep -qxF "$cur" "$SEEN_FILE" && continue
    echo "$cur" >> "$SEEN_FILE"
    otool -L "$cur" 2>/dev/null | tail -n +2 | awk '{print $1}' \
        | grep -v -e '^/usr/lib/' -e '^/System/' -e '^@' >> "$QUEUE_FILE" || true
done

# 跳过可执行文件自身。**必须拿 realpath 后的 HELPERS 去比**:上面收集闭包时对每个
# 条目做了 realpath,而 /tmp 会解析成 /private/tmp —— 用原始 $HELPERS 前缀匹配会失配,
# 结果把 qemu-system-aarch64 / qemu-img / swtpm 又各拷一份进 Frameworks
# (多 35 MB,而且是把可执行文件塞进嵌套代码目录)。踩过。
HELPERS_REAL="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$HELPERS")"
while read -r lib; do
    case "$lib" in "${HELPERS}/"*|"${HELPERS_REAL}/"*) continue ;; esac
    cp "$lib" "${FRAMEWORKS}/$(basename "$lib")"
done < "$SEEN_FILE"
chmod u+w "${FRAMEWORKS}"/*.dylib

# ── 改写 install name ──────────────────────────────────────────────
rewrite() {
    local target="$1" prefix="$2" dep base
    while read -r dep; do
        [ -z "$dep" ] && continue
        base="$(basename "$dep")"
        [ -f "${FRAMEWORKS}/${base}" ] || die "闭包漏了 ${base}(被 ${target} 引用)"
        install_name_tool -change "$dep" "${prefix}/${base}" "$target"
    done < <(otool -L "$target" 2>/dev/null | tail -n +2 | awk '{print $1}' \
             | grep -v -e '^/usr/lib/' -e '^/System/' -e '^@')
}

# 先去掉上游带来的签名(Homebrew 的库和 QEMU 自己的 ad-hoc 签名)。
# 不去掉的话 install_name_tool 每改一处就警告一次"签名将失效",
# 留下的也是一堆已损坏的签名 —— 反正后面都要用我们的身份重签。
strip_signature() {
    codesign --remove-signature "$1" 2>/dev/null || true
}

for exe in qemu-system-aarch64 qemu-img swtpm; do
    strip_signature "${HELPERS}/${exe}"
    rewrite "${HELPERS}/${exe}" '@executable_path/../Frameworks'
done
for lib in "${FRAMEWORKS}"/*.dylib; do
    strip_signature "$lib"
    install_name_tool -id "@loader_path/$(basename "$lib")" "$lib"
    rewrite "$lib" '@loader_path'
done

# ── QEMU 的 ROM 数据目录 ───────────────────────────────────────────
# QEMU 装出来的 share/qemu 有 316 MB,其中绝大部分是别的架构的固件
# (edk2-aarch64/arm/riscv/loongarch/i386…),我们自带 edk2、一个都用不上。
# 只挑真正需要的:
#   efi-virtio.rom     virtio-net-pci 的 option ROM。**少了它 QEMU 直接退出**
#                      (failed to find romfile "efi-virtio.rom"),不是可选项。
#   vgabios-ramfb.bin  装机阶段的 ramfb 显示设备
#   keymaps/           VNC 的键盘映射表
# 合计约 1.2 MB。以后加设备时若报 romfile 找不到,在这里补一个,
# 别把整个 share/qemu 拷进来。
mkdir -p "${DATA}/share"
for blob in efi-virtio.rom vgabios-ramfb.bin; do
    SRC_BLOB="${QEMU_PREFIX}/share/qemu/${blob}"
    [ -f "$SRC_BLOB" ] || die "QEMU 数据目录里没有 ${blob}"
    cp "$SRC_BLOB" "${DATA}/share/${blob}"
done
cp -R "${QEMU_PREFIX}/share/qemu/keymaps" "${DATA}/share/keymaps"

# ── 固件与 NVRAM 模板 ──────────────────────────────────────────────
cp "${FIRMWARE_DIR}/secboot-code.fd" "${DATA}/secboot-code.fd"
cp "${FIRMWARE_DIR}/secboot-vars.fd" "${DATA}/secboot-vars.fd"

# ── virtio-win 驱动(只取产品真正用得到的三个)────────────────────
# 每个都对应 QEMUCommandBuilder 里的一个设备,别多打包:
#   viogpudo  ← -device virtio-gpu-pci
#   NetKVM    ← -nic user,model=virtio-net-pci
#   vioserial ← -device virtio-serial-pci(剪贴板 vdagent 通道)
# 许可:ISO 内 virtio-win_license.txt 为 BSD 3-Clause,允许二进制再分发;
# 驱动目录签名者是微软 WHQL,Secure Boot 客体可直接安装(2026-08-31 实测)。
# .pdb 是调试符号,占 34 MB 且客体用不上,不打包。
if [ -f "$VIRTIO_WIN_ISO" ]; then
    MOUNT="$(hdiutil attach -readonly -nobrowse -plist "$VIRTIO_WIN_ISO" \
        | /usr/bin/python3 -c 'import plistlib,sys; d=plistlib.loads(sys.stdin.buffer.read()); print([e["mount-point"] for e in d["system-entities"] if "mount-point" in e][0])')"
    trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rm -f "$QUEUE_FILE" "$SEEN_FILE"' EXIT
    # **三个驱动摊平放在同一层,不分子目录。这是有意的,别改回去。**
    #
    # Windows 在 OOBE 的联网页提供「安装驱动程序」按钮,弹出的是一个文件夹选择器。
    # 选盘符时 Windows 会递归扫描、把三个驱动一次全装上;但如果用户drill 进
    # `E:\NetKVM` 这样的子目录,就只装网卡 —— 装完切到 virtio-gpu 时客体没有
    # viogpudo,**画面永久全黑**(实测:QEMU 的 VNC 报 "Display output is not
    # active.",VM 状态 running、串口显示 Windows 正常引导,但一帧画面都没有)。
    # 摊平之后盘上没有子目录可选,这条路径就不存在了。
    #
    # 文件名不冲突:三个驱动共 15 个文件(去掉 .pdb),名字两两不同,已核对。
    STAGE_DIR="$(mktemp -d)"
    for drv in NetKVM viogpudo vioserial; do
        SRC_DIR="${MOUNT}/${drv}/w11/ARM64"
        [ -d "$SRC_DIR" ] || die "virtio-win ISO 里没有 ${drv}/w11/ARM64"
        # Readme.md 只属于 NetKVM,摊平后放在根目录会让人以为是整张盘的说明,不要
        find "$SRC_DIR" -type f ! -name '*.pdb' ! -name 'Readme.md' \
            -exec cp {} "${STAGE_DIR}/" \;
    done
    cp "${MOUNT}/virtio-win_license.txt" "${STAGE_DIR}/LICENSE.txt"

    # ── 可双击的安装器 ──────────────────────────────────────────
    # virtio-win 上游只提供 x64/x86 的 guest-tools MSI,**ARM64 没有安装器**,
    # 所以"像 Parallels 那样双击装工具"这条路得我们自己铺。
    #
    # 为什么不能只靠设备管理器:装机阶段显示设备是 ramfb,客体里根本没有
    # virtio-gpu 这块 PCI 设备,「更新驱动」没有目标可选。pnputil 把驱动放进
    # 驱动仓库,等 Complete Install 之后设备出现时 Windows 自己绑定。
    #
    # 换行必须是 CRLF:cmd.exe 解析 LF 换行的批处理会出莫名其妙的语法错误。
    /usr/bin/python3 - "$STAGE_DIR" <<'PYEOF'
import io, os, sys
script = """@echo off
title Kyvenza Guest Drivers

net session >nul 2>&1
if not errorlevel 1 goto install
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:install
echo.
echo    Kyvenza - Windows guest drivers
echo    ===============================
echo.
echo    Installing display, network and serial drivers...
echo.
pnputil /add-driver "%~dp0*.inf" /install
if errorlevel 1 goto failed
echo.
echo    Done.
echo.
echo    Next: shut Windows down. In Kyvenza, click "Complete Install",
echo    then start the VM again. The display switches to the virtio
echo    adapter on that boot.
echo.
pause
exit /b 0

:failed
echo.
echo    Something went wrong. Please report this to support@kyvenza.com.
echo.
pause
exit /b 1
"""
out = os.path.join(sys.argv[1], "Install-Kyvenza-Drivers.cmd")
io.open(out, "wb").write(script.replace("\n", "\r\n").encode("ascii"))
PYEOF

    chmod -R u+w "$STAGE_DIR"

    # 打成只读光盘再随包,而不是摊成一堆散文件。两个理由:
    # 1) 客体侧:引擎把它挂成 CD-ROM,用户看到的是一个正常光驱,不是一块来路不明的
    #    FAT 盘(vvfat 在安装器的"选择安装位置"里会顶着 QEMU VVFAT 的名字出现)。
    # 2) 宿主侧:一个不透明的数据文件,codesign 不会去看里面。散着放的话即便在
    #    Resources 下也多一份被当嵌套代码检查的风险。
    hdiutil makehybrid -quiet -iso -joliet \
        -default-volume-name "KYVENZA-DRIVERS" \
        -o "${DATA}/drivers.iso" "$STAGE_DIR"
    # 许可文本在包外也留一份,便于查看,不必挂载光盘
    cp "${MOUNT}/virtio-win_license.txt" "${DATA}/drivers-LICENSE.txt"
    rm -rf "$STAGE_DIR"
else
    echo "stage_helpers: 警告 —— 缺 ${VIRTIO_WIN_ISO},不打包 virtio 驱动" >&2
    echo "               客体将没有网卡和显示驱动。发布前必须补上。" >&2
fi

echo "stage_helpers: 完成"
du -sh "$HELPERS" "$FRAMEWORKS" | sed 's/^/  /'
