# HackiOS for Xiaomi Redmi 10C (`fog`) — native iOS 16.5 userland on XNU

**Status: WORKING — SpringBoard reaches the iOS home screen on the phone.**

This release packages the HackiOS bring-up for the Xiaomi Redmi 10C
(codename `fog`, Qualcomm Snapdragon 680 / SM6225). It boots the XNU 8796.121.2 kernel
(built from the Redwood tree) together with the iOS 16.5 userland, and gets SpringBoard from the
BootUI Apple logo all the way to a rendered, interactive home screen. The launcher uploads
the boot images into RAM. The system also requires a `darwin` image in the phone's
`userdata`, which the guest can write to during a run.

| Evidence | File |
|---|---|
| Home screen (clean, no debug banner) | [`evidence/ios16_5_homescreen_fog.png`](evidence/ios16_5_homescreen_fog.png) |
| Home screen (with the `radar:` debug banner) | [`evidence/ios16_5_homescreen_fog_banner.png`](evidence/ios16_5_homescreen_fog_banner.png) |
| Frame counter / `darwin` write-back proof | [`evidence/springboard_evidence.txt`](evidence/springboard_evidence.txt) |
| Boot spinner (intermediate state) | [`evidence/boot_spinner_ku104.png`](evidence/boot_spinner_ku104.png) |

> **Note on `ku104.png`:** the file that used to live next to the kernel build is *not* the home
> screen — it is a black frame with a boot spinner. The actual home-screen evidence in this release
> was captured at the end of the working run (`xl screenshot`, cycle 14) and is stored as
> `evidence/ios16_5_homescreen_fog.png`.

---

## 1. What this is

- **Kernel:** XNU `8796.121.2`, built for `DEVELOPMENT_ARM64_BCM2837` in the Redwood tree.
- **Userland:** iOS 16.5 (build `20F66`, iPhone 10,3 sysimage), running natively on the phone.
- **Boot chain:** Android bootloader → UEFI (`xnu-usb-fog.img`) → `xnuloader` → resident
  `flashboot.apfs` in RAM (`/dev/md0`) → staged payload → `fastboot oem run`.
- **Display:** the phone's panel is driven by `MiniIOMobileFramebuffer`; frames are composited by
  CoreAnimation on top of the **Mesa OSMesa** software GL implementation (`adreno=0 gl=1`).
- **Storage:** the root is `root.apfs`; `/private/var` is an in-memory filesystem, optionally
  mirrored to the `darwin` volume by `var_store`.

The screen above is exactly what this release produces: app grid, dock, Search pill, working
compositor and a live frame clock (the log shows frames past **1220**).

---

## 2. Upstream repositories and commits

| Tree | Remote | Commit | Role |
|---|---|---|---|
| Userland / loader / `xl` | <https://github.com/oosexgang/hakios-xnu-kernel> | `a3384e031eb1e605cf37adaefc19991f04f6274b` | iOS userland, injected dylibs, build scripts |
| Kernel (Redwood) | <https://github.com/oosexgang/hackios-xnu-kernel> | `c2ddff4e591d628aa8e665a457db6c52c06c4654` | XNU 8796.121.2, IOKit drivers (framebuffer, GPU, UART, USB) |

The working trees these files were taken from:

- userland: `/home/feolov/Projects/hackios-fog-workspace/hakios-xnu-kernel`
- kernel: `/home/feolov/Projects/hackios-redwood/hackios-xnu-kernel`

The source diffs against those commits are in [`patches-and-src/userland.patch`](patches-and-src/userland.patch)
and [`patches-and-src/kernel.patch`](patches-and-src/kernel.patch). The release does not include
the changed binary preferences for `com.apple.migration.plist`, `com.apple.purplebuddy.plist`
and `com.apple.springboard.plist`. Source changes require a rebuild before they affect the prebuilt
images.

---

## 3. Contents

```
hackios-fog-release/
├── README.md
├── run.sh                        # boots the prebuilt images and collects logs
├── xnuloader/
│   └── loader.efi                # standalone EFI build, separate from the bundled boot image
├── prebuilt/
│   ├── mach.development.bcm2837  # XNU 8796.121.2 kernel, DEVELOPMENT_ARM64_BCM2837
│   ├── xnu-usb-fog.img           # UEFI + xnuloader loader image
│   ├── root.apfs                 # root filesystem (GL=1, RC_JOBS=rc.jobs.unlock, no REST=1)
│   ├── flashboot.apfs            # 976 MB resident image (/dev/md0), stays in RAM
│   ├── run-sb-unblock.bin        # staged payload: kernel + root.apfs + boot-args
│   ├── xl                        # fastboot driver (log / screenshot / state / ramdisk / ...)
│   └── SHA256SUMS
├── patches-and-src/
│   ├── userland.patch            # git diff of the userland tree
│   ├── kernel.patch              # git diff of the Redwood kernel tree
│   ├── inject.c                  # backboardd: window-server + panel + input hooks
│   ├── inject_sb.c               # SpringBoard: activation, XPC, NSXPC, stacks
│   ├── var_store.c               # /private/var mirroring (kern.hackios.* sysctls)
│   └── run-sb-unblock.sh         # original run script (absolute paths of the workspace)
└── evidence/
    ├── ios16_5_homescreen_fog.png
    ├── ios16_5_homescreen_fog_banner.png
    ├── boot_spinner_ku104.png
    └── springboard_evidence.txt
```

Artifact sizes (approx.): kernel 15 MB, UEFI 2.0 MB, `root.apfs` 6.3 MB, payload 21 MB,
`flashboot.apfs` 976 MB, `xl` 22 KB. Integrity hashes are in `prebuilt/SHA256SUMS`.

> Download [`flashboot.apfs` from v1.0](https://github.com/ddoass/hackios-fog-release/releases/download/v1.0-homescreen/flashboot.apfs)
> into `prebuilt/`. The file is about 976 MiB and is stored as a release asset.
> The [v1.1 release](https://github.com/ddoass/hackios-fog-release/releases/tag/v1.1-homescreen)
> provides the separate system image and describes the one-time `darwin` setup.

---

## 4. What was fixed to get this far

### 4.1 XPC deadlocks (SpringBoard main thread)

SpringBoard's launch was serialised on synchronous XPC calls to processless or silent peers.
`inject_sb.c` now interposes `xpc_connection_send_message_with_reply_sync`:

- **No peer (`pid <= 0`, anonymous connection):** an empty dictionary is returned immediately,
  the call never waits (198/200 such calls in an early run belonged here).
- **Live peer:** the call is executed on one of **four worker threads** with a bounded wait, so a
  slow call cannot hold every other caller behind it.
- **Timeout by peer name** (`sysctl KERN_PROC_PID` → `p_comm`):
  `backboardd`, `lsd`, `SpringBoard` → **90 s**; everything else → **2 s**.
- **`com.apple.lsd.mapdb`** (and callers from `Foundation+0x99314`) → **2 s**. `lsd` is alive but
  never answers while it rebuilds the LaunchServices database in the in-memory `/private/var`;
  five 90-second waits used to freeze the launch for 7.5 minutes.

### 4.2 `NSXPCConnection` calls that bypass interposing

References inside `dyld_shared_cache` are pre-bound and never pass `__DATA,__interpose`.
`-[NSXPCConnection _sendInvocation:orArguments:count:methodSignature:selector:withProxy:]` is
therefore replaced with `method_setImplementation`. Calls aimed at `iconservices` are answered
locally with a zeroed return value instead of blocking the main thread; every other call is passed
through untouched.

### 4.3 The display was being blanked

Right after `systemShellWillBootstrap`, backboardd used to run:

```
[Display] Set Blanked: YES
[Backlight] Setting CoreBrightness backlight factor:0.000000
```

A blanked window server draws nothing. `inject.c` scans `CAWindowServerDisplay`, `CAWindowServer`,
`BKDisplay`, `BKDisplayController`, `BLSBacklight`, `BLControl`, … hooks the exact selectors
`setBlanked:`, `_setBlanked:`, `setDisplayBlanked:` and ignores `YES` (passing `NO` through), and
floors `BLControl`'s backlight factor at `1.0`. The scan is retried every 500 ms because some
CoreBrightness classes are registered lazily.

### 4.4 `var_store.c` sysctl namespace

The userspace helper used `kern.hakios.var_*` while the kernel exposes `kern.hackios.var_*`.
The names were corrected, so `var_store watch` can drive `var_save` / `var_busy` again and the
`/private/var` mirror works (`ufs: 5 writes into darwin, 16781312 bytes, read back the same`).

### 4.5 Rendering

CoreAnimation draws through the EAGL/Mesa-OSMesa path (`adreno=0 gl=1`). The kernel-side
`MiniIOMobileFramebuffer` presents the resulting surface; the BootUI Apple logo and then
SpringBoard's own layers both reach the panel (frame counter **1220+** in the evidence log).

---

## 5. Running it on the Redmi 10C (`fog`)

### Requirements

- Linux host with `fastboot`, `bash`, `flock`, `timeout` and `python3` in `PATH`.
- One Redmi 10C (`fog`) with its bootloader unlocked. Starting from Android requires USB debugging and `adb`.
- `prebuilt/flashboot.apfs` on the host and the `darwin` image set up in the phone's `userdata`.
- ~2 GB of free RAM on the phone (the resident image and the payload live there).

### One command

```bash
cd hackios-fog-release
./run.sh                    # collect logs for 2400 s, every 120 s
SECS=600 ./run.sh           # collect logs for 600 s
SLICE=60 ./run.sh           # collect logs every 60 s
```

`run.sh` performs the whole cycle:

1. leaves the loader / reboots to the bootloader;
2. `fastboot boot prebuilt/xnu-usb-fog.img` (UEFI from RAM);
3. waits for the `xnuloader` fastboot product;
4. `prebuilt/xl ramdisk prebuilt/flashboot.apfs` (resident image, once per session);
5. `fastboot stage prebuilt/run-sb-unblock.bin`;
6. `fastboot oem run`;
7. collects the kernel log every `SLICE` seconds into `logs/run-sb-unblock.log`
   (or `OUT`), taking a screenshot every other slice.

`SECS` sets the observation window on the host. The prebuilt payload's kernel timer is fixed
at 2400 seconds, so ending observation earlier leaves the guest running.

### Watching it

```bash
prebuilt/xl state                       # loader / fastboot / android
prebuilt/xl screenshot logs/screen.png  # works during a run
tail -f logs/run-sb-unblock.log
```

Expected timeline of a healthy run (guest clock):

| Guest time | What happens |
|---|---|
| 00:02 | SpringBoard is spawned by launchd |
| 00:04:48 | BootUI Apple logo drawn by backboardd |
| 00:05:35 | `systemShellWillBootstrap` |
| 00:06–00:08 | display handshake with backboardd (tens of seconds on the software renderer) |
| 00:07+ | SpringBoard's first frames; the home screen appears and the frame counter runs |

### Manual equivalent

```bash
fastboot boot prebuilt/xnu-usb-fog.img
# wait until `prebuilt/xl state` prints loader
prebuilt/xl ramdisk prebuilt/flashboot.apfs
fastboot stage prebuilt/run-sb-unblock.bin
fastboot oem run
prebuilt/xl log
```

The payload already contains this boot-args line:

```
debug=0x8 root_apfs=ufs_darwin ufs=2 bootcpu=7 cpus=7 loader_return_after=2400
var_store=1 ufs_write=1 adreno=0 gl=1 sb_delay=10 graphics_console=0 fbscale=2
applog=1 darwin_file=1 darwin_blocks=3145728 console=fbcon -v
amfi_get_out_of_my_way=1 cs_enforcement_disable=1 sb_threads=120
```

Rebuilding the payload from a changed kernel or `root.apfs` needs the upstream source tree
(`xnuloader/mkpayload.py`) and the files in `patches-and-src/`.

---

## 6. Known limitations

- **Software rendering only.** `adreno=0 gl=1` (Mesa OSMesa) is what works today; the Adreno path
  is not usable yet. Consequently display calls to backboardd take 30–80 s and the whole boot is
  slow.
- **Placeholder icons.** App artwork is not delivered (`iconservicesagent` never answers); the grid
  shows white placeholder tiles and the wallpaper is black.
- **No lock screen.** SpringBoard goes straight to the home screen (activation/setup are bypassed
  on purpose). Showing the lock screen first is a separate change.
- **`/private/var` is a memory filesystem.** LaunchServices rebuilds its database on every boot,
  which is why `mapdb` never answers and is capped at 2 s. Enabling `restore_var` will make the next
  boots faster.
- **Touch.** Input currently comes from the virtual USB touch screen; I2C touch on `fog` is planned.
- **Storage.** The launcher stages its boot files in RAM. The `darwin` image and any guest
  writes to it live in the phone's `userdata`.

---

## 7. Source build notes

The upstream userland build uses `xnu-clang` and the iPhoneOS 16.5 SDK. The release was built
with `GL=1 RC_JOBS=rc.jobs.unlock` to enable the Mesa software renderer and select the
release job list. Enabling `REST=1` starts extra jobs and starves XPC.

The kernel image was built from the Redwood tree with the `DEVELOPMENT_ARM64_BCM2837`
configuration. Reproducing the bundled Fog UEFI image also requires the original device
build inputs, which are outside this release.

---

## 8. Кратко по-русски

Готовая сборка HackiOS для Xiaomi Redmi 10C (`fog`): нативный iOS 16.5 (20F66) на ядре XNU
8796.121.2 из Redwood. Скрипт загружает загрузочные образы в RAM через `fastboot`.
Отдельный образ `darwin` хранится в `userdata` телефона, и система может писать в него.

Что доведено до рабочего состояния:

- обход дедлоков синхронных XPC (`xpc_connection_send_message_with_reply_sync`): пустой ответ без
  ожидания при отсутствии пира, 4 воркера, таймауты по имени процесса (90 с — `backboardd`/`lsd`,
  2 с — остальные, отдельно 2 с для `com.apple.lsd.mapdb`);
- перехват `-[NSXPCConnection _sendInvocation:...]` для вызовов из `dyld_shared_cache`
  (`IconServices`);
- блокировка гашения экрана: `CAWindowServerDisplay setBlanked: YES` игнорируется, подсветка не
  опускается ниже 1.0;
- исправлены sysctl-имена в `var_store.c` (`kern.hackios.*`);
- рендер через Mesa OSMesa (`adreno=0 gl=1`), счётчик кадров > 1220.

Запуск: `cd hackios-fog-release && ./run.sh`. Переменные `SECS` и `SLICE` задают
время наблюдения и интервал сбора логов. Скриншот
рабочего стола — `evidence/ios16_5_homescreen_fog.png`. Ограничения: программный рендер, иконки
без картинок, нет экрана блокировки, `/private/var` в памяти, тач — виртуальный USB.
