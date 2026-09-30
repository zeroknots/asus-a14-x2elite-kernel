# Linux for the ASUS Zenbook A14 (UX3407NA, Snapdragon X2 Elite)

A small, auditable patch set and kernel configuration for the ASUS Zenbook A14
**UX3407NA** (Qualcomm Snapdragon X2 Elite, SoC codename **Glymur**), kept as a
fork of Qualcomm's [`linux-msm/laptops-kernel`](https://github.com/linux-msm/laptops-kernel)
so upstream changes can be pulled in with an ordinary rebase.

> **Status: experimental.** These kernels are daily-driven by one person on one
> machine, installed as a *separate, non-default* boot entry next to a working
> distribution kernel. Keep a known-good kernel as your default.

## Branches

| Branch | Content |
| --- | --- |
| `asus-a14` (default) | Upstream base + the A14 patches below + `asus-a14/` build tooling |
| `topic/glymur-laptops` | Unmodified upstream branch this work is based on |

The exact base is recorded in [`asus-a14/UPSTREAM`](../asus-a14/UPSTREAM):
`linux-msm/laptops-kernel` branch `topic/glymur-laptops`, commit
`a981ab678811bc36107b124092daffb493f6dd29` (7.3-rc3 + next-20260917). Every
script refuses to run unless that commit is an ancestor of the checkout.

## Patches on top of upstream

```
git log --oneline a981ab678811..asus-a14 -- . ':!asus-a14' ':!.github'
```

- **QTEE kernel clients and service discovery** (posted upstream, v2, 5 patches,
  Amirreza Zarrabi) and the **Qualcomm TPM driver** (posted upstream, v2,
  3 patches). On this laptop the QTEE TPM service (`qcom.tz.tpm`) is *not*
  implemented by the firmware, so no TPM appears; the patches are carried for
  testing.
- **A14 device tree**:
  - camera wiring for the OV02C10 RGB and HM1092 IR sensors (experimental,
    both stream raw frames through libcamera);
  - USB/DP PHY supply references matching the working stock device tree;
  - the QCC2072 UART Bluetooth controller on UART14.

## Releases

Each release is a fully resolved config in
[`asus-a14/configs/releases/`](../asus-a14/configs/releases/); the numbered
[fragments](../asus-a14/configs/fragments/) document how each was derived.

| Release | Adds |
| --- | --- |
| `zenbook-hw1` | Camera, QTEE/TPM, FastRPC (NPU), DMA-buf system heap (its zram request was silently dropped, which is why the scripts now fail on dropped options) |
| `zenbook-hw2` | zram, nftables, policy routing, Bluetooth profiles, ASUS HID (the QCC2072 Bluetooth node is a DTS patch) |
| `zenbook-hw3` | xtables/iptables (Docker iptables backend, UFW, Tailscale), container networking, CFS bandwidth and other cgroup controllers, `uinput` |

`git diff zenbook-hw2 zenbook-hw3 -- asus-a14/configs/releases` is the honest
answer to "what changed?". [`required-options.txt`](../asus-a14/required-options.txt)
and [`required-modules.txt`](../asus-a14/required-modules.txt) list what every
release must keep; the scripts fail if an option is dropped.

### Known gaps (all releases)

Compared with a full distribution arm64 config, `UHID` (Bluetooth LE HID),
`HIDRAW` (FIDO2 keys), `EXFAT_FS`, `NTFS3_FS`, `USB_UAS`, `WIREGUARD`,
`CRYPTO_USER_API_*` (iwd) and `PSI` are still missing. Known hardware gaps: no
TPM (firmware service absent), no keyboard-backlight control, audio needs a
local UCM profile and a bind-race workaround.

## Building

Native arm64 (or set `CROSS_COMPILE=aarch64-linux-gnu-`). Outputs go to
`$A14_BUILD_ROOT` (default `../asus-a14-build`).

```bash
asus-a14/build.sh hw3              # config is verified before compiling
asus-a14/package.sh hw3            # modules, provenance.json, SHA256SUMS, checks
A14_CHECK_ONLY=1 asus-a14/build.sh hw3   # only verify the config
```

## Installing (Omarchy Snapdragon layout only)

```bash
sudo asus-a14/install.sh hw3
```

This targets an [Omarchy](https://omarchy.org) Snapdragon install (GRUB on the
ESP under `/boot/oma-snap`, versioned firmware under `/usr/lib/firmware/<release>`).
It adds `TEST: Zenbook A14 hw3` as a **non-default** GRUB entry, never changes
the default, never removes kernels, verifies every existing entry before and
after, and rebuilds DKMS modules. Firmware is **not** part of this repository:
it is copied from the running kernel's firmware namespace, which must already
contain the Glymur/UX3407NA firmware (ADSP/CDSP, GPU, QCC2072 Wi-Fi/Bluetooth).

The initramfs includes only Glymur firmware from `qcom/` (about 85 MB instead of
~280 MB) so several entries fit on a 2 GB ESP.

## Syncing upstream

```bash
git remote add upstream https://github.com/linux-msm/laptops-kernel.git
git fetch upstream topic/glymur-laptops
old=$(sed -n 's/^commit=//p' asus-a14/UPSTREAM)
git rebase --onto upstream/topic/glymur-laptops "$old" asus-a14
# record the new base, then derive and verify a new release config:
sed -i "s/^commit=.*/commit=$(git rev-parse upstream/topic/glymur-laptops)/" asus-a14/UPSTREAM
asus-a14/new-release.sh hw3 hw4 asus-a14/configs/fragments/60-hw4-....config
```

A new base changes Kconfig, so always cut a new release name rather than
reusing an old one. `qcom-laptops` (a newer sibling branch) currently lacks
the A14 device tree, the ASUS Glymur EC driver and the Glymur camera code, so
it is not a drop-in base.

## License

Kernel code is GPL-2.0 (see `COPYING`). The `asus-a14/` tooling is GPL-2.0 as
well. `asus-a14/docker-check-config.sh` is Moby's
[`contrib/check-config.sh`](https://github.com/moby/moby/blob/master/contrib/check-config.sh)
(Apache-2.0), vendored unchanged.
