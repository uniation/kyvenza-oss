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

    # ── 剪贴板代理(vdagent)────────────────────────────────────
    # 与三个驱动一起摊在盘根目录。**全世界没有现成的 ARM64 版本**(上游只发
    # x86/x64,UTM 的安装器里那一支写着 TODO),所以这两个 exe 是我们自己交叉
    # 编译的,配方见 scripts/guest-tools/build_vdagent.sh —— GPLv2+,构建脚本
    # 与补丁随源码交付包一起公开。
    #
    # 少了它们,界面上的「共享剪贴板」开关就是个不生效的摆设,而那正是
    # 2026-09-03 刚清理掉的一类问题。所以这里缺文件要**报错退出**,
    # 不像 virtio-win 那样只警告 —— 剪贴板开关是随包功能,不能靠人记得补。
    VDAGENT_BIN="${VDAGENT_BIN_DIR:-${ROOT}/.local/vdagent/out/bin}"
    for exe in vdagent.exe vdservice.exe; do
        [ -f "${VDAGENT_BIN}/${exe}" ] || die \
            "缺 ${VDAGENT_BIN}/${exe},先跑 make guest-tools(或设 VDAGENT_BIN_DIR)"
        cp "${VDAGENT_BIN}/${exe}" "${STAGE_DIR}/"
    done

    # ── 可双击的安装器 ──────────────────────────────────────────
    # virtio-win 上游只提供 x64/x86 的 guest-tools MSI,**ARM64 没有安装器**,
    # 所以"像 Parallels 那样双击装工具"这条路得我们自己铺。
    #
    # 为什么不能只靠设备管理器:装机阶段显示设备是 ramfb,客体里根本没有
    # virtio-gpu 这块 PCI 设备,「更新驱动」没有目标可选。pnputil 把驱动放进
    # 驱动仓库,等 Complete Install 之后设备出现时 Windows 自己绑定。
    #
    # 换行必须是 CRLF:cmd.exe 解析 LF 换行的批处理会出莫名其妙的语法错误。
    # **批处理正文只能是 ASCII**(下面 encode("ascii") 会把关);中文缘由一律写在
    # 这里,不要写进 rem 行 —— 客体的 OEM 代码页也显示不出来。
    #
    # 关于 pnputil 的退出码:259 = 没有新驱动可加(驱动早装过、或重复运行安装器),
    # 3010 = 装好了但要重启,两者都是成功。2.1.0 之前写成 `if errorlevel 1 goto
    # failed`,于是所有从旧版本升级上来的用户(驱动早已就位)一跑安装器就跳到
    # failed,**剪贴板代理从来没被装上**,而且界面上没有任何迹象。真机上复现过。
    # 剪贴板代理与驱动是两件独立的事,现在无论驱动那步结果如何都会装。
    /usr/bin/python3 - "$STAGE_DIR" <<'PYEOF'
import io, os, sys
# 原始字符串:脚本里有 Windows 路径的反斜杠,普通字符串里 \K 之类是非法转义。
script = r"""@echo off
title Kyvenza Guest Tools

net session >nul 2>&1
if not errorlevel 1 goto install
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:install
echo.
echo    Kyvenza - Windows guest tools
echo    ============================
echo.
echo    Installing display, network and serial drivers...
echo.
pnputil /add-driver "%~dp0*.inf" /install
set PNPRESULT=%errorlevel%
set DRIVERS=ok
rem pnputil returns non-zero on success too: 259 means there was nothing new to
rem add (the normal case when the drivers are already installed), 3010 means it
rem installed them but wants a reboot. Treating those as failures skips
rem everything below.
if %PNPRESULT% equ 0 goto clipboard
if %PNPRESULT% equ 259 goto clipboard
if %PNPRESULT% equ 3010 goto clipboard
set DRIVERS=failed
echo    Driver installation reported code %PNPRESULT%.

:clipboard
echo.
echo    Installing the clipboard agent...
echo.
rem The clipboard agent is independent of the drivers, so it installs either way.
rem The service records an absolute path to its executable, so the agent has to
rem live on the system drive. Registering it straight off this disc would break
rem the moment the disc is ejected or swapped.
set "KYVDIR=%ProgramFiles%\Kyvenza"
if not exist "%KYVDIR%" mkdir "%KYVDIR%"
rem Stop the old copy BEFORE overwriting it. On an upgrade the running agent
rem holds its own executable open, so copying first fails with "another program
rem is using this file" while the installer still reports success - the service
rem re-registers happily, pointing at the OLD binary. The machine then keeps the
rem previous agent forever and nothing on screen says so. Seen on a real guest.
sc stop vdservice >nul 2>&1
sc delete vdservice >nul 2>&1
rem sc returns as soon as the stop is pending, and vdagent.exe runs in the user
rem session rather than as the service itself, so neither file is free yet.
timeout /t 3 /nobreak >nul
taskkill /f /im vdagent.exe >nul 2>&1
copy /Y "%~dp0vdagent.exe" "%KYVDIR%\" >nul
if errorlevel 1 goto agentbusy
copy /Y "%~dp0vdservice.exe" "%KYVDIR%\" >nul
if errorlevel 1 goto agentbusy
"%KYVDIR%\vdservice.exe" install
sc start vdservice >nul 2>&1
rem sc start returns as soon as the service is START_PENDING, so give it a
rem moment before asking whether it is actually running.
timeout /t 3 /nobreak >nul
sc query vdservice | find "RUNNING" >nul
if errorlevel 1 (
    echo    The clipboard agent did not start. Everything else is installed;
    echo    shared clipboard stays off until it does.
) else (
    echo    Clipboard agent running.
)
goto shares

:agentbusy
echo    Could not replace the clipboard agent: it is still in use.
echo    Restart Windows and run this installer again.

:shares
echo.
echo    Setting up shared folders...
echo.
rem Shared folders ride on Windows' own WebDAV client (the WebClient service).
rem Nothing is installed here: this only turns that service on and raises two of
rem its limits. It is independent of the drivers and of the clipboard agent, so
rem it runs whatever happened above.
sc config WebClient start= auto >nul 2>&1
rem WebClient refuses files larger than 50 MB by default, which is far too small
rem for the thing people actually use a shared folder for. 0xFFFFFFFF is the
rem maximum the service accepts.
reg add "HKLM\SYSTEM\CurrentControlSet\Services\WebClient\Parameters" /v FileSizeLimitInBytes /t REG_DWORD /d 4294967295 /f >nul 2>&1
rem The other default cap is on how much directory metadata one listing may
rem return; a folder with a few thousand files hits it and simply fails to open.
reg add "HKLM\SYSTEM\CurrentControlSet\Services\WebClient\Parameters" /v FileAttributesLimitInBytes /t REG_DWORD /d 8000000 /f >nul 2>&1
rem Both limits are read when the service starts, so restart it here rather than
rem leaving the user with settings that only take effect after the next reboot.
sc stop WebClient >nul 2>&1
sc start WebClient >nul 2>&1

copy /Y "%~dp0Find-Kyvenza-Shares.cmd" "%KYVDIR%\" >nul
rem Map the drive at every logon. The task must run with a LIMITED token: drive
rem letters mapped by an elevated process belong to the elevated session and are
rem invisible to Explorer, so an administrator task would look like it worked
rem while no drive ever appeared.
schtasks /create /tn "Kyvenza Shared Folders" /sc onlogon /rl limited /f /tr "\"%KYVDIR%\Find-Kyvenza-Shares.cmd\"" >nul 2>&1
if errorlevel 1 (
    echo    Could not register the logon task. You can still connect the shares
    echo    by double-clicking Connect-Kyvenza-Shares on the KYVENZA disc.
) else (
    echo    Shared folders will connect at every sign-in.
)

:ssh
echo.
echo    Enabling remote command access...
echo.
rem This is what lets Kyvenza (and an AI assistant driving it) run commands
rem inside this VM. It turns on Windows' own OpenSSH Server and nothing else:
rem no third-party binary is installed, and the server only ever listens on the
rem VM's own network, which Kyvenza forwards to 127.0.0.1 on the Mac.
rem
rem OpenSSH Server is a Feature on Demand, so this step needs the VM to have
rem internet access the first time. Failing here is not fatal: everything above
rem already worked, and the user can re-run this installer once online.
sc query sshd >nul 2>&1
if not errorlevel 1 goto sshconfig
dism /online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 /quiet /norestart >nul 2>&1
sc query sshd >nul 2>&1
if errorlevel 1 (
    echo    Could not install OpenSSH Server. This step needs internet access
    echo    in the VM. Connect it to the network and run this installer again.
    echo    Everything else above is already set up.
    goto performance
)

:sshconfig
sc config sshd start= auto >nul 2>&1
net start sshd >nul 2>&1
rem Without this rule sshd listens on 0.0.0.0:22 and the Mac still cannot reach
rem it. The rule OpenSSH's own installer creates is scoped to network profiles
rem that this VM's NAT adapter does not match, and a blocked connection looks
rem exactly like a VM that never finished booting. Verified on Windows 11 25H2:
rem sshd RUNNING, port LISTENING, host got no banner until this rule existed.
rem
rem remoteip pins it to 10.0.2.2, the NAT gateway, which is this Mac and nothing
rem else. Opening port 22 to every profile would also expose sshd to the real
rem network the moment the user switches the VM to bridged networking.
netsh advfirewall firewall delete rule name="Kyvenza SSH (host only)" >nul 2>&1
netsh advfirewall firewall add rule name="Kyvenza SSH (host only)" dir=in action=allow protocol=TCP localport=22 remoteip=10.0.2.2 >nul 2>&1
rem The per-VM public key is NOT on this disc: this disc ships with Kyvenza and
rem is the same for every VM, while each VM has its own key. The key arrives on
rem the small KYVENZA script disc instead, which Kyvenza rewrites at every boot.
copy /Y "%~dp0Find-Kyvenza-SSH.cmd" "%KYVDIR%\" >nul 2>&1
call "%KYVDIR%\Find-Kyvenza-SSH.cmd" /quiet >nul 2>&1
rem Report the outcome rather than assuming it. A wrong ACL on the key file makes
rem sshd ignore it *silently* - the only trace is in the Event Viewer - so the
rem failure has to be visible here, while the user is still looking.
sc query sshd | find "RUNNING" >nul 2>&1
if errorlevel 1 (
    echo    OpenSSH Server is installed but not running. Check the Event Viewer.
) else (
    if not exist "%ProgramData%\ssh\administrators_authorized_keys" (
        echo    OpenSSH Server is running, but this VM's key was not found.
        echo    Open the KYVENZA disc and run Configure-Kyvenza-SSH as administrator.
    ) else (
        netsh advfirewall firewall show rule name="Kyvenza SSH (host only)" >nul 2>&1
        if errorlevel 1 (
            echo    OpenSSH Server is running, but the firewall rule is missing,
            echo    so the Mac cannot reach it. Run this installer again.
        ) else (
            echo    Remote command access is ready.
        )
    )
)

:performance
echo.
echo    Turning off desktop effects that are slow without a GPU...
echo.
rem The display driver has no 3D acceleration, so every DWM effect - window
rem animations, transparency, dragging a window with its contents showing - is
rem rendered on the CPU and pushed through the display channel as a large dirty
rem region. These four values are the ones "Adjust for best performance" sets:
rem all under HKCU, all reversible from Settings > Accessibility > Visual effects
rem and System > Advanced system settings > Performance. The UAC prompt keeps the
rem signed-in user's hive when that user is an administrator, which is the normal
rem setup on a fresh Windows install.
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 2 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v EnableTransparency /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\Control Panel\Desktop\WindowMetrics" /v MinAnimate /t REG_SZ /d 0 /f >nul 2>&1
reg add "HKCU\Control Panel\Desktop" /v DragFullWindows /t REG_SZ /d 0 /f >nul 2>&1
rem Explorer and DWM read these at sign-in; poke them now so the change is
rem visible without signing out. The call is best-effort.
rundll32.exe user32.dll,UpdatePerUserSystemParameters 1, True >nul 2>&1
echo    Desktop effects set to best performance. Undo it any time in
echo    Settings ^> Accessibility ^> Visual effects.

echo.
if "%DRIVERS%"=="failed" goto failed
echo    Done.
echo.
echo    Next: shut Windows down. In Kyvenza, click "Complete Install",
echo    then start the VM again. The display switches to the virtio
echo    adapter on that boot.
echo.
rem Reinstalling restarts the agent service, which drops the channel the host
rem opened when the display window appeared - and the host does not reconnect on
rem its own. The clipboard then does nothing at all, text included, with nothing
rem on screen to explain why. Every upgrading user runs this installer, so say it
rem here rather than leaving them to find it.
echo    If Kyvenza's display window was open while this ran, close it and
echo    open it again. The clipboard reconnects with the window.
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
# 登录时跑的小脚本。**它不能内嵌 URL** —— 端口与 token 是每台 VM 一份、
# 且可能在启动时变,而这张光盘是随包的、所有 VM 共用。所以它只负责去各个盘符里
# 找那张 KYVENZA 脚本盘,真正的地址在那上面。
finder = r"""@echo off
rem Find the Kyvenza shares disc and run the connect script on it. The disc is a
rem small read-only volume the app attaches at every boot; it carries this VM's
rem own address, which this file deliberately does not.
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist %%d:\Connect-Kyvenza-Shares.cmd (
        call %%d:\Connect-Kyvenza-Shares.cmd
        exit /b 0
    )
)
exit /b 1
"""

# SSH 侧同构:这张光盘上只有「去找那张盘」的逻辑,每台 VM 独有的公钥在那张盘上。
ssh_finder = r"""@echo off
rem Find the Kyvenza script disc and run the SSH setup on it. That disc carries
rem this VM's own public key, which this file deliberately does not: this disc
rem ships with the app and is identical for every VM.
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist %%d:\Configure-Kyvenza-SSH.cmd (
        call %%d:\Configure-Kyvenza-SSH.cmd %*
        exit /b 0
    )
)
exit /b 1
"""

for name, text in (("Install-Kyvenza-Drivers.cmd", script),
                   ("Find-Kyvenza-Shares.cmd", finder),
                   ("Find-Kyvenza-SSH.cmd", ssh_finder)):
    out = os.path.join(sys.argv[1], name)
    io.open(out, "wb").write(text.replace("\n", "\r\n").encode("ascii"))
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
