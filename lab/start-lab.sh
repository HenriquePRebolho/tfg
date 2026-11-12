#!/bin/bash

VALID_FIREWALLS=("fw-nftables" "fw-vyos" "fw-ipfire" "fw-openwrt")
FIREWALL_VM=""

# Timers (in seconds)
NET_SETTLE_DELAY=3   # Wait time after networks become active
VM_START_DELAY=2     # Delay between starting each VM

usage() {
  echo "Usage: $0 -fw <firewall-vm>"
  echo "Available firewalls: ${VALID_FIREWALLS[*]}"
}

# Parse terminal flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -fw|--fw)
      if [[ -z "$2" || "$2" == -* ]]; then
        echo "Error: $1 requires a firewall VM name."
        usage
        exit 1
      fi
      FIREWALL_VM="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Ensure a firewall flag was provided
if [[ -z "$FIREWALL_VM" ]]; then
  echo "Error: Missing firewall VM name."
  usage
  exit 1
fi

# Validate against the 4 allowed firewalls
IS_VALID=false
for fw in "${VALID_FIREWALLS[@]}"; do
  if [[ "$FIREWALL_VM" == "$fw" ]]; then
    IS_VALID=true
    break
  fi
done

if [[ "$IS_VALID" == false ]]; then
  echo "Error: '$FIREWALL_VM' is not a valid firewall VM."
  usage
  exit 1
fi

# Prevent gateway IP conflicts if another firewall VM is still active
for fw in "${VALID_FIREWALLS[@]}"; do
  if [[ "$fw" != "$FIREWALL_VM" ]]; then
    STATE=$(sudo virsh domstate "$fw" 2>/dev/null)
    if [[ "$STATE" == "running" ]]; then
      echo "Error: '$fw' is currently running. Shut it down before switching firewalls:"
      echo "  sudo virsh shutdown $fw"
      exit 1
    fi
  fi
done

# Start virtual networks and confirm each is active
for net in lab-untrusted lab-lan lab-dmz; do
  ACTIVE=$(sudo virsh net-info "$net" 2>/dev/null | awk '/Active:/ {print $2}')
  if [[ "$ACTIVE" != "yes" ]]; then
    echo "Starting network '$net'..."
    sudo virsh net-start "$net"

    # Wait up to 10 seconds for libvirt to report the network as active
    for _ in {1..10}; do
      ACTIVE=$(sudo virsh net-info "$net" 2>/dev/null | awk '/Active:/ {print $2}')
      [[ "$ACTIVE" == "yes" ]] && break
      sleep 1
    done

    if [[ "$ACTIVE" != "yes" ]]; then
      echo "Error: Network '$net' failed to become active."
      exit 1
    fi
  else
    echo "Network '$net' is already active."
  fi
done

echo "Waiting ${NET_SETTLE_DELAY}s for virtual bridges to settle..."
sleep "$NET_SETTLE_DELAY"
sudo virsh net-list --all

# Start the firewall first, followed by the endpoint VMs
for vm in "$FIREWALL_VM" client trusted attacker; do
  STATE=$(sudo virsh domstate "$vm" 2>/dev/null)
  if [[ "$STATE" != "running" ]]; then
    echo "Starting VM '$vm'..."
    sudo virsh start "$vm"
    sleep "$VM_START_DELAY"
  else
    echo "VM '$vm' is already running."
  fi
done

sudo virsh list
