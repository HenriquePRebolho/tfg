#!/bin/bash

BASE_VMS=("client" "trusted" "attacker")
FIREWALL_VMS=("fw-nftables" "fw-vyos" "fw-ipfire" "fw-openwrt")
NETWORKS=("lab-untrusted" "lab-lan" "lab-dmz")

SHUTDOWN_TIMEOUT=25  # Seconds to wait for graceful shutdown before forcing off

# Build the target list with base VMs plus whichever firewall is currently running
VMS_TO_STOP=("${BASE_VMS[@]}")
for fw in "${FIREWALL_VMS[@]}"; do
  STATE=$(sudo virsh domstate "$fw" 2>/dev/null)
  if [[ "$STATE" == "running" ]]; then
    echo "Detected active firewall: $fw"
    VMS_TO_STOP+=("$fw")
  fi
done

# Send graceful ACPI shutdown to all running lab VMs
RUNNING_VMS=()
for vm in "${VMS_TO_STOP[@]}"; do
  STATE=$(sudo virsh domstate "$vm" 2>/dev/null)
  if [[ "$STATE" == "running" ]]; then
    echo "Sending shutdown signal to '$vm'..."
    sudo virsh shutdown "$vm" >/dev/null
    RUNNING_VMS+=("$vm")
  else
    echo "VM '$vm' is already shut off."
  fi
done

# Poll until all VMs power off, or force-stop after timeout
if [[ ${#RUNNING_VMS[@]} -gt 0 ]]; then
  echo "Waiting up to ${SHUTDOWN_TIMEOUT}s for VMs to power off..."
  for ((i=1; i<=SHUTDOWN_TIMEOUT; i++)); do
    STILL_RUNNING=0
    for vm in "${RUNNING_VMS[@]}"; do
      STATE=$(sudo virsh domstate "$vm" 2>/dev/null)
      if [[ "$STATE" == "running" ]]; then
        STILL_RUNNING=1
        break
      fi
    done
    [[ $STILL_RUNNING -eq 0 ]] && break
    sleep 1
  done

  # Fallback for minimal guests (e.g., Alpine/OpenWrt without acpid) that ignore ACPI signals
  for vm in "${RUNNING_VMS[@]}"; do
    STATE=$(sudo virsh domstate "$vm" 2>/dev/null)
    if [[ "$STATE" == "running" ]]; then
      echo "VM '$vm' did not shut down in time; forcing power off..."
      sudo virsh destroy "$vm" >/dev/null
    fi
  done
fi

echo "All lab VMs are shut off."

# Stop virtual networks once all VMs are detached
for net in "${NETWORKS[@]}"; do
  ACTIVE=$(sudo virsh net-info "$net" 2>/dev/null | awk '/Active:/ {print $2}')
  if [[ "$ACTIVE" == "yes" ]]; then
    echo "Stopping network '$net'..."
    sudo virsh net-destroy "$net" >/dev/null
  else
    echo "Network '$net' is already inactive."
  fi
done

sudo virsh list --all
sudo virsh net-list --all
