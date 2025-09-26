#!/usr/bin/env bash
set -euo pipefail

### ========= Configurable variables =========
VMID="${VMID:-9001}"
VM_NAME="${VM_NAME:-dev-singlebox}"
NODE="${NODE:-$(hostname)}"                 # Proxmox node to host the VM
STORAGE="${STORAGE:-local-lvm}"             # Storage for VM disks (e.g., local-lvm, nvme, ceph-ssd)
ISO_STORAGE="${ISO_STORAGE:-local}"         # Storage where images/isos are kept (usually "local")
BRIDGE="${BRIDGE:-vmbr0}"
DISK_SIZE_GB="${DISK_SIZE_GB:-800}"         # Size of primary disk for the VM
MEMORY_MB="${MEMORY_MB:-32768}"             # 32 GB
CORES="${CORES:-8}"                         # vCPU cores
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa.pub}"   # Your public key for the devops user
CI_USER="${CI_USER:-devops}"
TIMEZONE="${TIMEZONE:-Australia/Melbourne}"

# Image info (Ubuntu 22.04 cloud image)
IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
IMG_NAME="ubuntu-22.04-jammy-cloudimg-amd64.img"
IMG_PATH="/var/lib/vz/template/iso/${IMG_NAME}"

### ========= Sanity checks =========
command -v qm >/dev/null || { echo "This must run on a Proxmox node (qm not found)."; exit 1; }
[[ -r "${SSH_KEY_PATH}" ]] || { echo "SSH key not found at ${SSH_KEY_PATH}"; exit 1; }
pvesm status >/dev/null || { echo "Proxmox storage subsystem not responding."; exit 1; }

### ========= Fetch cloud image (once) =========
if [[ ! -f "${IMG_PATH}" ]]; then
  echo "Downloading Ubuntu cloud image to ${IMG_PATH} ..."
  mkdir -p "$(dirname "${IMG_PATH}")"
  curl -L "${IMG_URL}" -o "${IMG_PATH}"
fi

### ========= Enable 'snippets' on ISO storage (for cloud-init custom user-data) =========
# Will no-op if already enabled
if ! pvesm status | awk -v s="${ISO_STORAGE}" '$1==s {print $0}' | grep -q snippets; then
  echo "Enabling 'snippets' content type on storage '${ISO_STORAGE}' ..."
  pvesm set "${ISO_STORAGE}" --content "$(pvesm status | awk -v s="${ISO_STORAGE}" '$1==s {print $0}' | awk '{print $2}'),snippets" || true
fi

SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "${SNIPPET_DIR}"

USERDATA_FILE="${SNIPPET_DIR}/${VM_NAME}-user-data.yml"

### ========= Cloud-init user-data (installs Docker, Compose, prepares dev stack) =========
cat > "${USERDATA_FILE}" <<'YAML'
#cloud-config
preserve_hostname: false
hostname: dev-singlebox
manage_etc_hosts: true
timezone: ${TIMEZONE}

users:
  - name: ${CI_USER}
    groups: [sudo, docker]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - ${SSH_PUBKEY}

package_update: true
package_upgrade: true
packages:
  - ca-certificates
  - curl
  - gnupg
  - git
  - apt-transport-https
  - jq

write_files:
  - path: /etc/sysctl.d/99-opensearch.conf
    content: |
      vm.max_map_count=262144
    owner: root:root
    permissions: '0644'

  - path: /etc/security/limits.d/90-opensearch.conf
    content: |
      * soft memlock unlimited
      * hard memlock unlimited
    owner: root:root
    permissions: '0644'

  - path: /opt/devstack/.env
    content: |
      # Generated defaults; change as needed
      POSTGRES_USER=app
      POSTGRES_PASSWORD=$(openssl rand -hex 16)
      POSTGRES_DB=appdb
      REDIS_PASSWORD=$(openssl rand -hex 16)
      MINIO_ROOT_USER=minioadmin
      MINIO_ROOT_PASSWORD=$(openssl rand -hex 16)
      OPENSEARCH_PASSWORD=$(openssl rand -hex 16)
      TRAEFIK_BASIC_AUTH=$(printf "admin:$(openssl passwd -apr1 admin)" )
    owner: root:root
    permissions: '0600'

  - path: /opt/devstack/prometheus/prometheus.yml
    content: |
      global:
        scrape_interval: 15s
      scrape_configs:
        - job_name: 'prometheus'
          static_configs:
            - targets: ['prometheus:9090']
        - job_name: 'node'
          static_configs:
            - targets: ['host.docker.internal:9100']
        - job_name: 'traefik'
          static_configs:
            - targets: ['traefik:8080']
    owner: root:root
    permissions: '0644'

  - path: /opt/devstack/docker-compose.yml
    content: |
      version: "3.9"
      name: dev-singlebox
      services:
        traefik:
          image: traefik:v3.1
          command:
            - --api.insecure=true
            - --providers.docker=true
            - --entrypoints.web.address=:80
          ports:
            - "80:80"
            - "8080:8080"   # Traefik dashboard
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
          restart: unless-stopped

        postgres:
          image: postgres:16
          environment:
            POSTGRES_USER: ${POSTGRES_USER}
            POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
            POSTGRES_DB: ${POSTGRES_DB}
          volumes:
            - pgdata:/var/lib/postgresql/data
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER"]
            interval: 10s
            timeout: 5s
            retries: 5
          restart: unless-stopped

        redis:
          image: redis:7
          command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]
          ports:
            - "6379:6379"
          restart: unless-stopped

        opensearch:
          image: opensearchproject/opensearch:2
          environment:
            - discovery.type=single-node
            - OPENSEARCH_INITIAL_ADMIN_PASSWORD=${OPENSEARCH_PASSWORD}
            - plugins.security.disabled=true
            - bootstrap.memory_lock=true
          ulimits:
            memlock:
              soft: -1
              hard: -1
            nofile:
              soft: 65536
              hard: 65536
          volumes:
            - osdata:/usr/share/opensearch/data
          ports:
            - "9200:9200"
            - "9600:9600"
          restart: unless-stopped

        osdash:
          image: opensearchproject/opensearch-dashboards:2
          environment:
            - OPENSEARCH_HOSTS=["http://opensearch:9200"]
          ports:
            - "5601:5601"
          depends_on:
            - opensearch
          restart: unless-stopped

        minio:
          image: minio/minio:latest
          command: server /data --console-address ":9001"
          environment:
            MINIO_ROOT_USER: ${MINIO_ROOT_USER}
            MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
          volumes:
            - minio:/data
          ports:
            - "9000:9000"
            - "9001:9001"
          restart: unless-stopped

        prometheus:
          image: prom/prometheus:latest
          volumes:
            - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
          ports:
            - "9090:9090"
          restart: unless-stopped

        grafana:
          image: grafana/grafana:latest
          environment:
            - GF_SECURITY_ADMIN_USER=admin
            - GF_SECURITY_ADMIN_PASSWORD=admin
          ports:
            - "3000:3000"
          volumes:
            - grafana:/var/lib/grafana
          depends_on:
            - prometheus
          restart: unless-stopped

        # --- Placeholders for your stateless app services (replace images) ---
        api:
          image: nginx:alpine
          labels:
            - "traefik.http.routers.api.rule=HostRegexp(`{host:.+}`) && PathPrefix(`/api`)"
            - "traefik.http.services.api.loadbalancer.server.port=80"
          restart: unless-stopped

        realtime:
          image: nginx:alpine
          labels:
            - "traefik.http.routers.realtime.rule=PathPrefix(`/ws`)"
            - "traefik.http.services.realtime.loadbalancer.server.port=80"
          restart: unless-stopped

        web:
          image: nginx:alpine
          labels:
            - "traefik.http.routers.web.rule=PathPrefix(`/`)"
            - "traefik.http.services.web.loadbalancer.server.port=80"
          volumes:
            - webroot:/usr/share/nginx/html:ro
          restart: unless-stopped

        worker:
          image: alpine:3
          command: ["sh","-c","while true; do echo worker alive; sleep 30; done"]
          restart: unless-stopped

      volumes:
        pgdata: {}
        osdata: {}
        minio: {}
        grafana: {}
        webroot: {}

runcmd:
  - timedatectl set-timezone ${TIMEZONE}
  - sysctl --system

  # Install Docker Engine + compose plugin
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Let ${CI_USER} use docker without sudo
  - usermod -aG docker ${CI_USER}

  # Bring up the dev stack
  - mkdir -p /opt/devstack/prometheus
  - chown -R ${CI_USER}:${CI_USER} /opt/devstack
  - cd /opt/devstack && docker compose up -d

final_message: |
  Dev single-box is ready. SSH in as '${CI_USER}'. Stack is in /opt/devstack.
YAML

# Replace template vars inside user-data
SSH_PUBKEY="$(cat "${SSH_KEY_PATH}")"
sed -i "s|\${CI_USER}|${CI_USER}|g" "${USERDATA_FILE}"
sed -i "s|\${SSH_PUBKEY}|${SSH_PUBKEY//|/\\|}|g" "${USERDATA_FILE}"
sed -i "s|\${TIMEZONE}|${TIMEZONE}|g" "${USERDATA_FILE}"

### ========= Create VM =========
echo "Creating VM ${VMID} (${VM_NAME}) on node ${NODE} ..."
qm create "${VMID}" --name "${VM_NAME}" --memory "${MEMORY_MB}" --cores "${CORES}" --sockets 1 --agent 1 \
  --net0 virtio,bridge="${BRIDGE}" --scsihw virtio-scsi-pci --ostype l26 --serial0 socket

# Import disk from cloud image and attach
echo "Importing cloud image disk ..."
qm importdisk "${VMID}" "${IMG_PATH}" "${STORAGE}" --format qcow2
qm set "${VMID}" --scsi0 "${STORAGE}:vm-${VMID}-disk-0"
qm set "${VMID}" --efidisk0 "${STORAGE}:0,pre-enrolled-keys=1" --boot order=scsi0
qm set "${VMID}" --ide2 "${ISO_STORAGE}:cloudinit"

# Resize root disk
qm resize "${VMID}" scsi0 "${DISK_SIZE_GB}G"

# Cloud-init: DHCP + custom user-data
qm set "${VMID}" --ciuser "${CI_USER}" --ipconfig0 ip=dhcp
qm set "${VMID}" --cicustom "user=${ISO_STORAGE}:snippets/$(basename "${USERDATA_FILE}")"

# Start VM
echo "Starting VM..."
qm start "${VMID}"

echo "Done."
echo "Next steps:"
echo "  - Find the VM IP: 'qm guest exec ${VMID} ip -brief a' (after cloud-init finishes) or check your DHCP leases."
echo "  - SSH in: ssh ${CI_USER}@<vm-ip>"
echo "  - Traefik dashboard: http://<vm-ip>:8080"
echo "  - OpenSearch: http://<vm-ip>:9200   | Dashboards: http://<vm-ip>:5601"
echo "  - MinIO: http://<vm-ip>:9001        | Prometheus: http://<vm-ip>:9090 | Grafana: http://<vm-ip>:3000"
