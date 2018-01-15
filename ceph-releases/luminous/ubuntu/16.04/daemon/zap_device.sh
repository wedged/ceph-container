#!/bin/bash
set -e

function is_blockdevice {
  test -b "${1}"
  echo $?
}

function is_parentpartition {
  local result
  result=$(lsblk --nodeps -no PKNAME "${1}")
  if [ "$result" == "" ]; then
    echo 0
  else
    echo 1
  fi
}

function has_boot_label {
  local result
  result=$(lsblk --nodeps -no LABEL "${1}")
  if [ "$result" == "boot" ]; then
    echo 0
  else
    echo 1
  fi
}

function get_dmcrypt_uuid_part {
  # look for Ceph encrypted partitions
  # Get all dmcrypt for ${device}
  blkid -t TYPE="crypto_LUKS" "${1}"* -o value -s PARTUUID
}

function get_opened_dmcrypt {
  # Get actual opened dmcrypt for ${device}
  dmsetup ls --exec 'basename' --target crypt
}

function zap_dmcrypt_device {
  # $1: list of cryptoluks partitions (returned by get_dmcrypt_uuid_part)
  # $2: list of opened dm (returned by get_opened_dmcrypt)
  if [ $# -ne 2 ]; then echo "${FUNCNAME[0]}" function needs 2 args; exit 1; fi
  local dm_uuid
  for dm_uuid in $1; do
    for dm in $2; do if [ "${dm_uuid}" == "${dm}" ]; then cryptsetup luksClose /dev/mapper/"${dm_uuid}"; fi done
    dm_path="/dev/disk/by-partuuid/${dm_uuid}"
    dmsetup --verbose --force wipe_table "${dm_uuid}" || true
    dmsetup --verbose --force remove --retry "${dm_uuid}" || true
    # erase all keyslots (remove encryption key)
    payload_offset=$(cryptsetup luksDump "${dm_path}" | awk '/Payload offset:/ { print $3 }')
    phys_sector_size=$(blockdev --getpbsz "${dm_path}")
    # If the sector size isn't a number, let's default to 512
    if ! is_integer "${phys_sector_size}"; then phys_sector_size=512; fi
    # remove LUKS header
    dd if=/dev/zero of="${dm_path}" bs="${phys_sector_size}" count="${payload_offset}" oflag=direct
  done
}

function zap_device {
  local phys_sector_size
  local dm_path
  local ceph_dm
  local payload_offset

  if [[ -z ${OSD_DEVICE} ]]; then
    log "Please provide device(s) to zap!"
    log "ie: '-e OSD_DEVICE=/dev/sdb' or '-e OSD_DEVICE=/dev/sdb,/dev/sdc'"
    exit 1
  fi

  if [[ "${OSD_DEVICE}" == "all_ceph_disks" ]]; then
    for type in " data" " journal" " block" " block.wal" " block.db"; do
      for disk in $(blkid -t PARTLABEL="ceph$type" -o device | uniq); do
        dev="$dev ${disk%?}"
      done
    done
    # get a uniq list of devices to wipe
    disks=$(echo "$dev" | tr ' ' '\n' | nl | sort -u -k2 | sort -n | cut -f2-)
    ceph-disk zap "$disks"
  else
    if [ "$(is_blockdevice "${device}")" == 0 ]; then
      log "Provided device ${device} does not exist."
    fi
    # testing all the devices first so we just don't do anything if one device is wrong
    for device in $(comma_to_space "${OSD_DEVICE}"); do
      partitions=$(get_child_partitions "${device}")
      # if the disk passed is a raw device AND the boot system disk
      if [ "$(has_boot_label "${device}")" ==  0 ]; then
        log "Looks like ${device} has a boot partition,"
        log "if you want to delete specific partitions point to the partition instead of the raw device"
        log "Do not use your system disk!"
        exit 1
      fi
      ceph_dm=$(get_dmcrypt_uuid_part "${device}")
      opened_dm=$(get_opened_dmcrypt "${device}")
      # If dmcrypt partitions detected, loop over all uuid found and check whether they are still opened.
      if [[ -n $ceph_dm ]]; then
        zap_dmcrypt_device "$ceph_dm" "$opened_dm"
      fi
      log "Zapping the entire device ${device}"
      for p in $partitions; do dd if=/dev/zero of="${p}"bs=1 count=4096; done
      dd if=/dev/zero of="${device}" bs=1M count=10
      sgdisk --zap-all --clear --mbrtogpt -g -- "${device}"
      log "Executing partprobe on ${device}"
      partprobe "${device}"
      udevadm settle
    done
  fi
}
