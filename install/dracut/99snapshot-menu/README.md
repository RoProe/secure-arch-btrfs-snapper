# 99snapshot-menu — dracut module

post-LUKS snapshot menu, shown in initramfs after LUKS unlock.

## Files

- **snapshot-menu.sh** — pre-mount hook: shows interactive boot/snapshot menu,
  writes `/run/rootflags-override` if a snapshot was chosen
- **module-setup.sh** — dracut module definition: declares dependencies, installs
  hooks, scripts and binaries into the initramfs
- **snapshot-rewrite.sh** — rewrites `sysroot.mount` at runtime to mount the
  selected snapshot subvolume instead of `@`
- **snapshot-rewrite.service** — runs `snapshot-rewrite.sh` before `sysroot.mount`,
  only active if `/run/rootflags-override` exists
