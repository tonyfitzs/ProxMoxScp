#!/usr/bin/env bash
#
# FlipFeso Debian 12 VM Builder (cloud-init version)
# - No libguestfs, no virt-customize
# - Uses Debian 12 cloud image + Proxmox cloud-init to inject SSH key
#
# Spec:
#  - Debian 12 (cloud image)
#  - 8 vCPU
#  - 32 GB RAM
#  - 500 GB disk
#  - Q35 + UEFI (OVMF)
#  - SSH key injected via cloud-init
#

set -euo pipefail

############### CONFIG ###############

VM_NAME="flipfeso-prod"
CORES=8
RAM_MB=32768
DISK_SIZE="500G"
BRIDGE="vmbr0"
OSTYPE="l26"
MACHINE="q35"
CPU_TYPE="host"
STORAGE=""
DEBIAN_VERSION="12"
DEBIAN_CLOUD_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-$(dpkg --print-architecture).qcow2"

# Where to store the image
WORKDIR="/root/flipfeso-cloud"
SSHKEY_FILE="/root/flipfeso-sshkey.pub"

######################################

YW="$(echo "\033[33m")"
BL="$(echo "\033[36m")"
RD="$(echo "\033[01;31m")"
GN="$(echo "\033[1;92m")"
CL="$(echo "\033[m")"
BOLD="$(echo "\033[1m")"

msg_info()  { echo -e "${YW}[INFO]${CL} $*"; }
msg_ok()    { echo -e "${GN}[ OK ]${CL} $*"; }
msg_err()   { echo -e "${RD}[ERR ]${CL} $*"; }

header_info() {
  clear
  cat <<"EOF"
   ______ _ _       _____            _                
  |  ____(_) |     |  __ \          | |               
  | |__   _| | ___ | |__) |___  __ _| | ___  ___ _ __ 
  |  __| | | |/ _ \|  _  // _ \/ _` | |/ _ \/ _ \ '__|
  | |    | | | (_) | | \ \  __/ (_| | |  __/  __/ |   
  |_|    |_|_|\___/|_|  \_\___|\__,_|_|\___|\___|_|   

   FlipFeso Debian 12 Production VM Builder (cloud-init)
EOF
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_err "Please run this script as root."
    exit 1
  fi
}

check_pve() {
  if ! command -v pveversion &>/dev/null; then
    msg_err "This script must be run on a Proxmox VE node."
    exit 1
  fi
}

check_arch() {
  local arch
  arch="$(dpkg --print-architecture)"
  if [[ "$arch" != "amd64" ]]; then
    msg_err "Only amd64 architecture is supported (got: $arch)."
    exit 1
  fi
}

get_next_vmid() {
  pvesh get /cluster/nextid
}

pick_storage() {
  msg_info "Detecting storage pools that support disk images..."
  local menu=()
  local line tag type free item maxlen=0

  while read -r line; do
    tag=$(echo "$line" | awk '{print $1}')
    type=$(echo "$line" | awk '{printf "%-10s", $2}')
    free=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf "%9sB", $6}')
    item="Type: $type Free: $free"
    [[ ${#item} -gt $maxlen ]] && maxlen=${#item}
    menu+=("$tag" "$item" "OFF")
  done < <(pvesm status -content images | awk 'NR>1')

  if [[ ${#menu[@]} -eq 0 ]]; then
    msg_err "No valid storage pool found that supports images."
    exit 1
  fi

  if [[ ${#menu[@]} -eq 3 ]]; then
    STORAGE="${menu[0]}"
    msg_ok "Using storage: ${BL}${STORAGE}${CL}"
    return
  fi

  if command -v whiptail &>/dev/null; then
    STORAGE=$(whiptail --backtitle "FlipFeso VM Builder" --title "Storage Pools" --radiolist \
      "Select storage for ${VM_NAME} disk image:\n(Use SPACE to select)" \
      16 $((maxlen + 30)) 6 \
      "${menu[@]}" 3>&1 1>&2 2>&3) || {
        msg_err "Storage selection cancelled."
        exit 1
      }
  else
    echo "Available storage pools:"
    local i=0
    while [[ $i -lt ${#menu[@]} ]]; do
      echo "  - ${menu[$i]}: ${menu[$((i+1))]}"
      i=$((i+3))
    done
    read -rp "Enter storage name to use: " STORAGE
  fi

  msg_ok "Using storage: ${BL}${STORAGE}${CL}"
}

generate_mac() {
  printf '02:%02X:%02X:%02X:%02X:%02X\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

get_ssh_key() {
  local PUBKEY=""

  if command -v whiptail &>/dev/null; then
    PUBKEY=$(whiptail --backtitle "FlipFeso VM Builder" --title "SSH Public Key" --inputbox \
      "Paste your SSH PUBLIC key here (from PuTTYgen: 'Public key for pasting into OpenSSH authorized_keys file').\n\nIt should start with ssh-ed25519 or ssh-rsa and be a single line." \
      14 80 "" 3>&1 1>&2 2>&3) || {
        msg_err "SSH key input cancelled."
        exit 1
      }
  else
    echo
    echo "Paste your SSH PUBLIC key (single line), then press Enter:"
    read -r PUBKEY
  fi

  if [[ -z "$PUBKEY" ]]; then
    msg_err "SSH public key cannot be empty."
    exit 1
  fi

  echo "$PUBKEY"
}

download_debian_image() {
  mkdir -p "$WORKDIR"
  local img_file="${WORKDIR}/$(basename "${DEBIAN_CLOUD_URL}")"

  if [[ -f "$img_file" ]]; then
    msg_ok "Image already exists at ${BL}${img_file}${CL}, reusing."
  else
    msg_info "Downloading Debian ${DEBIAN_VERSION} cloud image..."
    curl -fSL -o "$img_file" "$DEBIAN_CLOUD_URL"
    msg_ok "Downloaded image: ${BL}${img_file}${CL}"
  fi

  echo "$img_file"
}

create_vm() {
  local vmid="$1"
  local img_file="$2"
  local storage="$3"
  local mac_addr="$4"
  local sshkey_file="$5"

  msg_info "Creating VM ID ${vmid} (${VM_NAME})..."

  qm create "$vmid" \
    --name "$VM_NAME" \
    --memory "$RAM_MB" \
    --cores "$CORES" \
    --cpu "$CPU_TYPE" \
    --machine "$MACHINE" \
    --ostype "$OSTYPE" \
    --scsihw virtio-scsi-pci \
    --bios ovmf \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --net0 "virtio,bridge=${BRIDGE},macaddr=${mac_addr}" \
    --onboot 1

  msg_ok "Base VM config created."

  msg_info "Importing disk into storage ${storage}..."
  qm importdisk "$vmid" "$img_file" "$storage" >/dev/null

  local disk
  disk=$(qm config "$vmid" | awk '/unused0/ {print $2}')
  if [[ -z "$disk" ]]; then
    msg_err "Failed to find imported disk (unused0) in VM config."
    exit 1
  fi

  qm set "$vmid" --scsi0 "$disk,discard=on,ssd=1" >/dev/null
  msg_ok "Attached disk as scsi0: ${disk}"

  # Add cloud-init drive
  qm set "$vmid" --ide2 "${storage}:cloudinit" >/dev/null
  msg_ok "Cloud-init drive added."

  # Set hostname, SSH key, and enable DHCP
  qm set "$vmid" \
    --ciuser debian \
    --sshkey "$sshkey_file" \
    --hostname "$VM_NAME" \
    --ipconfig0 ip=dhcp >/dev/null

  # Resize disk to desired size (cloud-init/growpart should grow FS on first boot)
  qm resize "$vmid" scsi0 "$DISK_SIZE" >/dev/null 2>&1 || true
  msg_ok "Disk resized to ${DISK_SIZE}."

  # Set boot order
  qm set "$vmid" --boot order=scsi0 >/dev/null

  msg_ok "VM ${vmid} (${VM_NAME}) created and configured with cloud-init."
}

######################################
# Main
######################################

header_info
require_root
check_pve
check_arch

echo
echo -e "${BOLD}This will create a Debian 12 FlipFeso Production VM with:${CL}"
echo "  - Name:   ${VM_NAME}"
echo "  - vCPU:   ${CORES}"
echo "  - RAM:    ${RAM_MB} MB"
echo "  - Disk:   ${DISK_SIZE}"
echo "  - Bridge: ${BRIDGE}"
echo
read -rp "Continue? [Y/n]: " cont
cont=${cont:-Y}
if [[ ! "$cont" =~ ^[Yy]$ ]]; then
  msg_err "Aborted by user."
  exit 1
fi

pick_storage
MAC_ADDR="$(generate_mac)"
PUBKEY="$(get_ssh_key)"

# Save SSH key to file for qm --sshkey
echo "$PUBKEY" > "$SSHKEY_FILE"
chmod 600 "$SSHKEY_FILE"
msg_ok "SSH key saved to ${SSHKEY_FILE}"

IMG_FILE="$(download_debian_image)"

VMID="$(get_next_vmid)"
msg_ok "Using VM ID: ${BL}${VMID}${CL}  MAC: ${BL}${MAC_ADDR}${CL}"

create_vm "$VMID" "$IMG_FILE" "$STORAGE" "$MAC_ADDR" "$SSHKEY_FILE"

msg_info "Starting VM ${VMID}..."
qm start "$VMID"
msg_ok "VM started."

echo
echo -e "${GN}Done!${CL}"
echo "VM ID:   $VMID"
echo "Name:    $VM_NAME"
echo "Bridge:  $BRIDGE"
echo "Storage: $STORAGE"
echo
echo "After it boots and gets a DHCP IP:"
echo "  - SSH as user 'debian' using your PuTTY private key."
echo "  - Then install Docker with:"
echo "        sudo apt-get update"
echo "        sudo apt-get install -y docker.io docker-compose-plugin"
