#!/bin/bash
set -euo pipefail
source helpers/common.py

validate() {
  if [[ ${bupsrc[path]} == /dev/disk/by-id/* ]]; then
    local part; part=$(basename "${bupsrc[devpart]}")
    if [[ -e "/sys/class/block/$part/partition" ]]; then
      return  # Valid
    else
      echo "Error: ${bupsrc[name]}'s path is not an existing partition: ${bupsrc[path]}"
      exit 1
    fi
  fi

  if ! echo "${bupsrc[path]}" | grep -Eq "^/dev/disk/by-.*uuid/"; then
    echo "Error: ${bupsrc[name]}'s path is not specified with /dev/disk/by-*uuid/: ${bupsrc[path]}"
    exit 1
  fi

  local uuid=${bupsrc[path]#/dev/disk/by-*uuid/}  # /dev/disk/by-partuuid/asdf --> asdf
  local instances; instances=$(lsblk --raw --output uuid,partuuid,pkname | grep "$uuid")

  if [[ $(echo "$instances" | wc -l) != 1 ]]; then
    disks=$(echo "$instances" | cut -d" " -f3 | sed 's|^|/dev/|')
    echo -e "Error: multiple UUIDs for ${bupsrc[name]}." \
      "Refusing to continue as the backup could be made from the wrong one.\n"
    # shellcheck disable=SC2086
    lsblk --tree --output name,uuid,partuuid,label,model,serial $disks
    exit 1
  fi
}


case "$1" in
  "$hook_before")
    while next_bupsrc; do
      if ! is_bupsrc_target_linux; then
        validate
      fi
    done
    ;;
esac
