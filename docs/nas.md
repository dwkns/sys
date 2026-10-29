# The NAS — dwkns-nas

A Synology DS220j running DSM 7.1, on the tailnet as `dwkns-nas` and on the
home network as `dwkns-nas.local` (192.168.5.45). One 3.6 TB volume.

`sys nas` shows its state at a glance; `sys nas open` opens its web page.

It cannot run `sys` — there is no git on DSM — so it is listed in
`config/ssh/no-sys` and every Mac that syncs writes its `authorized_keys` over
SSH instead. See section 4 of [AGENTS.md](../AGENTS.md).

## Accounts

- **dwkns** — the only account used. In the `administrators` group, so `sudo`
  works with its DSM password.
- **admin** — the built-in account, **disabled** (Control Panel ▸ User & Group
  ▸ Disallow this account). Nothing ran as it; its share and home were empty.

**One account, one password.** DSM, SMB and `sudo` all use the same stored
password. SSH is the exception: it uses a key, which is why you can log in
without knowing the password and then have `sudo` refuse you. To check a
password without changing anything:

```bash
ssh -t nas 'sudo -v && echo CORRECT'
```

Reset it in Control Panel ▸ User & Group ▸ dwkns ▸ Edit.

## Shares

| Share | For |
|---|---|
| `dwkns-nas` | general files — the one `sys net` mounts |
| `dwkns-timemachine` | Time Machine only; Time Machine mounts it itself |
| `admin-nas` | empty, and unreachable now admin is disabled |
| `homes` | DSM's per-user home directories |

## Time Machine

Destination: `smb://dwkns@dwkns-nas.local/dwkns-timemachine` — the **local
network** name, deliberately, not the Tailscale one. Backing up over the
tailnet worked until Tailscale stopped on the NAS, at which point backups
failed silently for a day. Backups only happen at home anyway.

Set it with `-p` so the password is prompted for rather than passed as an
argument, and so `backupd` (which runs as root) gets a credential it can use:

```bash
sudo tmutil setdestination -p smb://dwkns@dwkns-nas.local/dwkns-timemachine
```

Without `-a` this **replaces** the whole destination list — including any local
disk. Check afterwards with `tmutil destinationinfo`.

### "Failed to mount destination"

Two causes seen so far, in order of likelihood:

1. **A stale `lock` inside the sparsebundle**, left by a power cut or a
   backup interrupted mid-flight. Delete it while nothing has the bundle
   mounted:

   ```bash
   ssh nas 'rm -f /volume1/dwkns-timemachine/dwkns-mbp-m5.sparsebundle/lock'   # the bundle keeps the Mac's old name
   ```

   **Leave `token` alone.** It carries material the encrypted bundle needs;
   removing it breaks access until it is put back.

2. **No credential for root.** A destination added through Finder or without
   `-p` may leave `backupd` unable to authenticate even though the share
   mounts fine for you by hand. Re-add it with the `-p` command above.

## Tailscale

Installed as a DSM package (Package Center ▸ Installed ▸ Tailscale), currently
1.102.4. It must be **Running** there or the NAS drops off the tailnet.

The failure worth remembering: the package reported "Running" while Tailscale
itself was stopped, with

```
State store failed to initialize … open /volume1/@appdata/Tailscale/tailscaled.state: permission denied
```

The daemon runs as the `tailscale` user, but the state files were still owned
by `root` from an older version that ran as root. Fixing ownership keeps the
machine's existing tailnet identity, so nothing has to be re-authorised:

```bash
ssh -t nas 'sudo chown -R tailscale:tailscale /volume1/@appdata/Tailscale && sudo synopkg restart Tailscale'
```

`synopkg start` also sets the package to start at boot; `synopkg resume` does
not.

## Moving files onto it

- **rsync over SSH needs DSM's rsync service** (File Services ▸ rsync ▸ Enable).
  Without it DSM answers "Permission denied, please try again" — which looks
  exactly like an SSH login failure and is not one. Enabled now.
- **Copying from a Mac over SMB leaves `._` AppleDouble files** beside every
  file and folder; copying over SSH does not.
- **The USB drive (`dwkns-media`) is exFAT**: no owners or modes (`chmod` is
  silently ignored), and names cannot contain `: * ? " < > | \`. A name SMB
  cannot store — a trailing space, say — arrives as a private Unicode
  character, as the `Chernobyl (2019)` folder did.
- **Bulk copies belong on the NAS itself** (its disk to its USB port) or on a
  wired Mac — and check the USB link says SuperSpeed (`dmesg | grep usb` on the
  NAS, `system_profiler SPUSBHostDataType` on a Mac). Twice a cable or
  adapter silently ran at USB 2, a third of the speed.

## Keychain on the Macs

SMB passwords live in the login Keychain, one item per account **and per name
used to reach the NAS** — `dwkns-nas._smb._tcp.local` and
`dwkns-nas.tail75564c.ts.net` are separate items. Reaching the same NAS by
a new name means one more prompt, once. Time Machine's own credential lives in
the System keychain, and the backup's encryption key in the iCloud keychain:
**never delete that one**, or existing backups become unreadable.
