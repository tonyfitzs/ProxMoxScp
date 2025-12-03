#!/usr/bin/env bash

set -euo pipefail

# ---- CONFIG ----
VM_NAME="flipfeso-prod"
CORES=8
RAM_MB=8192          # 8 GB by default (32 GB was too much for the host)
DISK_SIZE="500G"
BRIDGE="vmbr0"
OSTYPE="l26"
MACHINE="q35"
CPU_TYPE="host"
STORAGE="Prox2LVM"   # your storage pool

WORKDIR="/tmp/flipfeso-cloud"
SSHKEY_FILE="/root/flipfeso-sshkey.pub"
DEBIAN_CLOUD_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2"

echo
echo "==== FlipFeso Debian 12 Production VM Builder (static IP) ===="
echo
echo "This will create a VM with:"
echo "  Name : $VM_NAME"
echo "  CPU  : $CORES"
echo "  RAM  : ${RAM_MB} MB"
echo "  Disk : $DISK_SIZE"
echo "  Net  : bridge $BRIDGE"
echo "  Store: $STORAGE"
echo

read -rp "Continue? [Y/n]: " cont
cont=${cont:-Y}
if [[ ! "$cont" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

# Basic checks
if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must be run as root."
  exit 1
fi

if ! command -v qm >/dev/null 2>&1; then
  echo "This must run on a Proxmox VE node (qm not found)."
  exit 1
fi

# ---- Static IP info ----
echo
echo "Static IP configuration (for cloud-init):"
echo "  Example IP/CIDR: 10.110.11.54/24"
echo "  Example Gateway: 10.110.11.1"
echo

read -rp "Enter static IP with CIDR (e.g. 10.110.11.54/24): " IP_CIDR
read -rp "Enter gateway IP (e.g. 10.110.11.1): " GW

if [[ -z "$IP_CIDR" || -z "$GW" ]]; then
  echo "IP and gateway cannot be empty."
  exit 1
fi

IPCONFIG0="ip=${IP_CIDR},gw=${GW}"

# ---- SSH key ----
echo
echo "Paste your SSH PUBLIC key (from PuTTYgen: 'Public key for pasting into OpenSSH authorized_keys file')"
echo "It should start with ssh-ed25519 or ssh-rsa and be a single line."
read -r PUBKEY

if [[ -z "$PUBKEY" ]]; then
  echo "SSH public key cannot be empty."
  exit 1
fi

echo "$PUBKEY" > "$SSHKEY_FILE"
chmod 600 "$SSHKEY_FILE"
echo "Saved SSH key to $SSHKEY_FILE"

# ---- Download cloud image ----
mkdir -p "$WORKDIR"
IMG_FILE="$WORKDIR/debian-12-nocloud-amd64.qcow2"

# If something weird exists there (dir/symlink/etc), remove it
if [[ -e "$IMG_FILE" && ! -f "$IMG_FILE" ]]; then
  rm -rf "$IMG_FILE"
fi

if [[ -f "$IMG_FILE" ]]; then
  echo "Image already exists at $IMG_FILE, reusing."
else
  echo "Downloading Debian 12 cloud image..."
  curl -fSL -o "$IMG_FILE" "$DEBIAN_CLOUD_URL"
fi

echo "Image details:"
ls -l "$IMG_FILE"
file "$IMG_FILE" || true

# ---- Get next VMID ----
VMID=$(pvesh get /cluster/nextid)
echo
echo "Using VMID: $VMID"

# ---- Create VM ----
echo "Creating VM $VMID..."
qm create "$VMID" \
  --name "$VM_NAME" \
  --memory "$RAM_MB" \
  --cores "$CORES" \
  --cpu "$CPU_TYPE" \
  --machine "$MACHINE" \
  --ostype "$OSTYPE" \
  --scsihw virtio-scsi-pci \
  --bios ovmf \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --net0 "virtio,bridge=${BRIDGE}" \
  --onboot 1

# Add EFI disk to avoid WARN about temporary efivars
echo "Adding EFI disk..."
qm set "$VMID" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=1"

# ---- Import disk ----
echo "Importing disk into $STORAGE..."
qm importdisk "$VMID" "$IMG_FILE" "$STORAGE"

DISK=$(qm config "$VMID" | awk '/unused0/ {print $2}')
if [[ -z "$DISK" ]]; then
  echo "Failed to find imported disk (unused0) in VM config."
  exit 1
fi

echo "Attaching disk as scsi0: $DISK"
qm set "$VMID" --scsi0 "$DISK,discard=on,ssd=1"

# ---- Cloud-init drive ----
echo "Adding cloud-init drive..."
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"

# ---- Cloud-init config (STATIC IP, SSH key, user) ----
echo "Configuring cloud-init (user=debian, static IP)..."
qm set "$VMID" \
  --ciuser debian \
  --sshkey "$SSHKEY_FILE" \
  --ipconfig0 "$IPCONFIG0"

# ---- Resize disk ----
echo "Resizing disk to $DISK_SIZE..."
qm resize "$VMID" scsi0 "$DISK_SIZE" || true

# ---- Boot order ----
qm set "$VMID" --boot order=scsi0

# ---- Start VM ----
echo "Starting VM $VMID..."
qm start "$VMID"

echo
echo "Done."
echo "VM ID:   $VMID"
echo "Name:    $VM_NAME"
echo "Storage: $STORAGE"
echo "IP:      $IP_CIDR (static, via cloud-init)"
echo
echo "Once it boots, SSH with:"
echo "  user: debian"
echo "  auth: your PuTTY private key (for the public key you pasted)"
EOF

chmod +x flipfeso-vm-static.sh
