# FiiO M11: root, current certificates, and working Apple Music

The FiiO M11 (2019, Exynos 7872, Android 7.0) is still a very good player. Its software has three problems:

1. Websites and apps that use Let's Encrypt certificates fail, because Android 7.0 does not have the current root certificates.
2. Apple Music does not sign in. It goes back to the sign-in screen every time.
3. When Apple Music does sign in, it plays no sound.

This repository fixes all three. It does not change FiiO's audio path for normal playback. We checked that FiiO Music still plays through the DAC at the file's own sample rate. We did not test the USB DAC mode or the balanced output.

The fixes are **Magisk modules**. You can remove each one, and you can remove Magisk itself. Nothing in this guide writes to the system partition.

How we found each problem is in [docs/HISTORY.md](docs/HISTORY.md). The technical details, with addresses and log lines, are in [docs/TECHNICAL.md](docs/TECHNICAL.md).

> **Warning.** This guide writes to your player's ramdisk partition. A mistake can stop Android from starting. The guide includes two ways to recover, but follow every step in order, and do the backup first. You do this at your own risk. It probably ends any warranty.

## What it does, in short

| Problem | Cause | Fix |
|---|---|---|
| No root | Locked-down user build | Magisk v30.7, put in the separate `ramdisk` partition by a signed recovery package |
| Let's Encrypt sites fail | Android 7.0 root store from 2017 | Magisk module that replaces the root store with AOSP's current one (149 roots) |
| Apple Music: "Only Available on Unrooted Devices" | FiiO signs its firmware with AOSP **test-keys** | Magisk module sets `ro.build.tags=release-keys` at boot |
| Apple Music sign-in fails | FiiO leaves the **serial number empty**. Apple sees the device ID `00000000000000` and rejects it | Same module sets the serial number from the Exynos chip ID |
| Apple Music plays no sound | Bug in FiiO's `libmedia.so`: it sends the wrong frame count for small static audio tracks, and the audio server rejects them | Magisk module with a 60-byte patch of your own copy of the library |

## Which players this is for

- **FiiO M11** (not M11 Pro, M11 Plus, M11S or M15) on firmware **1.1.1**.
- Tested on the 2020-12-30 build of 1.1.1. FiiO also published a 2022-11-28 rebuild of 1.1.1. Its `libmedia.so` files are byte-identical to the 2020 build, so the audio patch applies to both. The other steps use files from your own backup, so they do not depend on the build.
- Check your version: **Settings → About** must show 1.1.1. The audio patch script stops if your `libmedia.so` is different.

The M11 Pro and M15 use the same chip and similar firmware. We did not test them. The recovery check uses the product name, so at least `pre-product=M11` must change for them.

## What you need

- A computer with **Linux**, or Windows with **WSL** (Ubuntu). macOS can work for the `adb` steps, but the build steps expect Linux tools.
- These packages (Ubuntu names):

  ```bash
  sudo apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu python3 python3-cryptography openssl curl qemu-user-static cpio xz-utils
  ```

- **adb** (Android platform-tools) on the computer that has the USB cable to the player. On Windows you can use Git Bash for the `adb` steps.
- **Magisk v30.7**: download `Magisk-v30.7.apk` from the official release page, <https://github.com/topjohnwu/Magisk/releases/tag/v30.7>. Only download Magisk from GitHub.
- A USB-C cable and a charged player (more than 50 %).
- About 2.5 GB free in the player's internal storage for the backup.

Run all commands from the top folder of this repository.

## Step 0. Prepare the player

1. Go to **Settings → About**. Tap **Build number** 7 times.
2. Go to **Settings → Developer options**. Turn on **USB debugging**.
3. Connect the cable. Accept the prompt on the player.
4. On the computer, run:

   ```bash
   adb devices
   ```

   You must see one device with the word `device`.

## Step 1. Make a full backup (do not skip this)

This step only reads the eMMC. It copies every partition except `userdata` and `cache` to the player's internal storage. The `efs` partition holds data for your unit only. No firmware file contains it.

1. Get the AOSP test key. The M11's recovery accepts packages signed with this public key.

   ```bash
   bash tools/common/fetch-testkey.sh
   ```

2. Build the backup package:

   ```bash
   bash tools/backup/build.sh
   ```

3. Copy it to the player:

   ```bash
   adb push tools/backup/m11-backup.zip /sdcard/m11-backup.zip
   ```

4. On the player, open FiiO's updater. You can open it from **Technical Support → Firmware Update**, or with this command:

   ```bash
   adb shell am start -n com.android.fiioupdate/.activity.OtaUpdateActivity
   ```

   Select **Local upgrade → Built-in storage**. Tap `m11-backup.zip`. The player counts down for 10 seconds and restarts into recovery.
5. Wait. The backup takes about one minute. The player then starts Android again.
6. Copy the backup to the computer:

   ```bash
   adb pull /sdcard/m11-backup backup
   ```

7. Check that `backup/manifest.txt` shows `ok` on every line (18 lines).
8. Keep a second copy of the `backup` folder somewhere else, for example on a NAS. **Do not publish it.**

If recovery shows an error and stops on its menu, recovery wrote nothing. Press **power** once to restart (the menu selects "Reboot system now" first).

## Step 2. Root with Magisk

1. Build the Magisk ramdisk from **your** backup:

   ```bash
   bash tools/root/patch-ramdisk.sh backup/ramdisk.img path/to/Magisk-v30.7.apk
   ```

2. Build the root package and the restore package:

   ```bash
   bash tools/root/build.sh
   ```

3. Optional: test both packages on a fake partition (needs `qemu-user-static`). All 7 lines must show `PASS`.

   ```bash
   bash tools/root/test-flash.sh
   ```

4. Copy both packages to the player. Keep the restore package on the player. You need it if Android does not start.

   ```bash
   adb push tools/root/out/m11-root.zip /sdcard/
   adb push tools/root/out/m11-restore-ramdisk.zip /sdcard/
   ```

5. On the player, install `m11-root.zip` in the same way as the backup (FiiO's updater → **Local upgrade → Built-in storage**).
6. The root package writes the Magisk ramdisk only if the partition holds exactly the stock ramdisk from your backup. After the write, it reads the partition again and compares.
7. When Android starts, install the Magisk app:

   ```bash
   adb install path/to/Magisk-v30.7.apk
   ```

8. Open Magisk. If it says **"Requires additional setup … proceed and reboot?"**, tap **OK**. This copies Magisk's tools to `/data` and restarts.
9. **Never** use the **Install** button in the Magisk app on this player. The M11 has no `boot` partition, and the app's install method does not know about the separate `ramdisk` partition.
10. Give `adb` root. Run `adb shell su`. Magisk shows a prompt on the player. Tap **Grant** quickly. The prompt counts down, then closes itself and saves a refusal. If that happens, open Magisk → **Superuser** and turn on **[SharedUID] Shell**.

## Step 3. Current root certificates

1. Optional: save the stock store so you can compare later:

   ```bash
   adb pull /system/etc/security/cacerts tools/cacerts/device
   ```

2. Build the module from AOSP's current store:

   ```bash
   bash tools/cacerts/build-module.sh
   ```

3. Optional, only if you did step 1: check real servers against the stock store and the new store:

   ```bash
   bash tools/cacerts/check-chains.sh
   ```

   Let's Encrypt sites show `FAIL` for stock and `ok` for fixed. All hosts must show `ok` for fixed.

4. Install it and restart:

   ```bash
   bash tools/cacerts/install.sh
   adb reboot
   ```

5. Check: `adb shell ls /system/etc/security/cacerts | wc -l` shows 149.

This replaces the store completely. It adds 81 current roots (ISRG Root X1 and X2, GTS, Amazon, Microsoft and others). It also removes 80 old roots that Android no longer trusts, for example WoSign, StartCom, CNNIC and Symantec.

## Step 4. Apple Music: root check and sign-in

1. Install the module:

   ```bash
   bash tools/props/install.sh
   adb reboot
   ```

2. Check both values:

   ```bash
   adb shell getprop ro.build.tags
   adb shell getprop ro.serialno
   ```

   The first must show `release-keys`. The second must show 16 hex characters, the same as `adb get-serialno`.

3. Install **Apple Music** from the Play Store. The Play Store gives the M11 version 4.9.7.2. Newer versions need a newer Android.
4. If you opened Apple Music before this step, clear its data once. The app keeps the old all-zero device ID.

   ```bash
   adb shell pm clear com.apple.android.music
   ```

5. Open Apple Music and sign in.

## Step 5. Apple Music: sound

1. Copy your player's 64-bit `libmedia.so` to the computer:

   ```bash
   adb pull /system/lib64/libmedia.so tools/audio-fix/libmedia64.stock.so
   ```

2. Make the patched copy. The script stops if your file is not the one we analysed (SHA-256 `c7933a37…feceeefb`).

   ```bash
   bash tools/audio-fix/make-patch.sh tools/audio-fix/libmedia64.stock.so tools/audio-fix/libmedia64.patched.so
   ```

3. Optional: show every instruction that changed. You must see only 15 instructions, at `c05a8` to `c05e0`.

   ```bash
   bash tools/audio-fix/verify-patch.sh tools/audio-fix/libmedia64.stock.so tools/audio-fix/libmedia64.patched.so
   ```

4. Install the module and restart:

   ```bash
   bash tools/audio-fix/install.sh
   adb reboot
   ```

5. Check that the player started normally. Play a song in FiiO Music. Then play a song in Apple Music.

This changes the frame count only for **static** audio tracks (short sounds that an app gives to Android in one buffer). Music playback uses streaming tracks, and FiiO's code for those does not change. The patch is for 64-bit apps only. Apple Music is a 64-bit app.

## Spotify

Spotify still supports Android 7.0. Install and update it from the Play Store. The Play Store selects the parts of the app that match the M11 (`arm64-v8a` and `xhdpi`). If you install an APK by hand, use the **arm64-v8a** build with the **nodpi** or bundle variant.

## How to undo

| To remove | Do this |
|---|---|
| One module | Magisk app → **Modules** → remove it, then restart. Or: `adb shell su -c 'touch /data/adb/modules/<id>/remove'` and `adb reboot` |
| Magisk (root) | Install `m11-restore-ramdisk.zip` with FiiO's updater. This puts the stock ramdisk back and all modules stop loading. |

Module ids: `m11-cacerts`, `m11-props`, `m11-static-audiotrack`.

## If Android does not start

Hold one key while you press **power** to start the player:

| Key | Mode |
|---|---|
| **Next** | Recovery |
| **Previous** | Fastboot |
| **Play/pause** | Engineering mode |

- **Magisk safe mode:** Magisk loads no modules if it sees **volume down** while Android starts. The M11 has a gold volume wheel on its left side, not volume keys. The wheel sends `KEY_VOLUMEDOWN` events (input device `gpio_keys`), so turning it down during start should work. We did not test this.
- **Recovery:** start with **Next** + power. Select **Apply update from Internal Storage** and install `m11-restore-ramdisk.zip`. This removes Magisk and all modules.
- **Last resort:** start with **Previous** + power for fastboot, and write `backup/ramdisk.img` to the `ramdisk` partition. (We did not test fastboot.)

## What this does not fix

- **32-bit apps** still use the unpatched `/system/lib/libmedia.so`. A 32-bit app with a small static audio track still fails.
- **Widevine.** The M11 has no Widevine DRM. Apple Music does not need it, because it uses FairPlay. Some video apps need it.
- **Security patch level.** The firmware stays at the 2017-04-01 Android security patch level.
- **Newer Android.** The M11 is not Treble-compatible, and FiiO does not publish the source of its audio driver. We think a newer Android version is not realistic.

## Files

| Path | What it is |
|---|---|
| `tools/common/` | Test key download, and whole-file signing for recovery packages (`signapk -w` format) |
| `tools/backup/` | Recovery package that copies all partitions to internal storage. It only reads. |
| `tools/root/` | Magisk ramdisk patch, root package, restore package, and tests |
| `tools/cacerts/` | Root certificate module, and a tool that compares real server chains |
| `tools/props/` | `release-keys` tag and serial number module |
| `tools/audio-fix/` | `libmedia.so` patch for static audio tracks, and a diff tool |
| `tools/diag/` | Script that logs an app's TCP connections (used to find the sign-in problem) |
| `docs/HISTORY.md` | How we got here, in order |
| `docs/TECHNICAL.md` | Device facts, the recovery check, the Magisk patch, and the audio bug with addresses |

This repository has no FiiO firmware, no FiiO binaries, and no Magisk binaries. The scripts patch the files from your own player.
