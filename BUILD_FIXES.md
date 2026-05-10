# K230 SDK Build Fixes for macOS (BPI-CanMV-K230D-Zero_defconfig)

All changes required to successfully build `sysimage-sdcard.img` on macOS using Docker + Colima.

---

## Environment

- **Host**: macOS (Apple Silicon)
- **Docker runtime**: Colima — `colima start --vm-type vz --vz-rosetta --arch aarch64 --memory 8 --cpu 4`
- **Docker image**: Ubuntu 22.04 (`linux/amd64` via Rosetta 2)
- **Build target**: `BPI-CanMV-K230D-Zero_defconfig`

---

## 1. Colima — Enable Rosetta 2

The toolchain is an x86_64 ELF cross-compiler (`riscv64-linux-musleabi_for_x86_64-pc-linux-gnu`).
Running it inside an `aarch64` Colima VM requires Rosetta 2 translation.

```bash
colima start --vm-type vz --vz-rosetta --arch aarch64 --memory 8 --cpu 4
```

Without `--vz-rosetta`, the toolchain binaries will fail with `exec format error`.

---

## 2. `Makefile` — Fix shell exit code propagation

**File**: `b1_files/k230_sdk/Makefile`

All `exit $?` inside `$(shell ...)` or recipe lines must be `exit $$?` (double-dollar escapes the `$` in Make).

**Also changed**:
- `mpp-apps` declared to depend on `mpp-kernel` (prevents parallel race).
- `rt-smart-kernel` declared to depend on `rt-smart-apps` (romfs must be built first).
- `scons -j16` → `scons -j2` (prevents OOM on 8 GiB VM during rt-smart-kernel build).

---

## 3. `build_k230.sh` — Cap top-level parallelism

**File**: `b1_files/k230_sdk/build_k230.sh`

Change:
```bash
make CONF="$CONF" -j$(nproc)
```
To:
```bash
make CONF="$CONF" -j1
```

Running multiple top-level Make targets in parallel causes race conditions between `mpp-kernel`, `mpp-apps`, `rt-smart-apps`, and `rt-smart-kernel`.

---

## 4. LVGL CMake — Prevent OOM / compiler crash

### 4a. `sample/Makefile`

**File**: `b1_files/k230_sdk/src/big/mpp/userapps/sample/Makefile`

- `cmake --build ... -j$(nproc)` → `cmake --build ... -j1`
- Add `rm -f $(SAMPLE_LVGL_BUILD_DIR)/CMakeCache.txt` before the cmake configure step to prevent stale cache from a prior failed build.

### 4b. `sample_lvgl/CMakeLists.txt`

**File**: `b1_files/k230_sdk/src/big/mpp/userapps/sample/sample_lvgl/CMakeLists.txt`

Set debug build mode:
```cmake
set(CMAKE_BUILD_TYPE Debug)
set(CMAKE_C_FLAGS_DEBUG "-O0")
set(CMAKE_CXX_FLAGS_DEBUG "-O0")
```

`-O2`/`-O3` optimisation causes the RISC-V cross-compiler to OOM inside the 8 GiB VM when compiling LVGL's large translation units.

### 4c. `lvgl/env_support/cmake/custom.cmake`

**File**: `b1_files/k230_sdk/src/big/mpp/userapps/src/lvgl/env_support/cmake/custom.cmake`

Exclude vendor GPU backends and the ebike demo that pull in large source trees:
```cmake
set(LV_CONF_SKIP_VENDOR_GPU ON)
# ... (list of excluded backends)
set(LV_USE_DEMO_EBIKE OFF)
```

Add `-g0` to demo and example compile flags to avoid debug info bloat.

---

## 5. Sensor CMake — Single-threaded

**File**: `b1_files/k230_sdk/src/big/mpp/userapps/src/sensor/Makefile`

```makefile
cmake --build build -j1
```

(was `-j$(nproc)`)

---

## 6. Dockerfile — Add missing packages and Python deps

**File**: `b1_files/k230_sdk/Dockerfile.k230`

### 6a. apt packages added

| Package | Why |
|---|---|
| `scons` | rt-smart-kernel build system |
| `libconfuse2` | runtime dependency of the pre-compiled `genimage` binary |
| `dosfstools` | `mkdosfs` — genimage uses it to create the FAT32 `app.vfat` image |
| `mtools` | `mcopy` — genimage uses it to copy files into the FAT32 image |

### 6b. pip packages added

```dockerfile
pip3 install --no-cache-dir scons pycryptodome gmssl
```

- `pycryptodome` + `gmssl` — required by `tools/firmware_gen.py` (signs/hashes U-Boot binaries).
- `scons` via pip — ensures the correct Python-package version is available alongside the apt version.

---

## 7. `mcopy` wrapper — Fix mtools 4.0.32 bug

**File**: added as `RUN cat > /usr/local/bin/mcopy` in `Dockerfile.k230`

Ubuntu 22.04 ships mtools `4.0.33-1+really4.0.32-1build1`. In this version, passing any of the flags `-b`, `-p`, or `-s` together with `-i <image-file>` triggers:

```
Internal error, size too big / Streamcache allocation problem
```

genimage calls:
```
mcopy -bsp -i app.vfat /path/to/app '::'
```

The wrapper at `/usr/local/bin/mcopy` (takes PATH priority over `/usr/bin/mcopy`) strips the `-b`, `-p`, `-s` flags and handles directory recursion manually using `mmd` + per-file `mcopy` calls.

```bash
#!/bin/bash
REAL_MCOPY=/usr/bin/mcopy
# ... strips -b -p -s flags, recurses directories with mmd + mcopy per file
```

The fix was verified by running the exact genimage command against a 256 MB sparse FAT image and confirming all 49 files were copied successfully.

---

## Build order (all stages that must pass)

1. `mpp-kernel`
2. `mpp-apps` (depends on mpp-kernel; includes LVGL)
3. `rt-smart-apps` (scons)
4. `rt-smart-kernel` (scons -j2; depends on rt-smart-apps for romfs)
5. `big-core-opensbi`
6. `uboot` (u-boot.bin + u-boot-spl.bin)
7. `firmware_gen.py` (signs U-Boot; needs pycryptodome + gmssl)
8. `genimage` (mkdosfs + patched mcopy → `app.vfat` → `sysimage-sdcard.img`)

---

## Output

```
b1_files/k230_sdk_output/BPI-CanMV-K230D-Zero_defconfig/images/
├── sysimage-sdcard.img        (384 MB — flash to SD card)
├── sysimage-sdcard.img.gz     (30 MB  — compressed)
└── BPI-CanMV-K230D-Zero_sdcard__nncase_v2.10.0.img.gz -> sysimage-sdcard.img.gz
```

Flash to SD card:
```bash
# macOS
gunzip -c sysimage-sdcard.img.gz | sudo dd of=/dev/diskN bs=4m status=progress
```
