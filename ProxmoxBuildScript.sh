flipfeso-from-template.sh
#!/usr/bin/env bash

set -euo pipefail

# ---- CONFIG ----
TEMPLATE_ID=9600              # Your golden Debian 12 template
DEFAULT_VM_NAME="flipfeso-prod"
CORES=8
RAM_MB=8192                   # 8 GB
DISK_SIZE="500G"
BRIDGE="vmbr0"
DISK_STORAGE="Prox2LVM"
SSHKEY_FILE="/root/flipfeso-sshkey.pub"

echo
echo "==== FlipFeso VM Builder from Template (static IP + SSH) ===="
echo
echo "Template: $TEMPLATE_ID"
echo
echo "Default new VM settings:"
echo "  Name : $DEFAULT_VM_NAME (you can override)"
echo "  CPU  : $CORES"
echo "  RAM  : ${RAM_MB} MB"
echo "  Disk : $DISK_SIZE"
echo "  Net  : bridge $BRIDGE"
echo "  Disk Storage: $DISK_STORAGE"
echo

read -rp "Enter VM name [${DEFAULT_VM_NAME}]: " VM_NAME
VM_NAME=${VM_NAME:-$DEFAULT_VM_NAME}

echo
read -rp "Continue and create VM '${VM_NAME}'? [Y/n]: " cont
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

echo
echo "Static IP configuration (for cloud-init):"
echo "  Example IP/CIDR: 10.110.10.10/24"
echo "  Example Gateway: 10.110.10.1"
echo

read -rp "Enter static IP with CIDR (e.g. 10.110.10.10/24): " IP_CIDR
read -rp "Enter gateway IP (e.g. 10.110.10.1): " GW

if [[ -z "$IP_CIDR" || -z "$GW" ]]; then
  echo "IP and gateway cannot be empty."
  exit 1
fi

IPCONFIG0="ip=${IP_CIDR},gw=${GW}"

echo
echo "Paste your SSH PUBLIC key (PuTTYgen: 'Public key for pasting into OpenSSH authorized_keys file')"
echo "It should start with ssh-rsa or ssh-ed25519 and be a single line."
read -r PUBKEY

if [[ -z "$PUBKEY" ]]; then
  echo "SSH public key cannot be empty."
  exit 1
fi

echo "$PUBKEY" > "$SSHKEY_FILE"
chmod 600 "$SSHKEY_FILE"
echo "Saved SSH key to $SSHKEY_FILE"

# ---- Get next VMID and clone ----
VMID=$(pvesh get /cluster/nextid)
echo
echo "Cloning template $TEMPLATE_ID to VMID $VMID with name '$VM_NAME'..."
qm clone "$TEMPLATE_ID" "$VMID" --name "$VM_NAME" --full 1 --storage "$DISK_STORAGE"

echo "Setting CPU/RAM..."
qm set "$VMID" --cores "$CORES" --memory "$RAM_MB"

echo "Resizing disk to $DISK_SIZE..."
# Assumes template uses scsi0 as root disk
qm resize "$VMID" scsi0 "$DISK_SIZE" || true

# Ensure cloud-init drive exists
echo "Adding cloud-init drive (if not present)..."
qm set "$VMID" --ide2 "${DISK_STORAGE}:cloudinit" || true

echo "Configuring network + SSH key via cloud-init..."
qm set "$VMID" \
  --net0 "virtio,bridge=${BRIDGE}" \
  --sshkeys "$SSHKEY_FILE" \
  --ipconfig0 "$IPCONFIG0" \
  --ciuser debian

# Ensure boot order
qm set "$VMID" --boot order=scsi0

echo "Starting VM $VMID..."
qm start "$VMID"

echo
echo "==== FlipFeso VM created and started ===="
echo "  VM ID  : $VMID"
echo "  Name   : $VM_NAME"
echo "  IP     : $IP_CIDR (static)"
echo "  Storage: $DISK_STORAGE"
echo
echo "Login options:"
echo "  Console: user 'debian' with the password you set when creating the template (VMID $TEMPLATE_ID)"
echo "  SSH:     debian@${IP_CIDR%%/*} using your PuTTY private key"
echo
echo "Docker, cloud-init, qemu-guest-agent etc. should already be installed from the template."
EOF
