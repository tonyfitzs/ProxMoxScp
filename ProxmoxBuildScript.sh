#!/usr/bin/env bash
#
# FlipFeso Production VM Builder
# Creates a Debian 12 cloud VM with Docker and SSH key injection on Proxmox VE.
#
# Spec:
#  - Debian 12 (cloud image)
#  - 8 vCPU
#  - 32 GB RAM
#  - 500 GB disk
#  - Q35 + UEFI (OVMF)
#  - SSH key injected for root and debian users
#  - Docker + Docker Compose plugin

set -euo pipefail

############### CONFIG ###############

VM_NAME="flipfeso-prod"
CORES=8                # vCPU
RAM_MB=32768           # 32 GB
DISK_SIZE="500G"       # root disk size
BRIDGE="vmbr0"         # network bridge
OSTYPE="l26"
MACHINE="q35"
CPU_TYPE="host"
STORAGE=""             # will be selected interactively
DEBIAN_VERSION="12"
DEBIAN_CLOUD_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-$(dpkg --print-architecture).qcow2"

######################################

# Pretty printing
YW="$(echo "\033[33m")"
BL="$(echo "\033[36m")"
RD="$(echo "\033[01;31m")"
GN="$(echo "\033[1;92m")"
CL="$(echo "\033[m")"
BOLD="$(echo "\033[1m")"

function msg_info()  { echo -e "${YW}[INFO]${CL} $*"; }
function msg_ok()    { echo -e "${GN}[ OK ]${CL} $*"; }
function msg_err()   { echo -e "${RD}[ERR ]${CL} $*"; }

function header_info() {
  clear
  cat <<"EOF"
   ______ _ _       _____            _                
  |  ____(_) |     |  __ \          | |               
  | |__   _| | ___ | |__) |___  __ _| | ___  ___ _ __ 
  |  __| | | |/ _ \|  _  // _ \/ _` | |/ _ \/ _ \ '__|
  | |    | | | (_) | | \ \  __/ (_| | |  __/  __/ |   
  |_|    |_|_|\___/|_|  \_\___|\__,_|_|\___|\___|_|   

   FlipFeso Debian 12 Production VM Builder
EOF
}

######################################
# Sanity checks
######################################

function require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_err "Please run this script as root."
    exit 1
  fi
}

function check_pve() {
  if ! command -v pveversion &>/dev/null; then
    msg_err "This script must be run on a Proxmox VE node."
    exit 1
  fi
}

function check_arch() {
  local arch
  arch="$(dpkg --print-architecture)"
  if [[ "$arch" != "amd64" ]]; then
    msg_err "Only amd64 architecture is supported (got: $arch)."
    exit 1
  fi
}

######################################
# Helpers
######################################

function get_next_vmid() {
  pvesh get /cluster/nextid
}

function pick_storage() {
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
    # Only one option
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

function generate_mac() {
  # Locally administered MAC
  printf '02:%02X:%02X:%02X:%02X:%02X\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

######################################
# SSH key handling
######################################

function get_ssh_key() {
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

######################################
# Image preparation
######################################

function ensure_libguestfs() {
  if ! command -v virt-customize &>/dev/null; then
    msg_info "Installing libguestfs-tools on Proxmox host..."
    apt-get -qq update >/dev/null
    apt-get -qq install -y libguestfs-tools lsb-release >/dev/null
    # workaround some libguestfs DHCP needs
    apt-get -qq install -y dhcpcd-base >/dev/null 2>&1 || true
    msg_ok "libguestfs-tools installed."
  fi
}

function download_debian_image() {
  local tmpdir="$1"
  local img_file

  msg_info "Downloading Debian ${DEBIAN_VERSION} cloud image..."
  img_file="${tmpdir}/$(basename "${DEBIAN_CLOUD_URL}")"
  curl -fSL -o "$img_file" "$DEBIAN_CLOUD_URL"
  msg_ok "Downloaded image: ${BL}${img_file}${CL}"

  echo "$img_file"
}

function customize_image() {
  local img_file="$1"
  local hostname="$2"
  local pubkey="$3"

  msg_info "Customizing image (Docker, guest-agent, SSH keys, hostname)..."

  virt-customize -q -a "$img_file" \
    --install qemu-guest-agent,apt-transport-https,ca-certificates,curl,gnupg,software-properties-common,lsb-release \
    --run-command "mkdir -p /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg" \
    --run-command "echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable' > /etc/apt/sources.list.d/docker.list" \
    --run-command "apt-get update -qq && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin" \
    --run-command "systemctl enable docker" \
    --hostname "$hostname" \
    --ssh-inject "debian:string:${pubkey}" \
    --ssh-inject "root:string:${pubkey}" \
    --run-command "mkdir -p /root/.ssh /home/debian/.ssh && chmod 700 /root/.ssh /home/debian/.ssh && chown debian:debian /home/debian/.ssh" \
    --run-command "echo -n > /etc/machine-id"

  msg_ok "Image customized successfully."
}

function expand_image() {
  local img_file="$1"
  local size="$2"
  local tmpdir
  tmpdir="$(dirname "$img_file")"

  msg_info "Expanding root filesystem to ${size}..."
  qemu-img create -f qcow2 "${tmpdir}/expanded.qcow2" "$size" >/dev/null 2>&1
  virt-resize --expand /dev/sda1 "$img_file" "${tmpdir}/expanded.qcow2" >/dev/null 2>&1
  mv "${tmpdir}/expanded.qcow2" "$img_file"
  msg_ok "Image expanded."
}

######################################
# VM creation
######################################

function create_vm() {
  local vmid="$1"
  local img_file="$2"
  local storage="$3"
  local mac_addr="$4"

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

  # Attach imported disk as scsi0
  local disk
  disk=$(qm config "$vmid" | awk '/unused0/ {print $2}')
  if [[ -z "$disk" ]]; then
    msg_err "Failed to find imported disk (unused0) in VM config."
    exit 1
  fi

  qm set "$vmid" --scsi0 "$disk,discard=on,ssd=1" >/dev/null
  msg_ok "Attached disk as scsi0: ${disk}"

  # Add EFI disk
  qm set "$vmid" --efidisk0 "${storage}:1,efitype=4m,pre-enrolled-keys=1" >/dev/null
  msg_ok "EFI disk added."

  # Set boot order and resize to final size (safety)
  qm set "$vmid" --boot order=scsi0 >/dev/null
  qm resize "$vmid" scsi0 "$DISK_SIZE" >/dev/null 2>&1 || true

  msg_ok "VM ${vmid} (${VM_NAME}) created successfully."
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
ensure_libguestfs

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

IMG_FILE="$(download_debian_image "$TMPDIR")"
customize_image "$IMG_FILE" "$VM_NAME" "$PUBKEY"
expand_image "$IMG_FILE" "$DISK_SIZE"

VMID="$(get_next_vmid)"
msg_ok "Using VM ID: ${BL}${VMID}${CL}  MAC: ${BL}${MAC_ADDR}${CL}"

create_vm "$VMID" "$IMG_FILE" "$STORAGE" "$MAC_ADDR"

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
echo "Next steps:"
echo "  1) Find the VM's IP (via DHCP leases or Proxmox console)."
echo "  2) SSH using your existing PuTTY private key to user 'debian' or 'root'."
