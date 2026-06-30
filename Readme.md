# tamborgmatic (borgmatic config)

This is what I use to backup my computers and servers. Unlike the traditional Borg model, here the server is more trusted than clients. The goal is to [achieve enlightenment](http://www.taobackup.com) and survive Ransomware.

- [Running](#running)
- [Mounting archives](#mounting-archives)
- [Restoring partitions](#restoring-partitions)
- [Setup](#setup)
- [Troubleshooting](#troubleshooting)
- [Tips](#tips)



## Running

```sh
/etc/borgmatic/run_create.py
```
```sh
borgmatic ...
```



## Mounting archives

1. Create a target directory:
    ```sh
    sudo mkdir -p /mnt/borg
    sudo chown $USER:$USER /mnt/borg
    ```
2. Find the archive to mount, for example with:
    ```sh
    borgmatic repo-list --last 5 -a "TAM_2009-*"
    ```
3. Mount it with:
    ```sh
    borgmatic mount --options=allow_root,uid=$UID,umask=007 --mount-point=/mnt/borg --archive=<archive_name>
    ```
4. When you are done, unmount it with:
    ```sh
    umount /mnt/borg
    ```

### Mounting partition images

<sub><sup>GUI instructions as you probably want to recover individual files while you still have a usable Linux with Desktop Environment</sup></sub>

1. With the File Manager (Nemo), navigate to `/mnt/borg`
2. Right-click the image file and click _Open With Disk Image Mounter_
3. Open _Disks_ (`gnome-disks`)
4. Click the loop device in the left pane, and then click the Play button to mount.
5. When you are done, unmount with the Stop button, and detach the loop device with the `⏏` button in the title bar (next to the Minimize button).



## Restoring partitions

<sub><sup>CLI instructions as in an emergency this may have to be run from the usually-headless Borg server!</sup></sub>

This section is mostly manual work because it shouldn't be used often, overwriting `/dev/sdX` is a delicate operation, and the case of multiple hard drives/partitions is complex.

Double-check the device you are about to write to!

1. Prepare:
    ```sh
    # Mount the archive (see previous section)
    borgmatic mount ...
    cd /mnt/borg

    # Take a reference of the archive content
    # (This is needed because `borg extract` fails while the archive is mounted, because the repo lock is held)
    rm -rf /tmp/borg_reference
    mkdir /tmp/borg_reference
    cd /tmp/borg_reference
    find /mnt/borg -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | xargs mkdir
    find /mnt/borg -mindepth 1 -maxdepth 1 -type f -printf "%f\n" | xargs touch
    cp -r /mnt/borg/structure .
    # Print sizes output now to reference it later:
    (cd /mnt/borg && stat --format="%n %s" *.raw.img)
    umount /mnt/borg

    # Add helper scripts to PATH:
    export PATH="/etc/borgmatic/restore:$PATH"
    ```

2. Run `2-backed_up_disk_structure.sh` to visualize data from `part_*.txt` and `sd?_header.bin` (how devices were at backup time).

    Use `sudo parted -l` to figure out about current target restore disks.

3. For each disk, restore its header (includes partition table) with:
    ```sh
    <structure/sdA_header.bin sudo tee /dev/sdX >/dev/null
    ```

    After restoring for all disks, run:
    ```sh
    sudo partprobe
    ```

    and check restored disks with `sudo gdisk /dev/sdX`:

    > MBR:
    > ```
    > Partition table scan:
    >   MBR: MBR only
    >   GPT: not present
    > ```
    > GPT:
    > ```
    > Partition table scan:
    >   MBR: protective
    >   GPT: damaged
    > ```

    If the disk was GPT restore its backup partition table with `w`, else quit with `q`.

    <details>
    <summary>To restore to smaller GPT disk</summary>
    Assuming that the last partition is the Linux root, and only that one will be shrinked:

    1. `sudo gdisk /dev/sdX`
    2. Make write fail with `w`:
        ```
        Problem: partition 3 is too big for the disk.
        Aborting write operation!
        Aborting write of new partition table.
        ```
        This is actually required, as it changes the default _Last sector_ in step 5.
    3. Print partition table with `p`
    4. Delete last partition with `d`
    5. Recreate the partition with `n`. Accept all defaults.
    6. Write and exit with `w`.
    </details>

4.  Restore raw images
    ```sh
    # Refer to the previous run of `stat` in step 1 to get sizes

    4-extract-file-pv.sh <archive name> PART.raw.img <size> | sudo tee /dev/sdXY >/dev/null
    ```

    > Note: use `borg extract` instead of ./PART.raw.img, because reading from the mounted filesystem is slow.

    > However if the partitions are NTFS, and not too full, and you don't care that empty space is not wiped with zeros, it may be faster to write only used data, even if reading from `./` is slower:
    > ```sh
    > ntfsclone --save-image --output - PART.raw.img |
    >   sudo ntfsclone --restore-image --overwrite /dev/sdXY -
    > ```
    >
    > Unfortunately `borg extract` can't be used with `--restore-image`, because the image is raw and not special-image (so it can be mounted), and _Only special images can be read from standard input_.

5.  Restore Linux LVM partitions: (example for root)

    - Format and mount:
        ```sh
        sudo vgcreate machine_name /dev/sdXY
        # Exact name in structure/lvdev_linux_root.txt

        # Get available space in VG in GiB:
        sudo vgs --noheadings -o vg_size /dev/machine_name

        # Remember to leave some space in VG for snapshots:
        sudo lvcreate --size 100G --name root machine_name

        sudo mkfs.ext4 -U "$(cat structure/serial_linux_root.txt)" /dev/machine_name/root
        sudo mkdir /mnt/borg_linux_target
        sudo mount /dev/machine_name/root /mnt/borg_linux_target
        ```

    - Extract:
        ```sh
        pushd /mnt/borg_linux_target

        sudo SSH_AUTH_SOCK="$SSH_AUTH_SOCK" borgmatic borg extract \
          --progress --numeric-ids --sparse --strip-components=1 \
          ::<archive name> linux_root/
        ```

    - Restore stuff:
        ```sh
        sudo su

        (umask 022; mkdir var/cache/apt)
        # No need to mess with `tmp` and `var/tmp` as they are automatically created.

        for s in etc/borgmatic/restore/machine_specific/*.generated.sh; do "$s"; done
        exit
        ```

    - List CACHEDIR.TAG files for reference:
        ```sh
        find . -name "CACHEDIR.TAG" -exec sh -c \
          '[ "$(head -c 43 "$1" 2>/dev/null)" = "Signature: 8a477f597d28d172789f06886806bc55" ] && echo "$1"' \
          _ {} \;
        ```

    - Finalize:
        ```sh
        popd
        sudo umount /mnt/borg_linux_target
        ```

6. Restore data:
    - Boot into restored Linux to have GUI
    - Format partition with its previous filesystem
    - Restore its serial from `structure/serial_xxxx.txt`:
      - NTFS: `sudo ntfslabel --new-serial=<serial> /dev/sdXY`
      - exFAT: `sudo tune.exfat -I <serial> /dev/sdXY`
    - Mount
    - Open a terminal at mount point and run:
        ```sh
        borgmatic extract --progress --strip-components=1 --archive=<archive name> --path=PART/
        ```
        This assumes backup uid matches restore uid.
    - See "List CACHEDIR.TAG files for reference" in previous step.
    - For NTFS, hardlinks are successfully restored, but symlinks and junctions are not being correctly restored from Linux at this time. Workaround:
      - Mount the archive
      - ```
        6-ntfs-symlinks.sh <folder_junctions|folder_symlinks> /mnt/borg/NTFS_PART /media/user/NTFS_PART

        cd /media/user/NTFS_PART
        <_tamborgmatic/rm.0 xargs -0 rm -v
        ```
      - Reboot to Windows, and from there run `X:\_tamborgmatic\ln.bat`.
      - Review `missing.csv` if present. Cross-partition links will be here and are not automatically handled: recreate them manually.
      - Delete `_tamborgmatic` folder.
    - If you then realize that some important NTFS metadata is missing, you may try recovering it by converting the `.metadata.nc.img` to VHD with https://github.com/yirkha/ntfsclone2vhd/#metadata-only-images, and mounting it in Windows.


## Setup

0. Requirements:
    - Debian / Linux Mint / Ubuntu 20.04+ / antiX Linux, **installed on LVM:**
      ```sh
      sudo pvcreate /dev/sdXY
      sudo vgcreate machine_name /dev/sdXY
      # Get available space in VG in GiB:
      sudo vgs
      # Remember to leave some space in VG for snapshots:
      sudo lvcreate --size 100G --name root machine_name
      ```
    - Encrypted filesystems are currently unsupported
    - sudo [NOPASSWD](https://xkcd.com/1200/)

1. Create projects "Borg" and "HDD Smart" at [healthchecks.io](https://healthchecks.io).

1. Clone this:
    ```sh
    sudo apt install git

    sudo SSH_AUTH_SOCK="$SSH_AUTH_SOCK" GIT_SSH_COMMAND="sudo -u $USER ssh" git clone git@github.com:zzdroide/tamborgmatic.git /etc/borgmatic
    # For machine with no write access: sudo git clone https://github.com/zzdroide/tamborgmatic /etc/borgmatic
    sudo chown -R $USER:$USER /etc/borgmatic  # For ease of usage, and because of root/non-root invocations
    ```

1.
    ```sh
    (umask 077 && cp -r /etc/borgmatic/{config_example,config})
    cd /etc/borgmatic/config/
    ```
    And configure:

    - `constants.yaml`: see comments.

    - `bupsrcs.cfg`: &lt;type> &lt;name> &lt;path>

      Where &lt;type> is:
      - `linux` for a Linux root or data partition, that can remain mounted while backing up. Must be a LV and have free space in the VG for a snapshot.
      - `part` to backup the raw partition (for example Ext4 /boot, or Windows' NTFS partition)
      - `data` to backup file data only (exFAT-style)

    - `smarthealthc.cfg`: &lt;hc_url> &lt;dev>

      One line for every mechanical HDD worth preventative replacement.

    > Note: *.cfg files can have comments by starting lines with `#`

1.
    ```sh
    /etc/borgmatic/scripts/setup.sh
    ```

1. (Optional) If you want automatic backups triggered by the server:

    - Install and enable openssh-server. It's recommended to configure `PasswordAuthentication no`
    - ```sh
      scripts/install_tamborgmatic_auto.sh
      ```
    - Add the following line to `~/.ssh/authorized_keys`
      ```
      command="sudo systemctl start tamborgmatic-auto.service",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... tamborgcont
      ```


1. Configure `server_user` on server, and run `./update_authorized_keys.sh` there.


### Forget old host keys when server is reinstalled
```sh
ssh-keygen -f ~/.ssh/known_hosts -R 10.0.0.20
ssh-keygen -f ~/.ssh/known_hosts -R "[10.0.0.20]:1701"
/etc/borgmatic/scripts/setup.sh keyscan_server
grep tamborgmatic-auto.service ~/.ssh/authorized_keys && nano ~/.ssh/authorized_keys
```

### Development setup

```sh
poetry env use python3.13
poetry sync
eval $(poetry env activate)
pre-commit install
```



## Troubleshooting

### Borgmatic fails with `borg.remote.ConnectionClosed: Connection closed by remote host`

This is most likely the ssh hook rejecting the connection. Confirm this by running again but adding `-v2`. Now the output will contain: _Got unexpected RPC data format from server: Repo is NOT OK_

### Watching tamborgmatic-auto.service logs
```sh
sudo journalctl -eu tamborgmatic-auto.service
```

### Windows can't mount NTFS partition

If the restored partition can't be mounted (Disk Manager shows it as healthy, but most options are greyed out, and `DISKPART> list volume` doesn't show it), check the partition type with `sudo fdisk -l /dev/sdX`.

|   | MBR             | GPT                  |
| - | --------------- | -------------------- |
| ✓ | HPFS/NTFS/exFAT | Microsoft basic data |
| ✗ | Linux           | Linux filesystem     |

If for some unknown reason the partition type is not correct (happened to me once), change it with `sudo fdisk /dev/sdX`, command `t`.

### NTFS boots to blinking cursor (after resizing/moving/messing with partitions)

<details>
<summary>Explanation</summary>
Windows booting can be quite fragile, specifically Windows XP on MBR.

The NTFS bootsector has some legacy Cylinder/Head/Sector shit configured into it, and if it's wrong it just boots into a blinking cursor. This is vaguely documented in
[ntfsclone](https://man.archlinux.org/man/ntfsclone.8#Windows_Cloning)
and [partclone.ntfsfixboot](https://man.archlinux.org/man/partclone.ntfsfixboot.8)
(at least its source code [links](https://thestarman.pcministry.com/asm/mbr/NTFSBR.htm) to way too much detail).

- `jaclaz` explains
    [here](https://reboot.pro/index.php?showtopic=8233#post_id_70088)
    ([local copy](readme_data/xpboot/jaclaz.html#post_id_70088))
    where the problem is (note that he made a typo and wrote 0x0A,0x0C instead of 0x1A,0x1C),

- but I couldn't fix it with Testdisk
    [1](https://web.archive.org/web/20131005134310/http://www.xtralogic.com/support.shtml#faq_vhdu_disk_read_error)
    [2](https://web.archive.org/web/20131226114035/http://www.xtralogic.com/testdisk_rebuild_bootsector.shtml)
    (local
    [1](readme_data/xpboot/testdisk1.shtml#faq_vhdu_disk_read_error)
    [2](readme_data/xpboot/testdisk2.shtml)),

- nor by booting the XP disk, going into the recovery console, and running `fixmbr`, `fixboot`, `bootcfg /rebuild`,

- nor by booting the affected computer with BartPE, and running Bootice there.

- Rescuezilla explains
[why these attempts fail](https://github.com/rescuezilla/rescuezilla/blob/2.4.2/src/apps/rescuezilla/rescuezilla/usr/lib/python3/dist-packages/rescuezilla/parser/chs_utilities.py).
However I haven't tried this EDD method, just because I hadn't found it at the time.

What did work for me, was to let Windows setup generate the correct numbers, and plug them into my unbootable NTFS:

1. Backup the entire disk containing the unbootable NTFS (recommended), or just the unbootable NTFS partition and the first 512 bytes of the disk (MBR).

2. Begin to install a new Windows into this affected disk. Do not let the installer delete/create/resize partitions, just format the unbootable NTFS partition and install there.

3. When the installer reboots to continue by booting from disk instead of from installation media, confirm that it actually boots and stop it.

4. Backup the first 512 bytes of the now bootable NTFS partition (PBR), and then overwrite this now bootable partition with the unbootable one.

5. Compare the PBRs of the partitions, and change the relevant bytes (0x18-0x1F) in the unbootable one. Serial number for example (0x48-0x4F) is irrelevant, and MFT clusters (0x30-0x3F) should not be changed.

    ![screenshot](readme_data/xpboot/pbr_mod.png)

6. Overwrite the recently written Windows MBR on disk with the previous backed up MBR, to restore booting to GRUB.
</details>

#### Summary
```sh
# In Ubuntu, in same computer as non-working NTFS boot, which is for example /dev/sdXY:
sudo apt install -y lz4
cd somewhere_with_lots_of_free_space
sudo dd if=/dev/sdX of=mbr.bin count=1
sudo ntfsclone --save-image --output - /dev/sdXY | lz4 - unbootable_ntfs.simg.lz4

# Then insert Windows XP setup CD and boot it. Remember to press F6 and have floppy disk if required.
# Refuse to repair existing installation, and press lots of keys to install new Windows and just format (quick) the affected partition, without deleting the partition itself or altering anything else.
# After formatting, when setup is copying files, forcefully reboot the computer 🔥

# Now boot a live Ubuntu iso, as the MBR will be screwed and nothing will boot. (Advanced alternative: use the iso's GRUB to boot the installed Ubuntu in hard drive instead)
sudo apt install -y lz4
cd the_previous_folder
sudo dd if=/dev/sdXY bs=8 skip=3 count=1 of=magic_numbers.bin
lz4 -dc unbootable_ntfs.simg.lz4 | sudo ntfsclone --restore-image --overwrite /dev/sdXY -
sudo dd if=magic_numbers.bin of=/dev/sdXY bs=8 seek=3
sudo dd if=mbr.bin of=/dev/sdX
# Reboot and in GRUB choose Windows 😈
```

### There's a ghost/zombie/leftover/nonexistant `/dev/machine_name/root`
```sh
sudo dmsetup remove /dev/machine_name/root
```



## Tips

### Veracrypt containers

By default Veracrypt doesn't change the modified date of container files. So they are always skipped after the first backup, unless the files cache is purged.

You can disable _Preserve modification timestamp of file containers_ in [_Preferences_](https://github.com/veracrypt/VeraCrypt/issues/209#issuecomment-329992402).
