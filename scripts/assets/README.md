# 固件构建用的素材

`boot-logo.bmp` 是 UEFI 开机画面上的标识，`build_firmware.sh` 在编译前把它盖到
edk2 的 `MdeModulePkg/Logo/Logo.bmp`（原图是 TianoCore 的标识）。

**规格是 edk2 定死的，改图前先看这里**：24bpp 未压缩 BMP、`BITMAPINFOHEADER`
（40 字节 DIB 头）。PIL 的 `Image.save('x.bmp')` 对 `RGB` 模式正好写成这个格式。
背景必须是纯黑：固件清屏就是黑的，非黑背景会在画面中央露出一个色块。

重新生成（`kyvenza-k.svg` 是从 `.local/brand/kyvenza-avatar.svg` 收紧 viewBox
得来的，去掉了那张头像的深色底和大片留白）：

```bash
rsvg-convert -h 76 -o /tmp/kmark.png scripts/qemu/assets/kyvenza-k.svg
# 再用 PIL 把 K 与 KYVENZA 字样排到纯黑画布上，裁切居中后存 BMP
```

创建日期：2026-09-01
最后更新：2026-09-01
