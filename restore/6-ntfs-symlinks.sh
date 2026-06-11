#!/bin/bash
set -euo pipefail

if [[ "$#" -lt 3 ]] || [[ "$#" -gt 3 ]]; then
  echo "Usage: $0 <folder_junctions|folder_symlinks> <source_dir> <dest_base_dir>"
  echo ""
  echo "Example: $0 folder_junctions /mnt/borg/NTFS_PART /media/user/NTFS_PART"
  exit 1
fi

MODE="$1"
SRC_DIR=$(realpath "$2")

if [[ "$MODE" != "folder_junctions" ]] && [[ "$MODE" != "folder_symlinks" ]]; then
  echo "Error: first argument must be 'folder_junctions' or 'folder_symlinks'"
  exit 1
fi

DEST_BASE_DIR="$(realpath "$3")/_tamborgmatic"
rm -rf "$DEST_BASE_DIR"  # It should have been recently restored. If name clashes and this script deletes it, just restore again.
mkdir -p "$DEST_BASE_DIR"
FILE_RM="$DEST_BASE_DIR/rm.0"
FILE_LN="$DEST_BASE_DIR/ln.bat"
FILE_MISSING="$DEST_BASE_DIR/missing.csv"

echo "@echo off
cd /d \"%~dp0\..\"

set v5=0
ver | findstr /l \" 5.\" >nul
if %errorlevel% == 0 set v5=1
" >"$FILE_LN"
# For Windows XP and other Windows version 5, the following utilities should be in %PATH%:
# - ln.exe from https://schinagl.priv.at/nt/hardlinkshellext/hardlinkshellext.html
# - linkd.exe from [Windows Server 2003 Resource Kit Tools](https://web.archive.org/web/20070119115200/https://download.microsoft.com/download/8/e/c/8ec3a7d8-05b4-440a-a71e-ca3ee25fe057/rktools.exe)

echo "link,target" >"$FILE_MISSING"

# Prefix for absolute links in the mounted archive
ABS_PREFIX="/mnt/tamborgmatic/merged/$(basename "$SRC_DIR")/"

winpath() {
  # Converts / to \
  echo "${1//\//\\}"
}

lns() {
  local target="$1" link="$2"
  local dirlink; dirlink=$(dirname "$link")
  local baselink; baselink=$(basename "$link")
  echo "pushd \"$(winpath "$dirlink")\" && (ln -s \"$(winpath "$target")\" \"$baselink\" & popd)"
}

cd "$SRC_DIR"

# Find all symlinks
find . -type l -print0 | while IFS= read -r -d '' link; do
  # Remove leading ./ from link
  link="${link#./}"

  # These $link files are problematic for Windows. In particular, cmd.exe can't `del` them, so rm them in Linux:
  printf '%s\0' "$link" >>"$FILE_RM"

  # Get the target of the symlink
  target=$(readlink "$link")

  is_absolute=false
  if [[ "$target" == /* ]]; then
    is_absolute=true
  fi

  if [[ "$is_absolute" == "true" ]]; then
    if [[ "$target" == "$ABS_PREFIX"* ]]; then
      # It's an absolute link within the expected prefix, remove the prefix
      target="${target#"$ABS_PREFIX"}"
    else
      echo "Error: Absolute link '$link' points outside expected prefix: $target"
      exit 1
    fi
  fi

  # Check if the target exists (relative to the link's directory or absolute)
  # Since we are in SRC_DIR, we need to check relative to the link's parent
  if [[ "$is_absolute" == "true" ]]; then
    full_target_path="$SRC_DIR/$target"
  else
    link_dir=$(dirname "$link")
    full_target_path="$SRC_DIR/$link_dir/$target"
  fi

  if [[ ! -e "$full_target_path" ]]; then
    echo "$link,$target" >>"$FILE_MISSING"
    continue
  fi

  if [ -d "$full_target_path" ]; then
    # Directory
    if [ "$MODE" == "folder_symlinks" ]; then
      echo "if %v5%==0 (mklink /D \"$(winpath "$link")\" \"$(winpath "$target")\") else ($(lns "$target" "$link"))" >>"$FILE_LN"
    else  # folder_junctions
      echo "if %v5%==0 (mklink /J \"$(winpath "$link")\" \"$(winpath "$target")\") else (linkd \"$(winpath "$link")\" \"$(winpath "$target")\")" >>"$FILE_LN"
    fi
  else  # File
    echo "if %v5%==0 (mklink \"$(winpath "$link")\" \"$(winpath "$target")\") else ($(lns "$target" "$link"))" >>"$FILE_LN"
  fi
done

if [[ ! -f "$FILE_RM" ]]; then
  echo "No symlinks or junctions found. Workaround isn't required, skip this step :)"
  rm -rf "$DEST_BASE_DIR"
elif [[ "$(<"$FILE_MISSING" wc -l)" == "1" ]]; then
  # No missing files (only header)
  rm "$FILE_MISSING"
fi
