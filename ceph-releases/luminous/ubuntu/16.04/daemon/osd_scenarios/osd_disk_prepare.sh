#!/bin/bash
set -e

function osd_disk_prepare {
  if [[ -z "${OSD_DEVICE}" ]];then
    log "ERROR- You must provide a device to build your OSD ie: /dev/sdb"
    exit 1
  fi

  if [[ ! -e "${OSD_DEVICE}" ]]; then
    log "ERROR- The device pointed by OSD_DEVICE ($OSD_DEVICE) doesn't exist !"
    exit 1
  fi

  if [ ! -e "$OSD_BOOTSTRAP_KEYRING" ]; then
    log "ERROR- $OSD_BOOTSTRAP_KEYRING must exist. You can extract it from your current monitor by running 'ceph auth get client.bootstrap-osd -o $OSD_BOOTSTRAP_KEYRING'"
    exit 1
  fi

  ceph_health client.bootstrap-osd "$OSD_BOOTSTRAP_KEYRING"

  # then search for some ceph metadata on the disk
  if parted --script "${OSD_DEVICE}" print | grep -qE '^ 1.*ceph data'; then
    log "INFO: It looks like ${OSD_DEVICE} is an OSD"
    log "You can use the zap_device scenario on the appropriate device to zap it"
    log "Moving on, trying to activate the OSD now."
    return
  fi

  CEPH_PREPARE_BINARY=(ceph-volume)
  IFS=" " read -r -a CEPH_PREPARE_BINARY_CLI_OPTS <<< "${CLI_OPTS[*]}"
  if [[ ${OSD_DMCRYPT} -eq 1 ]]; then
    CEPH_PREPARE_BINARY_CLI_OPTS+=(--dmcrypt)
    CEPH_PREPARE_BINARY=(ceph-disk -v)
  fi
  if [[ ${OSD_BLUESTORE} -eq 1 ]]; then
    CEPH_PREPARE_BINARY_CLI_OPTS+=(--bluestore)
    "${CEPH_PREPARE_BINARY[@]}" prepare "${CEPH_DISK_CLI_OPTS[@]}" \
    --block.wal "${OSD_BLUESTORE_BLOCK_WAL}" \
    --block.db "${OSD_BLUESTORE_BLOCK_DB}" \
    "${OSD_DEVICE}"
  elif [[ "${OSD_FILESTORE}" -eq 1 ]]; then
    CEPH_PREPARE_BINARY_CLI_OPTS+=(--filestore)
    if [[ -n "${OSD_JOURNAL}" ]]; then
      "${CEPH_PREPARE_BINARY[@]}" prepare "${CEPH_PREPARE_BINARY_CLI_OPTS[@]}" "${OSD_DEVICE}" "${OSD_JOURNAL}"
    else
      "${CEPH_PREPARE_BINARY[@]}" prepare "${CEPH_PREPARE_BINARY_CLI_OPTS[@]}" "${OSD_DEVICE}"
    fi
  fi

  if [[ ${OSD_DMCRYPT} -eq 1 ]]; then
    # unmount lockbox partition when using dmcrypt
    umount_lockbox

    # close dmcrypt device
    # shellcheck disable=SC2034
    DATA_UUID=$(get_part_uuid "$(dev_part "${OSD_DEVICE}" 1)")
    # shellcheck disable=SC2034
    DATA_PART=$(dev_part "${OSD_DEVICE}" 1)
    if [[ ${OSD_BLUESTORE} -eq 1 ]]; then
      get_dmcrypt_bluestore_uuid
      close_encrypted_parts_bluestore
    elif [[ "${OSD_FILESTORE}" -eq 1 ]]; then
      get_dmcrypt_filestore_uuid
      close_encrypted_parts_filestore
    fi
  fi

  # watch the udev event queue, and exit if all current events are handled
  udevadm settle --timeout=600

  apply_ceph_ownership_to_disks
}
