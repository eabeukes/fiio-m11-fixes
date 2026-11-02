# Technical notes

All facts are from one FiiO M11 on firmware 1.1.1 (2020-12-30 build). Addresses are virtual addresses in the named file.

## Device

| Item | Value |
|---|---|
| SoC | Samsung Exynos 7872 (board `maestro7872`) |
| Android | 7.0 (`NRD90M`), security patch 2017-04-01 |
| Kernel | 4.4.13 |
| Build | `user`, `test-keys`, SELinux permissive |
| DAC | `Exynos7872-AK4493` (ALSA card 0), through the Exynos ABOX DSP |
| Audio HAL | `/system/lib{,64}/hw/audio.primary.maestro7872.so` |
| Inputs | `gpio_keys`: power, volume (the gold wheel), previous, play/pause, next |

### Partitions (`mmcblk0`)

| # | Name | Size |
|---|---|---|
| p1 | fat | 100 MiB |
| p2 | system | 2000 MiB |
| p3 | userdata | 26000 MiB |
| p4 | cache | 300 MiB |
| p5 | modem | 100 MiB |
| p6 | efs | 20 MiB |
| p7 | recovery | 32 MiB |
| p8 | misc | 4 MiB |
| p9 | kernel | 20 MiB |
| p10 | ramdisk | 10 MiB |
| p11 | dtb | 4 MiB |
| p12 | ldfw | 5 MiB |
| p13 | engmode | 20 MiB |
| p14 | bootlogo | 2 MiB |
| p15 | charginglogo | 2 MiB |
| p16 | oemdata | 4 MiB |

The bootloader is in `mmcblk0boot0`. `efs` is per-unit data and is not in any firmware package.

## Bootloader

U-Boot with Samsung fastboot. The boot command:

```
movi read kernel 0 80080000; movi read rootfs 0 84000000 A00000; movi r d 0 88000000;
bootm 80080000 84000000 88000000
```

`ramdisk` and `recovery` are U-Boot legacy uImages (type ramdisk, compression "none") that wrap a gzip cpio. U-Boot checks the header CRC and the data CRC. Recovery uses its own ramdisk and the same `kernel` partition.

Keys at power-on (strings in the bootloader):

```
only next_key pressed, then enter recovery mode
only pre key was pressed,then enter fastboot
only pause_play_key pressed, will enter enginerring mode
all keys are pressed enable console log
```

## Recovery packages

- `/system/etc/security/otacerts.zip` holds only the AOSP test key (SHA-1 `61:ED:37:7E:85:D3:86:A8:DF:EE:6B:86:4B:D8:5B:0B:FA:A5:AF:81`).
- Recovery checks a whole-file signature in the format of `signapk -w`: PKCS#7, SHA-1, no signed attributes, in the zip comment with a 6-byte footer. `tools/common/sign-ota.py` makes and checks this.
- After the signature, FiiO's recovery reads `META-INF/com/android/metadata` and compares `pre-product` with `ro.product.name` (`M11`). If they do not match, it stops with `E:try_update_binary failed because product name do not match.`
- FiiO's updater app (`com.android.fiioupdate`, a fork of Rockchip's `RKUpdateService`) installs `.zip` files from storage through `RecoverySystem.installPackage`. Recovery maps `/storage/emulated/0` to `/data/media/0`.
- Recovery has `/sbin/sh`, but no `adb`. It saves no log that you can read without root.

## Root (Magisk v30.7)

`tools/root/patch-ramdisk.sh` follows Magisk's `boot_patch.sh` for a legacy (not system-as-root) ramdisk:

- `init` becomes `magiskinit`. The original goes to `.backup/init.xz`.
- The patch adds `overlay.d/sbin/{magisk,stub,init-ld}.xz`.
- The fstab patch removes `/verity_key`. The fstab files do not change.
- `.backup/.magisk` gets `KEEPVERITY=false`, `KEEPFORCEENCRYPT=false`, `PREINITDEVICE=mmcblk0p3` and the SHA-1 of the stock image.

The kernel has none of the Samsung RKP, DEFEX or PROCA patterns that `boot_patch.sh` patches, so it does not change. The new uImage keeps FiiO's header fields with new size, time and CRCs (about 3.07 MiB of 10 MiB).

`tools/root/flash-ramdisk.c` is the `update-binary` of the root and restore packages. It writes to `mmcblk0p10` only if its `PARTNAME` is `ramdisk`. The root package writes only if the partition holds exactly the stock image, and puts it back if the read-back fails.

## Root certificates

AOSP keeps its store in `platform/system/ca-certificates`, `files/`. On the test player, 68 roots were in both stores, 81 were only in AOSP, and 80 were only on the player. The module copies AOSP's files with a `.replace` marker, so Magisk replaces the whole directory.

`TrustedCertificateStore` looks up `<subject_hash_old>.0`, `.1`, and so on, and stops at the first missing number. So do not remove single files from the store.

Chrome 119 uses its own Chrome Root Store and does not show the effect. WebView, the download manager and most apps use the system store.

## Apple Music

Play Store version for Android 7.0: 4.9.7.2 (`minSdk=24`).

**Root check.** The app looks for `test-keys` in `Build.TAGS` and for `/system/bin/su`, `/system/xbin/su` and `/system/app/Superuser.apk`. Magisk's `/sbin/su` is not on the list.

**Sign-in.** `ro.serialno` and `ro.boot.serialno` are empty in FiiO's firmware, so `Build.SERIAL` is `unknown`. The app's `shared_prefs/foothill.xml` then has `guidSerialKey = 00000000000000`, and `sf-api-token-service.itunes.apple.com` answers `{"status":"verificationFailure"}`. With `ro.serialno` set to the chip ID (zero-padded to 16 hex characters, as the USB serial), the app makes a unique ID and sign-in works. Clear the app's data after you change the serial number.

**DRM.** The M11 has no Widevine (`/system/vendor/lib{,64}/mediadrm` has only `libdrmclearkeyplugin.so`). Apple Music streams use FairPlay (`SVFootHillSessionCtrl::_getCKC()`) and play without Widevine.

## The static AudioTrack bug

**Symptom.** At start, ExoPlayer makes a static track: 4000 Hz, mono, 16-bit, 2-byte buffer (`initializeKeepSessionIdAudioTrack`). AudioFlinger refuses it:

```
E AudioFlinger: createTrack_l() initCheck failed -12; no control block?
I snet_event_log: [38340117,-1,]
```

**Server side** (`/system/lib/libaudioflinger.so`, 32-bit):

- `PlaybackThread::Track::Track` at `0x3c1c0`. At `0x3c304..0x3c312` it compares `IMemory::size()` with `frameCount * mFrameSize` (`mFrameSize` at `+0x3c`). If the buffer is smaller, it frees the control block and writes event `38340117` (AOSP security fix).
- `TrackBase` (`0x3b2bc`) computes `mFrameSize` as channel count × bytes per sample. Mono 16-bit gives 2. FiiO added the formats `0x0D000000` and `0x0E000001`/`0x0E000002`.
- `createTrack_l` raises a small frame count to a minimum only when `sharedBuffer == 0` (`0x2eeda`), so the server does not change the frame count of static tracks.

**Client side** (`/system/lib64/libmedia.so`, `AudioTrack::createTrack_l` at `0xbff30`):

- `0xc05dc` calls `IMemory::size()` on the static path, then ignores the result.
- `0xc05f0..0xc0628` sets the frame count of every track to `min(mAfLatency * mSampleRate / 1000, 8192)` (`mAfLatency` at `[this,#120]`, from `AudioSystem::getLatency` at `0xc01f8`).
- The value goes to `IAudioFlinger::createTrack` at `0xc06e4`.

AOSP 7.0 uses `frameCount = mSharedBuffer->size() / mFrameSize` for static tracks.

**Patch** (`tools/audio-fix/make-patch.sh`, 60 bytes at `0xc05a8..0xc05e3`, file offset `0x5b5a8`):

```
c05a8: cbnz x8, c05c4          ; misaligned buffer -> error path
c05ac: bl   IMemory::size      ; x0 = buffer size in bytes
c05b0: ldr  x9, [x19, #496]    ; mFrameSize
c05b4: udiv x24, x0, x9        ; frameCount = size / mFrameSize
c05b8: str  wzr, [sp, #156]    ; as at c0614
c05bc: ldr  w8, [x19, #672]    ; as at c0618
c05c0: b    c062c              ; continue after FiiO's csel
c05c4: mov  w8, #-22 ; stur w8, [x29, #-108] ; b c02c0   ; same error status, no log line
c05d0..c05e0: nop
```

| File | SHA-256 |
|---|---|
| Stock `lib64/libmedia.so` (2020 and 2022 builds of 1.1.1) | `c7933a37ed80c7ff7d9e1c720fc33a258cc5478630c97955c3476dd5feceeefb` |
| Patched | `48de0468b7beb8dacc0c05087038cdadae80a085509461f8cc07ddfdf54ac866` |
| Stock `lib/libmedia.so` (32-bit, not patched) | `12a6325723cfa85fc7985d476240981932b5cb34a8a7464d3d9983c0ee24d8a8` |

Streaming tracks do not enter `0xc05a8..0xc05e3`. The only branch into the range was the original `cbz` at `0xc05a8`.

## Audio after the changes

- FiiO Music: `pcm0p` at `S16_LE`, 2 channels, 44100 Hz. The mixer follows the file's sample rate (192 kHz when idle).
- Apple Music (48 kHz AAC stream): `pcm0p` at `S16_LE`, 2 channels, 48000 Hz.

To see the DAC state while something plays (as root):

```bash
adb shell su -c 'cat /proc/asound/card0/pcm0p/sub0/status /proc/asound/card0/pcm0p/sub0/hw_params'
```
