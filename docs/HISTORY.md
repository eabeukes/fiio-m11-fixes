# History: how we got here

This is the order in which things happened, on one FiiO M11 on firmware 1.1.1, over one day (2 November 2026). The owner worked with an AI coding assistant (Claude). The assistant ran the commands over `adb` and wrote the tools. The owner pressed the buttons on the player and made the decisions. A webcam pointed at the screen showed recovery, because recovery has no `adb`.

This history includes dead ends and mistakes, because they explain some choices in the tools.

## 1. The question: a newer Android?

The first request was a newer Android version that keeps the player working as a DAP and a DAC. We decided against it before we touched the player:

- The M11 started on Android 7.0. It has no `vendor` partition and is not Treble-compatible, so generic system images (GSIs) do not boot on it.
- Nobody publishes a custom ROM for the Exynos 7872.
- FiiO ships its audio driver (`audio.primary.maestro7872.so`), the AK4493 setup and the USB DAC mode only as binaries for this kernel and this Android version. On a newer Android, the best result is probably resampled audio. The likely result is no audio.

The new goal: keep Android 7 and fix what is broken on it.

## 2. Inventory (read only)

With USB debugging on, `adb` showed the important facts:

- `ro.build.tags=test-keys`. The file `/system/etc/security/otacerts.zip` holds only the public AOSP test key. **The stock recovery accepts any package signed with a key that everyone has.** This made all later steps possible without unlocking anything.
- SELinux is permissive.
- There is no `boot` partition. The kernel, the ramdisk and the device tree are separate partitions (`kernel`, `ramdisk`, `dtb`).
- The system store had 148 root certificates and no ISRG Root X1.

## 3. A backup package, and FiiO's extra recovery check

We wrote a small static ARM64 program that recovery runs as its `update-binary`. It only reads. It copies every partition to internal storage. We signed it with the AOSP test key and started it with FiiO's own updater app.

The first try failed. The webcam showed `Installation aborted.` after the signature check passed. Android saved no recovery log that we could read without root.

To find the reason, we downloaded FiiO's own 1.1.1 package from FiiO's forum and unpacked its recovery. Its `recovery` binary contains this message:

```
E:try_update_binary failed because product name do not match.
```

FiiO's recovery reads `META-INF/com/android/metadata` and compares `pre-product` with `ro.product.name`. Our package had no metadata. We added `pre-device=maestro7872` and `pre-product=M11`, as FiiO's packages have. The second try worked. The backup (18 images, 2.3 GB) took about one minute. The MD5 of every file matched between player and computer.

The FiiO package was a 2022-11-28 rebuild of 1.1.1. The player ran the 2020-12-30 build. None of the boot images matched, so all later steps use the player's own backup, not FiiO's package.

## 4. The bootloader

Before we wrote anything, we read the bootloader (`mmcblk0boot0`) to find a way back. It is U-Boot with Samsung fastboot. It checks keys at power-on:

- **Next** + power: recovery
- **Previous** + power: fastboot
- **Play/pause** + power: engineering mode

It reads the full 10 MiB `ramdisk` partition and checks the uImage CRCs. So a larger ramdisk is fine, but its header must be valid.

## 5. Root

We patched the stock ramdisk with Magisk v30.7. We followed the steps in Magisk's own `boot_patch.sh` for a legacy ramdisk, and kept FiiO's uImage header with new CRCs. Magisk v31.1 was one week old and had just raised its minimum to Android 7.0, so we did not use it.

The kernel needed no change. It has none of the Samsung code that Magisk patches.

The root package writes the new ramdisk only if the partition holds exactly the stock image. It reads the partition again after the write. We tested it under `qemu` against a fake partition with 7 cases before we used it. We also built a restore package that writes the stock ramdisk back.

The root package worked. Android started in about 50 seconds with Magisk running.

Two problems came after:

- The Magisk app asked to "reflash" because our offline patch had no `PREINITDEVICE` in its config. The app's own reinstall looks for a `boot` partition, so we did not accept it. We asked Magisk for the value (`mmcblk0p3`), rebuilt the ramdisk with it, and wrote it from Android as root.
- The assistant tapped **Grant** on the first `su` prompt too late. Magisk saved a refusal for `adb`. We fixed it in Magisk's Superuser list.

## 6. Root certificates

We compared the player's store with AOSP's current store by SHA-256 fingerprint. 81 roots were missing, for example ISRG Root X1 and X2, GTS and Amazon. 80 roots were old or distrusted, for example WoSign, StartCom, CNNIC and Symantec.

First we only added the 81. The owner then asked to remove the old ones too. The final module replaces the whole directory with AOSP's files. If you remove single files, Android cannot find certificates that come after a gap in the numbering (`<hash>.0`, `.1`, ...).

We checked 28 real hosts with OpenSSL. Let's Encrypt hosts failed on the stock store and passed on the new one. Everything else passed on both.

Testing on the player was hard:

- Chrome 119 has its own root store, so it loaded Let's Encrypt sites before the fix.
- The HTML Viewer's WebView never uses the network.
- The `adb` shell has no `INTERNET` permission on this build, and the download manager refuses root.

**Mistake:** one test called `content delete` on the download manager without a filter. This removed every download record. It also removed one file that the owner saved earlier (an app installer). The tools in this repository do not use the download manager.

## 7. Spotify and Apple Music

The Play Store still updates Spotify on Android 7.0. It installs the parts that match the M11 (`arm64-v8a`, `xhdpi`), so sideloading is not necessary.

Apple Music opened with "Only Available on Unrooted Devices". Its check looks for `test-keys` in `Build.TAGS` and for three fixed `su` paths. FiiO's firmware has `test-keys` even without root, so the check fails on every M11. A Magisk boot script now sets `ro.build.tags=release-keys` before Android starts.

The owner said that Apple Music sign-in had never worked on this player. That matched our test: the app went back to the sign-in screen after the password.

## 8. Sign-in: an empty serial number

The app logged almost nothing. With a full log capture and a record of its TCP connections, we saw:

```
ServerException: {"status":"verificationFailure"}
```

This came from `sf-api-token-service.itunes.apple.com` when the sign-in screen opened, before the app sent any password. So Apple rejected the **device**, not the account.

In the app's FairPlay settings we found `guidSerialKey = 00000000000000`. FiiO's firmware leaves `ro.serialno` empty, so Android reports the serial number as `unknown`. Apple's code turned that into a device ID of all zeros. Probably every M11 looks like the same device to Apple.

The boot script now also sets `ro.serialno` from the Exynos chip ID (`/sys/devices/system/chip-id/unique_id`). This is the same value that `adb` already uses as the USB serial. We cleared Apple Music's data, and it made a new, unique device ID. Sign-in worked on the next try.

## 9. No sound: a bug in FiiO's libmedia.so

Apple Music then showed "playing", but there was no sound. FairPlay worked: Apple's key server sent the content keys, and the AAC decoder started. The M11 has no Widevine, but Apple Music did not need it.

The audio server had **0 tracks**. At app start, it refused a tiny track:

```
AudioTrack set(): streamType -1, sampleRate 4000, ... frameCount 1, ... transferType 4
AudioFlinger: createTrack_l() initCheck failed -12; no control block?
```

This is ExoPlayer's "keep session id" track: 4000 Hz, mono, a 2-byte static buffer. When it fails, Apple Music never opens its real output.

We disassembled FiiO's libraries:

- The audio server writes SafetyNet event `38340117` before each failure. This is an AOSP security check: a static track's buffer must hold `frameCount × frameSize` bytes.
- The audio server computes the frame size correctly (2 bytes) and does not change the frame count of static tracks.
- FiiO's client library (`/system/lib64/libmedia.so`, `AudioTrack::createTrack_l`) sets the frame count of **every** track to `min(latency_ms × sampleRate / 1000, 8192)`. That includes static tracks. So the library announces the 2-byte buffer as many frames, and the security check rejects it.

The fix restores AOSP's `frameCount = size / frameSize` on the static path only. It changes 15 instructions. A second reviewer, with no other context, checked the patch against the disassembly. The reviewer found no errors and made two notes. Large static buffers now play in full, which is the AOSP behaviour. The patch does not cover 32-bit apps.

We installed it as a Magisk module. At boot, Magisk mounts the patched file over the original. The system partition does not change. Android started normally. FiiO Music still played at the file's own sample rate. Apple Music played through the AK4493 at 48 kHz.

## 10. What we learned

- The M11's recovery trusts the public AOSP test key. Many fixes are possible without unlocking the bootloader.
- Two of the Apple Music problems were FiiO firmware problems, not Apple problems: `test-keys` and the empty serial number.
- The silent playback was a bug in FiiO's change to Android's audio client library. It can affect any app that uses a small static audio track.
