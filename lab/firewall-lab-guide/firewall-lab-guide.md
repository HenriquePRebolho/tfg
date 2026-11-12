# Virtual Firewall Lab on KVM: Step-by-Step Guide

**Host:** Debian 13 (trixie) with KVM, libvirt, and QEMU
**Goal:** Build the lab architecture, prepare every virtual machine, and verify that the architecture works.
**Out of scope:** Firewall policy testing. That comes in a later stage.

---

## 0. How to use this guide

Follow the phases in order. Each phase ends with a **Checkpoint**. Do not move on until the checkpoint passes, because errors found later are much harder to trace back to their cause.

Commands are labelled with where they run:

| Label | Meaning |
|---|---|
| `[HOST]` | Your Debian terminal |
| `[VM: name]` | Inside a virtual machine. Open its console with `sudo virsh console name`. Leave the console with Ctrl+] |
| `[FIREWALL: name]` | Inside a firewall VM's console, same method as above |

To paste commands into a Linux terminal, use **Ctrl+Shift+V** (or right-click, then Paste). Plain Ctrl+V usually does nothing in a terminal.

Keep a notes file at `~/lab/notes/lab-notes.md`. Record each phase, any errors, and the output of the verification checks in Section 8. Those notes become the basis of your thesis appendix.

Replace any text in angle brackets, such as `<your-vyos-file>.iso`, with the real value on your system.

---

## 1. Architecture

### 1.1 Topology

```
  Zone 1: UNTRUSTED
  [Attacker: Kali]  10.10.1.100
        |
  ------+----  lab-untrusted  (bridge br-untr, 10.10.1.0/24)
        |
   WAN  eth0  10.10.1.1
   +------------------------------------------+
   |  FIREWALL under test                     |
   |  (one of: fw-nftables, fw-vyos,          |
   |   fw-ipfire, fw-openwrt)                 |
   +------------------------------------------+
   LAN  eth1  10.10.2.1          DMZ  eth2  10.10.3.1
        |                               |
  ------+----  lab-lan                  ------+----  lab-dmz
        |   (br-lan, 10.10.2.0/24)      |   (br-dmz, 10.10.3.0/24)
        |                               |
  [Client] 10.10.2.10            [Trusted server] 10.10.3.10
  Zone 2: INTERNAL               Zone 3: DMZ (known service)
```

### 1.2 Zones and addresses

| Zone | libvirt network | Bridge | Subnet | Machine | Address | Default gateway |
|---|---|---|---|---|---|---|
| Untrusted | `lab-untrusted` | `br-untr` | 10.10.1.0/24 | attacker (Kali) | 10.10.1.100 | 10.10.1.1 |
| Internal | `lab-lan` | `br-lan` | 10.10.2.0/24 | client | 10.10.2.10 | 10.10.2.1 |
| DMZ | `lab-dmz` | `br-dmz` | 10.10.3.0/24 | trusted server | 10.10.3.10 | 10.10.3.1 |

The firewall uses these addresses on its three interfaces: WAN `10.10.1.1`, LAN `10.10.2.1`, DMZ `10.10.3.1`.

### 1.3 MAC addresses

MAC addresses are fixed so that each network card can be recognised inside the operating system.

| Device | MAC address |
|---|---|
| attacker (Kali) | `52:54:00:10:00:01` |
| firewall WAN | `52:54:00:20:01:01` |
| firewall LAN | `52:54:00:20:01:02` |
| firewall DMZ | `52:54:00:20:01:03` |
| client | `52:54:00:30:00:01` |
| trusted server | `52:54:00:40:00:01` |

### 1.4 Design rules

1. The three bridges have no DHCP, no NAT, and no address on the host. The firewall VM is the only path between zones.
2. **Only one firewall VM runs at a time.** All four firewall VMs use the same MAC and IP addresses on the same bridges, so two running together cause address conflicts.
3. The three endpoints (client, trusted server, attacker) are shared by every firewall test.
4. Golden images are read-only templates. Never change one after overlays have been created from it.
5. Every VM has its own disk file. Two running VMs must never share one writable disk.
6. The lab has no internet access by design. Any internet route would create a path around the firewall.

---

## 2. Folder structure

### 2.1 On the host

```
~/lab/                          your files
├── xml/                        libvirt network definitions
├── cloud-init/                 cloud-init source files
├── downloads/                  downloaded images, ISOs, checksum files
└── notes/                      your records and verification output

/var/lib/libvirt/images/        managed by libvirt (VM disks and ISOs)
├── base/                       golden images (read-only templates)
├── iso/                        installer ISOs (VyOS, IPFire)
├── seeds/                      cloud-init seed ISOs (generated)
└── *.qcow2                     one disk file per VM
```

Disks belong in `/var/lib/libvirt/images/` because libvirt runs VMs as a separate system user, and AppArmor on Debian only lets it read and write disks in that folder. A disk stored in your home directory typically fails with "Permission denied".

### 2.2 Naming used in this guide

| Kind | Name pattern | Examples |
|---|---|---|
| Network | `lab-<zone>` | `lab-untrusted`, `lab-lan`, `lab-dmz` |
| Bridge | `br-<zone>` | `br-untr`, `br-lan`, `br-dmz` |
| Endpoint VM | role name | `client`, `trusted`, `attacker` |
| Firewall VM | `fw-<firewall>` | `fw-nftables`, `fw-vyos`, `fw-ipfire`, `fw-openwrt` |
| Disk | VM name plus `.qcow2` | `client.qcow2`, `fw-vyos.qcow2` |
| Seed | `seed-<vm>.iso` | `seed-client.iso` |

---

## 3. Tools

| Tool | Purpose | Documentation |
|---|---|---|
| bash | Terminal shell that runs commands and scripts | https://www.gnu.org/software/bash/manual/ |
| nano | Simple text editor in the terminal | https://www.nano-editor.org/docs.php |
| sudo | Runs a single command as administrator | https://www.sudo.ws/docs/ |
| wget | Downloads files | https://www.gnu.org/software/wget/manual/ |
| sha256sum, sha512sum | Verifies downloaded files against published checksums | https://www.gnu.org/software/coreutils/manual/ |
| KVM | Linux kernel virtualisation | https://www.linux-kvm.org/page/Documents |
| QEMU | Emulates the virtual hardware for each VM | https://www.qemu.org/docs/master/ |
| qemu-img | Creates, converts, and resizes disk images, and creates overlays | https://www.qemu.org/docs/master/tools/qemu-img.html (see "backing files") |
| libvirt | Daemon that manages VMs and networks | https://libvirt.org/docs.html |
| virsh | Command-line client for libvirt | https://libvirt.org/manpages/virsh.html |
| libvirt network XML | Format of the network definitions in `~/lab/xml/` | https://libvirt.org/formatnetwork.html |
| libvirt domain XML | Format of the VM definitions | https://libvirt.org/formatdomain.html |
| virt-install | Creates and starts VMs from the command line | https://virt-manager.org/ (also `man virt-install`) |
| virt-customize (libguestfs) | Edits a disk image without booting it | https://libguestfs.org/virt-customize.1.html |
| libguestfs | Library behind virt-customize | https://libguestfs.org/ |
| cloud-init | Configures a fresh Linux system on first boot | https://cloudinit.readthedocs.io/ |
| cloud-init NoCloud datasource | How seed ISOs are read | https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html |
| cloud-init network config v2 | Format of `network-config` files | https://cloudinit.readthedocs.io/en/latest/reference/network-config-format-v2.html |
| cloud-localds (cloud-utils) | Builds a seed ISO from the cloud-init files | https://github.com/canonical/cloud-utils |
| ip (iproute2) | Shows and changes addresses, routes, and links | https://wiki.linuxfoundation.org/networking/iproute2 |
| ping, traceroute | Reachability and path checks | `man ping`, `man traceroute` |
| curl | Requests web pages from the command line | https://curl.se/docs/ |
| nftables (nft) | Linux kernel firewall, used by the baseline firewall | https://wiki.nftables.org/ |
| conntrack | Shows and clears the firewall's connection table | https://conntrack-tools.netfilter.org/ |
| nginx | Web server on the trusted server | https://nginx.org/en/docs/ |
| tcpdump | Captures packets for inspection | https://www.tcpdump.org/ |
| nmap | Port scanner, installed on Kali and the golden image | https://nmap.org/book/man.html |
| iperf3 | Throughput measurement, used in the later testing stage | https://iperf.fr/ |
| hping3 | Packet crafting, used in the later testing stage | http://www.hping.org/ |
| nmcli (NetworkManager) | Sets the static address on Kali | `man nmcli` |
| 7z (p7zip) | Extracts the Kali `.7z` archive | `man 7z` |
| TigerVNC viewer | Shows a VM's graphical screen when needed | https://tigervnc.org/ |
| uci (OpenWrt) | Configures OpenWrt from the command line | https://openwrt.org/docs/guide-user/base-system/uci |
| draw.io (diagrams.net) | Draws the topology figure for the report | https://www.drawio.com/ |

---

## 4. Downloads

Download the files below into `~/lab/downloads/`. Release names change over time. If a file name below no longer matches, use the closest current file from the official page and keep a note of the exact name.

| Item | File | Official source |
|---|---|---|
| Debian 13 cloud image (golden base) | `debian-13-genericcloud-amd64.qcow2` and `SHA512SUMS` | https://cloud.debian.org/images/cloud/trixie/latest/ |
| Kali Linux QEMU image (attacker) | `kali-linux-<version>-qemu-amd64.7z` | https://www.kali.org/get-kali/ (Virtual Machines section) |
| VyOS rolling ISO | `vyos-rolling-latest.iso` or similar | https://vyos.io/ (rolling builds). LTS images require a subscription. |
| IPFire 2.29 ISO | `ipfire-2.29-core<NNN>-x86_64.iso` | https://www.ipfire.org/download |
| OpenWrt 25.12 x86-64 image (optional) | `openwrt-25.12.6-x86-64-generic-ext4-combined.img.gz` and `sha256sums` | https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/ |

### 4.1 Commands

```bash
# [HOST]
cd ~/lab/downloads

wget https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
wget https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS
sha512sum --ignore-missing -c SHA512SUMS

wget https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/openwrt-25.12.6-x86-64-generic-ext4-combined.img.gz
wget https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/sha256sums
sha256sum --ignore-missing -c sha256sums

# Extract the Kali archive (use the file name you downloaded)
7z x kali-linux-*-qemu-amd64.7z
ls ~/lab/downloads/*.qcow2

# Move the installer ISOs to the libvirt ISO folder
sudo mv ~/lab/downloads/vyos-*.iso ~/lab/downloads/ipfire-*.iso /var/lib/libvirt/images/iso/
```

Adjust the `mv` line if your ISO names differ.

**Checkpoint:** each checksum command prints `OK`. The Kali `.qcow2` file exists, and the two ISOs are in `/var/lib/libvirt/images/iso/`.

---

## 5. Virtual machines

| VM name | Role | Operating system | Disk file | Network | RAM / vCPU | Created in | Reused across tests |
|---|---|---|---|---|---|---|---|
| `client` | internal user | Debian 13 | overlay of `golden-debian13.qcow2` | `lab-lan` | 1 GB / 1 | Phase 7 | Yes |
| `trusted` | known web service | Debian 13 + nginx | overlay of `server-debian13.qcow2` | `lab-dmz` | 1 GB / 1 | Phase 7 | Yes |
| `attacker` | untrusted host | Kali Linux | copy of Kali `.qcow2` | `lab-untrusted` | 4 GB / 2 | Phase 7 | Yes |
| `fw-nftables` | baseline firewall | Debian 13 + nftables | overlay of `golden-debian13.qcow2` | 3 NICs | 2 GB / 2 | Phase 8 | No, one per firewall |
| `fw-vyos` | firewall appliance | VyOS | installed to empty disk | 3 NICs | 2 GB / 2 | Phase 8 | No |
| `fw-ipfire` | firewall appliance | IPFire 2.29 | installed to empty disk | 3 NICs | 2 GB / 2 | Phase 8 | No |
| `fw-openwrt` | firewall appliance (optional) | OpenWrt 25.12 | converted image | 3 NICs | 2 GB / 2 | Phase 8 | No |

**Total:** 3 endpoint VMs plus up to 4 firewall VMs.

**Base images:**

| File | Built from | Contents |
|---|---|---|
| `base/golden-debian13.qcow2` | Debian 13 cloud image | Test tools, serial console enabled |
| `base/server-debian13.qcow2` | copy of golden | Same, plus nginx |

**Overlay disks** (one per Debian VM, each file has its own name):

| Overlay file | Backed by |
|---|---|
| `client.qcow2` | `base/golden-debian13.qcow2` |
| `trusted.qcow2` | `base/server-debian13.qcow2` |
| `fw-nftables.qcow2` | `base/golden-debian13.qcow2` |

The Kali and appliance disks are not overlays. Each is a standalone file.

---

## 6. Key concepts

| Term | Meaning |
|---|---|
| Hypervisor | Software that runs virtual machines. Here, KVM with QEMU. |
| VM (guest) | A computer simulated in software, with its own disk, CPU, RAM, and network cards. |
| libvirt, virsh | libvirt manages VMs and networks. `virsh` is its command-line tool. |
| virtio | A fast driver type for virtual disks and network cards. |
| Bridge | A virtual network switch inside the host. Here, it connects the VM cards for one zone. |
| Isolated network | A libvirt network with no DHCP, NAT, or host routing. |
| MAC address | The hardware address of a network card. Fixed here so cards can be identified. |
| IP address, subnet | `10.10.2.10/24` means the address 10.10.2.10 in the network 10.10.2.0 with netmask 255.255.255.0. |
| Gateway, default route | Where a machine sends traffic for networks it does not directly reach. |
| IP forwarding | Lets a Linux machine pass packets between its interfaces. Required on the firewall. |
| Zone | A group of networks with the same trust level. Here: untrusted, internal, DMZ. |
| DUT | Device under test: the firewall being evaluated. |
| qcow2 | A disk file format that supports snapshots and backing files. |
| Golden image | A clean, read-only template that other disks are built from. |
| Overlay, backing file | A small disk file that stores only its changes. Its unchanged data is read from a backing file. |
| Snapshot | A saved state of a disk that you can return to. |
| cloud-init | Configures a new system from small text files on first boot. |
| Seed | The small ISO that carries cloud-init files to a VM. |
| Instance ID | cloud-init's identifier for a machine. It must change when the configuration changes, otherwise cloud-init skips it. |
| Serial console | A text console over a virtual serial port. It lets you use `virsh console` without a graphical screen. |
| VNC | A remote graphical display. Used here only for installers and first setup. |
| TTL | A counter in each packet. Each router decrements it, which is how traceroute finds the path. |

---

## 7. Build the lab

### Phase 0: Check the host hardware

```bash
# [HOST]
grep -Eo 'vmx|svm' /proc/cpuinfo | sort -u
ls -l /dev/kvm
```

**Checkpoint:** the first command prints `vmx` (Intel) or `svm` (AMD), and `/dev/kvm` exists.

**If `/dev/kvm` is missing** (the CPU supports virtualization, but the KVM module did not load):

```bash
# [HOST]
systemd-detect-virt                                       # "none" means a physical machine
lsmod | grep kvm                                          # kvm and kvm_intel (or kvm_amd) should be listed
sudo dmesg | grep -i -E 'kvm|vmx|svm'                     # look for "disabled by BIOS" messages
echo kvm_intel | sudo tee /etc/modules-load.d/kvm.conf    # use kvm_amd on AMD
sudo reboot
ls -l /dev/kvm                                            # after the reboot, the device must exist
```

If `systemd-detect-virt` prints anything other than `none`, the Debian host is itself a virtual machine, and nested virtualisation must be enabled in the hypervisor that runs it. If `dmesg` says virtualization is disabled by the BIOS, enable Intel VT-x or AMD-V in the firmware settings. Nested virtualisation is not needed on a physical host.

**If `journalctl -b -u systemd-modules-load.service` shows `deny-listed`**, a blacklist file is blocking the module. Find it with `grep -rn kvm /etc/modprobe.d/ /usr/lib/modprobe.d/`. Then rename the file so it is ignored, without deleting it:

```bash
# [HOST]
sudo mv /etc/modprobe.d/<file-you-found> /etc/modprobe.d/<file-you-found>.bak
sudo update-initramfs -u
sudo reboot
```

Only `.conf` files are read, so the `.bak` copy has no effect and can be restored later. Before you rename it, check whether you still need the software it was written for. A common reason to blacklist KVM is VirtualBox, which cannot use the virtualization hardware while KVM is loaded. The full diagnosis and the procedure for switching to VirtualBox are in Appendix A.

### Phase 1: Install the software

```bash
# [HOST]
sudo apt update
sudo apt install -y qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients \
  virtinst ovmf cloud-image-utils libguestfs-tools tigervnc-viewer p7zip-full wget

sudo usermod -aG libvirt,kvm "$USER"
echo 'export LIBVIRT_DEFAULT_URI=qemu:///system' >> ~/.bashrc
```

Log out and log back in, or reboot, so the group change takes effect. Then:

```bash
# [HOST]
sudo virt-host-validate qemu
sudo virsh list --all
```

**Checkpoint:** `virt-host-validate` reports `PASS` for the hardware virtualisation and KVM checks. `virsh list --all` runs without error. An empty list is normal at this point.

The `echo ... >> ~/.bashrc` command prints nothing when it succeeds, and so does `source ~/.bashrc`. Confirm the change with:

```bash
# [HOST]
grep LIBVIRT_DEFAULT_URI ~/.bashrc
echo $LIBVIRT_DEFAULT_URI                 # must print qemu:///system
```

### Phase 2: Create the folders

```bash
# [HOST]
mkdir -p ~/lab/{xml,cloud-init,downloads,notes}
sudo mkdir -p /var/lib/libvirt/images/{base,iso,seeds}
```

**Checkpoint:** `ls ~/lab` shows `cloud-init downloads notes xml`, and `ls /var/lib/libvirt/images` shows `base iso seeds`.

### Phase 3: Create the three isolated networks

Create the three network definition files:

```bash
# [HOST]
cat > ~/lab/xml/lab-untrusted.xml <<'EOF'
<network>
  <name>lab-untrusted</name>
  <bridge name='br-untr' stp='off' delay='0'/>
</network>
EOF

cat > ~/lab/xml/lab-lan.xml <<'EOF'
<network>
  <name>lab-lan</name>
  <bridge name='br-lan' stp='off' delay='0'/>
</network>
EOF

cat > ~/lab/xml/lab-dmz.xml <<'EOF'
<network>
  <name>lab-dmz</name>
  <bridge name='br-dmz' stp='off' delay='0'/>
</network>
EOF
```

Register and start them:

```bash
# [HOST]
for n in lab-untrusted lab-lan lab-dmz; do
  sudo virsh net-define ~/lab/xml/$n.xml
  sudo virsh net-autostart $n
  sudo virsh net-start $n
done
```

**Checkpoint:**

```bash
sudo virsh net-list --all
ip -br link show type bridge
```

All three `lab-*` networks show `active` and `yes` under Autostart. The bridges `br-untr`, `br-lan`, and `br-dmz` exist. Their state may show as `DOWN` until a VM is attached, which is normal.

### Phase 4: Prepare the golden images

#### 4.1 Golden Debian image

```bash
# [HOST]
sudo cp ~/lab/downloads/debian-13-genericcloud-amd64.qcow2 \
  /var/lib/libvirt/images/base/golden-debian13.qcow2

sudo virt-customize -a /var/lib/libvirt/images/base/golden-debian13.qcow2 \
  --install iperf3,nmap,hping3,tcpdump,curl,netcat-openbsd,dnsutils,traceroute,nftables,conntrack \
  --run-command 'systemctl enable serial-getty@ttyS0.service' \
  --run-command 'truncate -s 0 /etc/machine-id'
```

This edits the image without booting it. Downloading the packages needs internet on the host, and the command takes several minutes. The serial console line lets `virsh console` show a login prompt. The `machine-id` line makes every clone generate its own identity on first boot.

**Checkpoint:** the command finishes without an error message.

#### 4.2 Optional: Brazilian keyboard layout in Debian guests

Your host keyboard already produces the characters you type, because `virsh console` sends keystrokes as text. This step only affects a graphical (VNC) window inside Debian guests. Skip it unless you need it.

```bash
# [HOST]
sudo virt-customize -a /var/lib/libvirt/images/base/golden-debian13.qcow2 \
  --run-command "sed -i -e 's/^XKBLAYOUT=.*/XKBLAYOUT=\"br\"/' -e 's/^XKBVARIANT=.*/XKBVARIANT=\"abnt2\"/' /etc/default/keyboard"
```

If the command reports that `/etc/default/keyboard` does not exist, add `--install keyboard-configuration` to a separate `virt-customize` run first. Do this step only before any overlay is created from the golden image.

#### 4.3 Server image and read-only protection

```bash
# [HOST]
sudo cp /var/lib/libvirt/images/base/golden-debian13.qcow2 \
  /var/lib/libvirt/images/base/server-debian13.qcow2

sudo virt-customize -a /var/lib/libvirt/images/base/server-debian13.qcow2 \
  --install nginx-light

sudo chmod 444 /var/lib/libvirt/images/base/*.qcow2
```

**Checkpoint:** `ls -l /var/lib/libvirt/images/base/` shows both images with `-r--r--r--`.

### Phase 5: Write the cloud-init files and build the seeds

Create the working folder and the shared endpoint user file:

```bash
# [HOST]
cd ~/lab/cloud-init

cat > user-data.yaml <<'EOF'
#cloud-config
users:
  - name: lab
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: "lab"
ssh_pwauth: false
EOF
```

The password `lab` is weak on purpose. It is acceptable only because this network is isolated.

Create the per-VM files for the client and trusted server:

```bash
# [HOST]
cat > meta-data-client.yaml <<'EOF'
instance-id: client-001
local-hostname: client
EOF

cat > network-config-client.yaml <<'EOF'
version: 2
ethernets:
  lan0:
    match:
      macaddress: "52:54:00:30:00:01"
    set-name: lan0
    addresses: [10.10.2.10/24]
    routes:
      - to: 0.0.0.0/0
        via: 10.10.2.1
EOF

cat > meta-data-trusted.yaml <<'EOF'
instance-id: trusted-001
local-hostname: trusted
EOF

cat > network-config-trusted.yaml <<'EOF'
version: 2
ethernets:
  dmz0:
    match:
      macaddress: "52:54:00:40:00:01"
    set-name: dmz0
    addresses: [10.10.3.10/24]
    routes:
      - to: 0.0.0.0/0
        via: 10.10.3.1
EOF
```

Create the files for the nftables firewall. This VM has three network cards, and it needs IP forwarding switched on:

```bash
# [HOST]
cat > user-data-fw-nftables.yaml <<'EOF'
#cloud-config
users:
  - name: lab
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: "lab"
ssh_pwauth: false
write_files:
  - path: /etc/sysctl.d/99-forward.conf
    content: |
      net.ipv4.ip_forward=1
runcmd:
  - /usr/sbin/sysctl --system
  - /usr/bin/systemctl enable --now nftables
EOF

cat > meta-data-fw-nftables.yaml <<'EOF'
instance-id: fw-nftables-001
local-hostname: fw-nftables
EOF

cat > network-config-fw-nftables.yaml <<'EOF'
version: 2
ethernets:
  wan0:
    match:
      macaddress: "52:54:00:20:01:01"
    set-name: wan0
    addresses: [10.10.1.1/24]
  lan0:
    match:
      macaddress: "52:54:00:20:01:02"
    set-name: lan0
    addresses: [10.10.2.1/24]
  dmz0:
    match:
      macaddress: "52:54:00:20:01:03"
    set-name: dmz0
    addresses: [10.10.3.1/24]
EOF
```

Build the three seed ISOs:

```bash
# [HOST]
cloud-localds --network-config=network-config-client.yaml \
  /var/lib/libvirt/images/seeds/seed-client.iso user-data.yaml meta-data-client.yaml

cloud-localds --network-config=network-config-trusted.yaml \
  /var/lib/libvirt/images/seeds/seed-trusted.iso user-data.yaml meta-data-trusted.yaml

cloud-localds --network-config=network-config-fw-nftables.yaml \
  /var/lib/libvirt/images/seeds/seed-fw-nftables.iso \
  user-data-fw-nftables.yaml meta-data-fw-nftables.yaml
```

**Checkpoint:** `ls /var/lib/libvirt/images/seeds/` lists `seed-client.iso`, `seed-trusted.iso`, and `seed-fw-nftables.iso`.

Remember: cloud-init applies these files only on the first boot of a disk with that instance ID. If you change a file later, change the instance ID as well, or see the troubleshooting section.

### Phase 6: Create the endpoints

#### 6.1 Client

Create the overlay disk and the VM:

```bash
# [HOST]
sudo qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/base/golden-debian13.qcow2 \
  /var/lib/libvirt/images/client.qcow2 15G

sudo virt-install \
  --name client --memory 1024 --vcpus 1 \
  --cpu host-passthrough --machine q35 \
  --osinfo detect=on,require=off \
  --disk path=/var/lib/libvirt/images/client.qcow2,bus=virtio,cache=none,io=native,discard=unmap \
  --disk path=/var/lib/libvirt/images/seeds/seed-client.iso,device=cdrom \
  --network network=lab-lan,model=virtio,mac=52:54:00:30:00:01 \
  --memballoon none --rng /dev/urandom \
  --graphics none --console pty,target.type=serial \
  --import --noautoconsole
  --check mac_in_use=off
```

**Checkpoint:** wait two to three minutes for the first boot, then run:

```bash
# [HOST]
sudo virsh console client
```

Log in as `lab` / `lab`, and check:

```bash
# [VM: client]
ip -br addr
ip route
```

The address `10.10.2.10/24` is on `lan0`, and the default route goes via `10.10.2.1`. A ping to the gateway will fail until a firewall VM is running. That is expected.

#### 6.2 Trusted server

```bash
# [HOST]
sudo qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/base/server-debian13.qcow2 \
  /var/lib/libvirt/images/trusted.qcow2 15G

sudo virt-install \
  --name trusted --memory 1024 --vcpus 1 \
  --cpu host-passthrough --machine q35 \
  --osinfo detect=on,require=off \
  --disk path=/var/lib/libvirt/images/trusted.qcow2,bus=virtio,cache=none,io=native,discard=unmap \
  --disk path=/var/lib/libvirt/images/seeds/seed-trusted.iso,device=cdrom \
  --network network=lab-dmz,model=virtio,mac=52:54:00:40:00:01 \
  --memballoon none --rng /dev/urandom \
  --graphics none --console pty,target.type=serial \
  --import --noautoconsole
  --check mac_in_use=off
```

**Checkpoint:** log in with `sudo virsh console trusted` and run:

```bash
# [VM: trusted]
ip -br addr
systemctl is-active nginx
```

`dmz0` has `10.10.3.10/24`, and nginx reports `active`.

#### 6.3 Attacker (Kali Linux)

Kali is the attacker. It uses its own prepared image, so it does not use cloud-init.

```bash
# [HOST]
sudo cp ~/lab/downloads/kali-linux-*-qemu-amd64.qcow2 /var/lib/libvirt/images/attacker.qcow2

sudo virt-install \
  --name attacker --memory 4096 --vcpus 2 \
  --cpu host-passthrough --machine q35 \
  --osinfo detect=on,require=off \
  --disk path=/var/lib/libvirt/images/attacker.qcow2,bus=virtio,cache=none,io=native,discard=unmap \
  --network network=lab-untrusted,model=virtio,mac=52:54:00:10:00:01 \
  --graphics vnc,listen=127.0.0.1,port=5902 \
  --console pty,target.type=serial \
  --memballoon none --rng /dev/urandom \
  --import --noautoconsole
  --check mac_in_use=off
```

Kali's documentation lists the default login for its QEMU images and explains how to start the image. If the VM does not boot, check the boot mode in that documentation. Some Kali images need UEFI, in which case add `--boot uefi` after installing `ovmf`, which was done in Phase 1.

The first configuration is done through the graphical screen. Open it from the host:

```bash
# [HOST]
vncviewer 127.0.0.1:5902
```

In the Kali desktop, open a terminal and run:

```bash
# [VM: attacker, via VNC]
passwd                                    # change the default password
nmcli con show                            # note the name of the wired connection
nmcli device status                       # DEVICE must show the wired card, not "--"
sudo nmcli con mod "<connection name>" ipv4.method manual \
  ipv4.addresses 10.10.1.100/24 ipv4.gateway 10.10.1.1
sudo nmcli con up "<connection name>"
sudo systemctl enable --now serial-getty@ttyS0.service
```

Replace `<connection name>` with the name shown by `nmcli con show`.

**Checkpoint:** after the serial console is enabled, this works from the host:

```bash
# [HOST]
sudo virsh console attacker
```

Then inside Kali, `ip -br addr` shows `10.10.1.100/24`. Install `traceroute` if it is missing: `sudo apt install traceroute`.

### Phase 7: Create the firewalls

Each firewall gets its own VM with the same three network cards and MAC addresses. Build them one at a time. Before you start any firewall, make sure the others are shut down.

Every firewall uses the same MAC addresses, so libvirt refuses to define a second firewall while the first one still exists, even when it is shut off. The error reads `The MAC address ... is in use by another virtual machine`. This check protects against accidental conflicts, but the shared MACs are intentional here, because only one firewall runs at a time. For `fw-vyos`, `fw-ipfire`, and `fw-openwrt`, add `--check mac_in_use=off` as the last option of the `virt-install` command. Do not use `--check all=off`, because that disables the other safety checks too. Never start two firewall VMs at once, and check with `sudo virsh list` before each start.

#### 7.1 fw-nftables (the baseline firewall)

This is the easiest firewall to build. Debian and cloud-init already set up the addresses and forwarding.

```bash
# [HOST]
sudo qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/base/golden-debian13.qcow2 \
  /var/lib/libvirt/images/fw-nftables.qcow2 15G

sudo virt-install \
  --name fw-nftables --memory 2048 --vcpus 2 \
  --cpu host-passthrough --machine q35 \
  --osinfo detect=on,require=off \
  --disk path=/var/lib/libvirt/images/fw-nftables.qcow2,bus=virtio,cache=none,io=native,discard=unmap \
  --disk path=/var/lib/libvirt/images/seeds/seed-fw-nftables.iso,device=cdrom \
  --network network=lab-untrusted,model=virtio,mac=52:54:00:20:01:01 \
  --network network=lab-lan,model=virtio,mac=52:54:00:20:01:02 \
  --network network=lab-dmz,model=virtio,mac=52:54:00:20:01:03 \
  --memballoon none --rng /dev/urandom \
  --graphics none --console pty,target.type=serial \
  --import --noautoconsole
```

**Checkpoint:**

```bash
# [VM: fw-nftables]
ip -br addr                  # wan0, lan0 and dmz0 with 10.10.1.1, 10.10.2.1, 10.10.3.1
cat /proc/sys/net/ipv4/ip_forward   # must print 1
sudo nft list ruleset        # empty, because no rules exist yet
```

Shut it down before starting the next firewall:

```bash
# [HOST]
sudo virsh shutdown fw-nftables
```

#### 7.2 fw-vyos

VyOS is installed from its ISO onto an empty disk. The disk is empty on first boot, so the virtual firmware falls through to the ISO. After installation, the disk boots first.

```bash
# [HOST]
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/fw-vyos.qcow2 8G

sudo virt-install \
  --name fw-vyos --memory 2048 --vcpus 2 \
  --cpu host-passthrough --machine q35 \
  --osinfo detect=on,require=off \
  --disk path=/var/lib/libvirt/images/fw-vyos.qcow2,bus=virtio,cache=none,io=native,discard=unmap \
  --cdrom /var/lib/libvirt/images/iso/<your-vyos-file>.iso \
  --network network=lab-untrusted,model=virtio,mac=52:54:00:20:01:01 \
  --network network=lab-lan,model=virtio,mac=52:54:00:20:01:02 \
  --network network=lab-dmz,model=virtio,mac=52:54:00:20:01:03 \
  --boot hd,cdrom --memballoon none --rng /dev/urandom \
  --graphics none --console pty,target.type=serial --noautoconsole
```

If the console stays blank during installation, stop the VM with `sudo virsh destroy fw-vyos`, change `--graphics none --console pty,target.type=serial` to `--graphics vnc,listen=127.0.0.1,port=5903`, and run the command again with `--graphics vnc`. Connect with `vncviewer 127.0.0.1:5903`. Use this only for installation. Port 5903 is used so it does not clash with the Kali (5902) or IPFire (5901) displays.

Install VyOS:

```bash
# [HOST]
sudo virsh console fw-vyos
```

Log in on the live system with `vyos` / `vyos`, then run:

```text
# [FIREWALL: fw-vyos, live system]
install image
```

Follow the prompts. The installer lists only the disks attached to this VM. You should see one disk, `/dev/vda`, about 8 GB, which is the empty file `fw-vyos.qcow2`. Your host's disks are not attached to the VM, so the installer cannot see them. Answer `y` to erase that virtual disk. Set a password for the `vyos` user, and reboot when asked. After the reboot, log in with the password you chose.

Identify the interfaces and their MAC addresses:

```text
# [FIREWALL: fw-vyos]
show interfaces
```

Match each `ethN` name to its MAC address. The MACs should be `52:54:00:20:01:01`, `...:02`, and `...:03`. If the names are in a different order, adjust the lines below so that WAN, LAN, and DMZ use the interfaces whose MACs match.

Configure the three interfaces:

```text
# [FIREWALL: fw-vyos]
configure
set system host-name fw-vyos
set interfaces ethernet eth0 address 10.10.1.1/24
set interfaces ethernet eth0 description WAN
set interfaces ethernet eth1 address 10.10.2.1/24
set interfaces ethernet eth1 description LAN
set interfaces ethernet eth2 address 10.10.3.1/24
set interfaces ethernet eth2 description DMZ
commit
save
exit
show interfaces
```

**Checkpoint:** `show interfaces` lists the three interfaces with their addresses. The VyOS documentation covers the CLI in more depth. Leave the configuration without any firewall rules, because policy is part of the later testing stage.

Shut it down before the next step:

```bash
# [HOST]
sudo virsh shutdown fw-vyos
```

#### 7.3 fw-ipfire

IPFire is also installed from its ISO. It uses colour names for its zones: RED is the untrusted (WAN) side, GREEN is the internal (LAN) side, and ORANGE is the DMZ.

```bash
# [HOST]
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/fw-ipfire.qcow2 8G

sudo virt-install \
  --name fw-ipfire --memory 2048 --vcpus 2 \
  --cpu host-passthrough --machine q35 \
  --osinfo detect=on,require=off \
  --disk path=/var/lib/libvirt/images/fw-ipfire.qcow2,bus=virtio,cache=none,io=native,discard=unmap \
  --cdrom /var/lib/libvirt/images/iso/<your-ipfire-file>.iso \
  --network network=lab-untrusted,model=virtio,mac=52:54:00:20:01:01 \
  --network network=lab-lan,model=virtio,mac=52:54:00:20:01:02 \
  --network network=lab-dmz,model=virtio,mac=52:54:00:20:01:03 \
  --boot hd,cdrom --memballoon none --rng /dev/urandom \
  --graphics vnc,listen=127.0.0.1,port=5901 --noautoconsole
```

The IPFire installer is text-based and runs on the graphical screen, so open it with:

```bash
# [HOST]
vncviewer 127.0.0.1:5901
```

Follow the installer. Its exact screens vary by version. Set a root password and an admin password when asked. When it asks you to assign network cards, use these MAC addresses:

| Colour | MAC address |
|---|---|
| RED (WAN) | `52:54:00:20:01:01` |
| GREEN (LAN) | `52:54:00:20:01:02` |
| ORANGE (DMZ), configured later | `52:54:00:20:01:03` |

If the installer asks for the GREEN address, enter `10.10.2.1/24`. Reboot when it finishes.

The web interface runs on port 444 of the GREEN address. The host has no address in the lab, so give it a temporary one on the LAN bridge:

```bash
# [HOST]
sudo ip addr add 10.10.2.254/24 dev br-lan
```

If the installer chose a different GREEN subnet, use that subnet for the temporary address instead. Open `https://10.10.2.1:444` in a browser on the host. Accept the self-signed certificate warning, and log in as `admin` with the password you set.

In the web interface, configure the network settings to match the plan:

| Colour | Address | Notes |
|---|---|---|
| GREEN | `10.10.2.1/24` | Set during installation or in the web interface |
| RED | `10.10.1.1/24`, static, gateway `10.10.1.254` | The installer requires a gateway for static RED. Use `10.10.1.254`, a placeholder that no VM uses. Nothing answers there, so the lab has no internet route. Do not use the attacker's address or the firewall's own address. |
| ORANGE | `10.10.3.1/24`, static | Assign it to the DMZ card's MAC |

Menu names differ between versions. Look in the network configuration section.

Remove the temporary host address when you finish:

```bash
# [HOST]
sudo ip addr del 10.10.2.254/24 dev br-lan
```

**Checkpoint:** from the IPFire console (`sudo virsh console fw-ipfire` also works if serial output is enabled; otherwise use the VNC window), `ip -br addr` shows the three addresses. Then shut it down:

```bash
# [HOST]
sudo virsh shutdown fw-ipfire
```

#### 7.4 fw-openwrt (optional)

OpenWrt is a ready-made disk image, so it needs no installation.

```bash
# [HOST]
cd ~/lab/downloads
gunzip -k openwrt-25.12.6-x86-64-generic-ext4-combined.img.gz

sudo qemu-img convert -f raw -O qcow2 \
  openwrt-25.12.6-x86-64-generic-ext4-combined.img \
  /var/lib/libvirt/images/fw-openwrt.qcow2
sudo qemu-img resize /var/lib/libvirt/images/fw-openwrt.qcow2 2G

sudo virt-install \
  --name fw-openwrt --memory 2048 --vcpus 2 \
  --cpu host-passthrough --machine q35 \
  --osinfo detect=on,require=off \
  --disk path=/var/lib/libvirt/images/fw-openwrt.qcow2,bus=virtio,cache=none,io=native,discard=unmap \
  --network network=lab-untrusted,model=virtio,mac=52:54:00:20:01:01 \
  --network network=lab-lan,model=virtio,mac=52:54:00:20:01:02 \
  --network network=lab-dmz,model=virtio,mac=52:54:00:20:01:03 \
  --boot hd --memballoon none --rng /dev/urandom \
  --graphics none --console pty,target.type=serial \
  --import --noautoconsole
```

Open the console and log in as `root`. A fresh OpenWrt image has no root password, so set one:

```bash
# [HOST]
sudo virsh console fw-openwrt
```

```sh
# [FIREWALL: fw-openwrt]
passwd
ip -br link                   # map eth0, eth1, eth2 to the MAC addresses above
uci show network              # review the default layout before changing it
```

Configure the addresses with UCI. The default layout puts `eth0` into the LAN bridge, so the ports must change:

```sh
# [FIREWALL: fw-openwrt]
uci set network.lan.ipaddr='10.10.2.1'
uci set network.lan.netmask='255.255.255.0'

uci set network.wan.proto='static'
uci set network.wan.device='eth0'
uci set network.wan.ipaddr='10.10.1.1'
uci set network.wan.netmask='255.255.255.0'

uci set network.dmz='interface'
uci set network.dmz.proto='static'
uci set network.dmz.device='eth2'
uci set network.dmz.ipaddr='10.10.3.1'
uci set network.dmz.netmask='255.255.255.0'

# Replace eth0 with eth1 in the LAN bridge (check the device index with uci show network)
uci del_list network.@device[0].ports='eth0'
uci add_list network.@device[0].ports='eth1'

uci commit network
/etc/init.d/network restart
```

Review `uci show network` before the commit if your defaults differ. OpenWrt's firewall zones for the DMZ are policy, so they belong to the later testing stage. The routing checks in Section 8 still work without them.

**Checkpoint:** `ip -br addr` shows the three addresses. Shut it down before continuing:

```bash
# [HOST]
sudo virsh shutdown fw-openwrt
```

---

## 8. Verify the architecture

This section proves that the wiring, addressing, and routing are correct. It does **not** test security policy. A successful ping only shows that packets can reach the destination, not that the firewall should allow them.

Run the checks for one firewall at a time. Start the firewall you are checking, make sure the others are shut down, and start the three endpoints:

```bash
# [HOST]
sudo virsh start fw-nftables     # or fw-vyos, fw-ipfire, fw-openwrt
sudo virsh start client
sudo virsh start trusted
sudo virsh start attacker
```

Give the VMs one to two minutes to boot. Then work through the checks below.

### 8.1 Host checks

| # | Command | Expected result |
|---|---|---|
| H1 | `sudo virsh net-list --all` | Three `lab-*` networks are `active`, autostart `yes` |
| H2 | `ip -br link show type bridge` | `br-untr`, `br-lan`, `br-dmz` exist |
| H3 | `ip -br addr` | No `10.10.x.x` address on the host (unless you added the temporary IPFire address) |
| H4 | `sudo virsh list` | Three endpoints and exactly one firewall are running |

### 8.2 Endpoint addressing

Run each command inside the VM.

| # | VM | Command | Expected result |
|---|---|---|---|
| E1 | client | `ip -br addr` | `lan0` with `10.10.2.10/24` |
| E2 | client | `ip route` | `default via 10.10.2.1` |
| E3 | trusted | `ip -br addr` | `dmz0` with `10.10.3.10/24` |
| E4 | trusted | `ip route` | `default via 10.10.3.1` |
| E5 | attacker | `ip -br addr` | `10.10.1.100/24` on the wired interface |
| E6 | attacker | `ip route` | `default via 10.10.1.1` |

### 8.3 Gateway reachability

Each endpoint should reach its own gateway, which is a firewall interface in the same zone.

| # | VM | Command | Expected result |
|---|---|---|---|
| G1 | client | `ping -c 3 -W 2 10.10.2.1` | 0% packet loss |
| G2 | trusted | `ping -c 3 -W 2 10.10.3.1` | 0% packet loss |
| G3 | attacker | `ping -c 3 -W 2 10.10.1.1` | 0% packet loss |

If G1 to G3 fail, check the firewall's addresses (Section 7) and that the firewall VM is running. Also check the interface names and MAC mapping.

### 8.4 The firewall is in the path

Traceroute shows each router a packet passes through. The first hop must be the firewall's address on the source side. This check works even if the firewall later blocks the traffic. The TTL counter is checked before the firewall's forwarding rules run, so the first hop always answers.

| # | VM | Command | Expected result |
|---|---|---|---|
| P1 | client | `traceroute -n 10.10.3.10` | Hop 1 is `10.10.2.1`, then the destination `10.10.3.10` |
| P2 | attacker | `traceroute -n 10.10.2.10` | Hop 1 is `10.10.1.1`, then `10.10.2.10` |
| P3 | trusted | `traceroute -n 10.10.2.10` | Hop 1 is `10.10.3.1`, then `10.10.2.10` |

### 8.5 Cross-zone reachability

These checks confirm that routing works through the firewall. They are not policy tests.

| # | VM | Command | Expected result |
|---|---|---|---|
| R1 | client | `ping -c 3 -W 2 10.10.3.10` | Success, or blocked by the firewall's default policy |
| R2 | client | `curl -sI http://10.10.3.10 \| head -n 1` | `HTTP/1.1 200 OK` from nginx |
| R3 | attacker | `ping -c 3 -W 2 10.10.2.10` | Success, or blocked by the firewall's default policy |

If R1 to R3 fail, first confirm that P1 to P3 pass. Then look at the firewall's default forwarding policy. Note the result in your lab notes. Policy changes belong to the testing stage, so do not change rules just to make these checks pass. Note that nftables and VyOS start with no rules, so their routing normally passes these checks. IPFire and OpenWrt have default policies that you need to inspect.

### 8.6 Isolation

| # | VM | Command | Expected result |
|---|---|---|---|
| I1 | client | `ping -c 2 -W 2 1.1.1.1` | 100% packet loss, because there is no internet route |
| I2 | host | `ping -c 1 -W 1 10.10.2.10` | Fails, because the host is not on the lab network |

### 8.7 Forwarding and tools

| # | VM | Command | Expected result |
|---|---|---|---|
| T1 | fw-nftables | `cat /proc/sys/net/ipv4/ip_forward` | `1` |
| T2 | client | `iperf3 --version`, `nmap --version`, `hping3 --version` | Each prints a version |
| T3 | attacker | `nmap --version`, `hping3 --version` | Each prints a version |

VyOS and OpenWrt forward packets once their interfaces have addresses. Their routing is confirmed by checks P1 to P3.

### 8.8 Console and reset

| # | Check | Command | Expected result |
|---|---|---|---|
| C1 | Console access | `sudo virsh console client`, then log in | Login works. Leave with Ctrl+] |
| C2 | Overlay reset works | Reset the client as in Section 9.2, then repeat E1 and E2 | Same addresses as before |

### 8.9 Record the results

Save the output of each check in `~/lab/notes/verification-<firewall>.md`, with the date. Mark each check as passed, failed, or explained. For a check that failed, write down the cause. Those results are your evidence that the architecture works.

---

## 9. Snapshots and resets

### 9.1 Firewalls: take a snapshot after configuration

Shut the firewall down, confirm that it is off, and take the snapshot:

```bash
# [HOST]
sudo virsh shutdown fw-vyos
sudo virsh domstate fw-vyos          # wait until it says "shut off"
sudo virsh snapshot-create-as fw-vyos configured "addressing done, no policy"
sudo virsh snapshot-list fw-vyos
```

Restore it later with:

```bash
# [HOST]
sudo virsh snapshot-revert fw-vyos configured
```

Repeat for each firewall after its configuration is complete. When you change the firewall's configuration later, take a new snapshot with a different name. Keep the old one.

### 9.2 Endpoints: recreate the overlay

For endpoints, replacing the overlay is simpler than using snapshots. It returns the VM to exactly the state produced by cloud-init.

```bash
# [HOST]
sudo virsh destroy client                        # force power-off, not deletion
sudo rm /var/lib/libvirt/images/client.qcow2
sudo qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/base/golden-debian13.qcow2 \
  /var/lib/libvirt/images/client.qcow2 15G
sudo virsh start client
```

Use the same procedure for `trusted` (with `server-debian13.qcow2`) and `fw-nftables` (with `golden-debian13.qcow2`). Their seeds are unchanged, so cloud-init applies the same configuration.

### 9.3 The golden image rule

Never change `base/golden-debian13.qcow2` or `base/server-debian13.qcow2` while overlays exist. Overlays read unchanged data from the base, so a changed base silently damages them. If you must change a base image, delete its overlays first, change the base, and recreate the overlays.

---

## 10. Daily use

After a reboot, the networks start by themselves. The VMs do not. Start the one firewall you need and the endpoints:

```bash
# [HOST]
sudo virsh net-list --all                  # networks should be active
sudo virsh start fw-nftables               # or the firewall you are using
sudo virsh start client
sudo virsh start trusted
sudo virsh start attacker
sudo virsh list
```

To stop everything cleanly:

```bash
# [HOST]
for vm in attacker trusted client fw-nftables fw-vyos fw-ipfire fw-openwrt; do
  sudo virsh shutdown "$vm" 2>/dev/null
done
sudo virsh list
```

To keep the networks running (recommended) or to turn autostart off:

```bash
# [HOST]
sudo virsh net-autostart --disable lab-lan      # repeat for each network
```

Stopping a network with `sudo virsh net-destroy lab-lan` does not delete it. Starting it again with `net-start` restores it.

---

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `virsh` says "Permission denied" | Your user is not in the `libvirt` group yet | Log out and back in after `usermod`, or reboot |
| VM will not start, error mentions the network | The lab network is stopped | `sudo virsh net-start lab-<zone>` |
| `virsh console` shows nothing | Serial login is not enabled in that VM | Use VNC for that VM, or re-run `virt-customize` on the image before creating overlays |
| Endpoint has no `10.10.x.x` address after boot | Wrong MAC in the VM definition or in `network-config`, or cloud-init did not run | Compare MACs in Section 1.3. Run `sudo cloud-init status` inside the VM. Recreate the overlay if needed |
| Changed a seed file, but nothing changed | Same `instance-id`, so cloud-init skipped the file | Rebuild the seed ISO with `cloud-localds`, then recreate the overlay as in Section 9.2. The VM must not be running during the rebuild. Changing the instance ID or running `sudo cloud-init clean --logs` inside the VM also makes cloud-init run again |
| Ping to gateway fails | Firewall VM not running, or its address is not set | `sudo virsh list`. Check the firewall's interface addresses |
| Ping fails with `Network unreachable` | Missing default route on the endpoint | `ip route` inside the VM. Check the gateway in the network config |
| Two firewalls cause odd results | Two firewall VMs are running with the same addresses | `sudo virsh shutdown` the one you are not using |
| `virt-customize` fails with a libguestfs error | The appliance cannot run | Run `sudo libguestfs-test-tool` and read its output. The libguestfs documentation covers this |
| Overlay VM boots with damaged files | Golden image was changed after the overlay was created | Recreate the overlay as in Section 9.2. Follow the rule in Section 9.3 |
| Kali will not boot | Boot mode differs from what the image expects | Check Kali's documentation for the image. Try `--boot uefi` if it uses UEFI |
| Firewall rule seems to apply to the wrong zone | Interface names differ from the plan | Use the MAC addresses in Section 1.3 to identify each interface |
| traceroute shows no hops | Gateway not set, or firewall not running | Check `ip route` on the endpoint and the firewall's addresses |
| IPFire web page does not open | Temporary host address missing, or wrong subnet | Add the address from Section 7.3 and try again |
| `nmcli con up` fails, or the DEVICE column shows `--` | The connection is not bound to the wired card, or the card is unmanaged | Run `nmcli device status`. Bind the connection with `sudo nmcli con mod "<name>" connection.interface-name <device>`, then `sudo nmcli con up "<name>"`. Never edit `lo`, which is the loopback interface |
| `sudo cloud-init schema --system` reports `Additional properties are not allowed ('<key>' was unexpected)` | A key in `user-data` is misspelled, for example `ssh_pwaut` instead of `ssh_pwauth`. Cloud-init ignores the bad key, so the rest of the file still runs | Find the key with `grep -n -i 'ssh_pw' ~/lab/cloud-init/*.yaml`, correct the spelling, rebuild the seed, and recreate the overlay |
| `runcmd: ... systemctl: not found` in `/var/log/cloud-init-output.log`, and the service is `inactive` | cloud-init ran the command with a PATH that does not include the command | Use the absolute path, such as `/usr/bin/systemctl`, in `runcmd`. Check the path with `command -v systemctl` inside the VM |
| `sysctl: command not found` when run as the `lab` user | `sysctl` is in `/usr/sbin`, which normal users do not have in their PATH | Use `cat /proc/sys/net/ipv4/ip_forward` to read the value, or `sudo sysctl` to change it. Nothing is broken |
| `ERROR The MAC address '52:54:00:20:01:..' is in use by another virtual machine` when creating a firewall | A previous firewall VM still exists and uses the same MAC, which is intentional in this lab | Add `--check mac_in_use=off` to the `virt-install` command. Keep only one firewall running |
| `WARNING Failed to detect osinfo OS name from install media` | The ISO has no OS metadata | Harmless. virt-install uses a generic profile, which is fine for VyOS, IPFire, and OpenWrt |
| IPFire will not accept a static RED address without a gateway | The installer requires a gateway for static RED | Enter `10.10.1.254` as the gateway. It must be in the RED subnet, and no VM may use it. This is the lab's placeholder upstream |
| `virt-host-validate` reports `/dev/kvm` FAIL | KVM module blocked by a blacklist file, not loaded at boot, or virtualization disabled in firmware | Phase 0, block "If `/dev/kvm` is missing". Do not enable nested virtualisation on a physical host |
| `modprobe: command not found` when run without `sudo` | Debian keeps `modprobe` in `/usr/sbin`, which normal users do not have in their PATH | Use `sudo modprobe ...`. Nothing is broken |
| VirtualBox reports that VT-x is unavailable or in use | KVM is loaded while the lab VMs are running | Shut down the lab VMs, then `sudo modprobe -r kvm_intel`. Follow Appendix A.9 to switch modes |

---

## 12. References

### Virtualisation: learning the basics

- Arch Wiki, Libvirt: https://wiki.archlinux.org/title/Libvirt (clear explanations of libvirt, networks, and VM management, even though it is not Debian-specific)
- Arch Wiki, QEMU: https://wiki.archlinux.org/title/QEMU
- Debian Wiki, KVM: https://wiki.debian.org/KVM
- Debian Wiki, Cloud images: https://wiki.debian.org/Cloud
- Debian Cloud image index: https://cloud.debian.org/images/cloud/
- Linux KVM documentation: https://www.linux-kvm.org/page/Documents

### Disks, overlays, golden images, and snapshots

- qemu-img manual, including backing files and overlays: https://www.qemu.org/docs/master/tools/qemu-img.html
- QEMU documentation, index: https://www.qemu.org/docs/master/
- libvirt, storage and snapshots: https://libvirt.org/docs.html
- libguestfs and virt-customize: https://libguestfs.org/

### Cloud-init

- Main documentation: https://cloudinit.readthedocs.io/
- NoCloud datasource (how seed ISOs work): https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
- Network configuration format version 2: https://cloudinit.readthedocs.io/en/latest/reference/network-config-format-v2.html
- Command line reference (includes `clean`): https://cloudinit.readthedocs.io/en/latest/reference/cli.html
- cloud-utils (cloud-localds): https://github.com/canonical/cloud-utils

### Keyboard layout (Brazilian ABNT2)

- Debian keyboard configuration: https://wiki.debian.org/Keyboard
- X Keyboard Extension configuration database, which lists the `br` layout and its `abnt2` variant: https://www.xkeyboard-config.org/

### Networking

- Linux IP sysctl settings, including forwarding: https://docs.kernel.org/networking/ip-sysctl.html
- iproute2 (the `ip` command): https://wiki.linuxfoundation.org/networking/iproute2
- Debian Reference, networking chapters: https://www.debian.org/doc/manuals/debian-reference/
- Bridges and isolated networks in libvirt: https://libvirt.org/formatnetwork.html

### Firewalls

- nftables wiki: https://wiki.nftables.org/
- Netfilter connection tracking tools: https://conntrack-tools.netfilter.org/
- VyOS documentation: https://docs.vyos.io/
- IPFire documentation: https://www.ipfire.org/docs
- OpenWrt documentation: https://openwrt.org/docs/start
- OpenWrt firewall guide: https://openwrt.org/docs/guide-user/firewall/start
- OpenWrt UCI reference: https://openwrt.org/docs/guide-user/base-system/uci

### Attacker and tools

- Kali Linux documentation, including virtualisation and QEMU images: https://www.kali.org/docs/
- Kali Linux downloads: https://www.kali.org/get-kali/
- nmap reference guide: https://nmap.org/book/man.html
- hping3: http://www.hping.org/
- tcpdump: https://www.tcpdump.org/
- curl: https://curl.se/docs/

### Background research for the thesis

- Google Scholar: https://scholar.google.com/ (search for terms such as "open source firewall performance evaluation", "nftables iptables performance comparison", and "virtualized firewall benchmark")

### Writing and figures

- draw.io (diagrams.net): https://www.drawio.com/

---

**Note on links:** these addresses were compiled from the projects' published documentation structure. If one has moved, search the project name on the official site. Release file names change often, so check the exact names on each download page before you use the commands in Section 4.

---

## Appendix A: Hypervisor troubleshooting and switching between KVM and VirtualBox

KVM (the lab) and VirtualBox both use the CPU's virtualization hardware (Intel VT-x or AMD-V). Only one hypervisor can use it at a time. This appendix explains how to diagnose a missing `/dev/kvm`, and how to switch between the two.

### A.1 How the pieces fit together

KVM is provided by the `kvm_intel` module on Intel CPUs and `kvm_amd` on AMD CPUs. Loading it creates `/dev/kvm`, which the lab uses. Two mechanisms load it:

- **Automatic loading at boot.** Udev matches your CPU against the module aliases listed by `modprobe -c`. Those long alias lines are normal. They are the reason `kvm_intel` loads by itself, even without `/etc/modules-load.d/kvm.conf`.
- **Manual loading.** `sudo modprobe kvm_intel` loads the module at any time.

A **blacklist** entry blocks automatic loading, but not a manual `modprobe`. The file `/etc/modprobe.d/blacklist-kvm.conf` is the only mechanism that stops KVM at boot. Removing `kvm.conf` is not enough, because of the alias mechanism above.

The two states are:

| Mode | Blacklist file | KVM at boot | Used for |
|---|---|---|---|
| Lab mode | absent (kept as `blacklist-kvm.conf.bak`) | loads automatically | the KVM lab |
| VirtualBox mode | present | blocked | VirtualBox |

Check the current mode at any time:

```bash
# [HOST]
ls /etc/modprobe.d/blacklist-kvm.conf 2>/dev/null && echo "VirtualBox mode (KVM blocked)" || echo "Lab mode (KVM allowed)"
lsmod | grep -E 'kvm|vbox'
ls -l /dev/kvm
```

### A.2 Diagnosing a missing `/dev/kvm`

**Step 1: Is the host physical or a virtual machine?**

```bash
systemd-detect-virt
```

`none` means a physical machine, which is the normal case for this lab. Any other answer means the Debian host is itself a VM. Nested virtualisation is then required in the outer hypervisor. See A.7.

**Step 2: Is the module loaded?**

```bash
lsmod | grep kvm
ls -l /dev/kvm
```

In lab mode, `kvm` and `kvm_intel` are listed, and `/dev/kvm` exists with group `kvm`.

**Step 3: What happened at boot?**

```bash
sudo journalctl -b -u systemd-modules-load.service --no-pager | grep -i kvm
sudo dmesg | grep -i -E 'kvm|vmx|svm|virtualiz'
```

| Message | Meaning | Action |
|---|---|---|
| `Inserted module 'kvm_intel'` | Loaded correctly at boot | None |
| `Module 'kvm_intel' is deny-listed (by kmod)` | A blacklist entry is blocking it | Go to A.3 |
| `disabled by BIOS`, or an error mentioning VMX and the BIOS | Virtualization is off in the firmware | Go to A.4 |
| `DMAR: Intel(R) Virtualization Technology for Directed I/O` | Information about the IOMMU (VT-d). Not a fault | None |
| Nothing about KVM | The module was never tried | Go to A.5 |

**Step 4: Find the blacklist.**

```bash
grep -rn -i 'kvm' /etc/modprobe.d/ /usr/lib/modprobe.d/ /run/modprobe.d/ 2>/dev/null
sudo modprobe -c | grep -i '^blacklist' | grep -i kvm
```

In lab mode, the second command prints nothing. The `blacklist` lines for framebuffer drivers and `microcode` are distribution defaults and can be ignored.

Note that `modprobe` must be run with `sudo`. Debian keeps it in `/usr/sbin`, which normal users do not have in their PATH. Running it without `sudo` produces `modprobe: command not found`, and nothing is broken.

### A.3 Removing a blacklist for lab mode

Rename the file rather than deleting it. Only files ending in `.conf` are read, so the `.bak` copy has no effect, and it can be restored later:

```bash
# [HOST]
sudo mv /etc/modprobe.d/blacklist-kvm.conf /etc/modprobe.d/blacklist-kvm.conf.bak
sudo update-initramfs -u
sudo reboot
```

After the reboot, check that `/dev/kvm` exists and that the journal shows `Inserted module 'kvm_intel'`.

### A.4 Firmware (BIOS or UEFI) settings

Enter the firmware settings during boot, using the key your computer shows (often Del, F2, or F10). Then:

1. Enable **Intel Virtualization Technology** (VT-x). On AMD, enable **SVM Mode**.
2. Leave VT-d (IOMMU) at its default. It is not required for this lab.
3. Save with the explicit "Save and Exit" option. Some firmware discards changes if you exit another way.
4. If your board has a security feature such as Intel TXT, check the firmware documentation. Some boards lock virtualization settings behind it.

If you enabled the setting and the module still fails, try the firmware's optimised defaults, then enable VT-x again and save.

### A.5 Testing a manual load

```bash
# [HOST]
sudo modprobe kvm_intel
ls -l /dev/kvm
```

| Result | Meaning | What to do |
|---|---|---|
| Succeeds, and `/dev/kvm` appears | Firmware is fine. Only the automatic loading is failing | Check A.2 Step 3, then A.6 |
| `Operation not supported`, or `No such device` | Firmware is blocking VMX | Go to A.4 |
| `Key was rejected`, or `unavailable key` | Secure Boot is rejecting the module | Run `sudo apt install mokutil`, then `mokutil --sb-state`. If Secure Boot is on, disable it in the firmware |
| `Module kvm_intel not found` | The kernel does not include KVM | Run `modinfo kvm_intel` and `uname -r`. Install the standard kernel with `sudo apt install linux-image-amd64`, then reboot |

### A.6 Making the module load at boot

For an explicit load on every boot (in addition to the alias mechanism):

```bash
# [HOST]
echo kvm_intel | sudo tee /etc/modules-load.d/kvm.conf    # use kvm_amd on AMD
sudo reboot
```

### A.7 Nested virtualisation (only when the host is itself a VM)

If `systemd-detect-virt` does not print `none`, the Debian host runs inside another hypervisor. Nested virtualisation must then be enabled in that outer hypervisor. The Ubuntu documentation at https://ubuntu.com/server/docs/how-to/virtualisation/enable-nested-virtualisation/ explains the principle. Inside the Debian VM, check it with:

```bash
cat /sys/module/kvm_intel/parameters/nested      # Y means enabled
```

On a physical host, nested virtualisation is not needed, and it has no effect on `/dev/kvm`. Modern kernels enable it by default.

### A.8 Quick reference of checks

```bash
sudo virt-host-validate qemu | grep kvm          # the /dev/kvm line must show PASS in lab mode
sudo modprobe -c | grep -i '^blacklist' | grep -i kvm   # prints nothing in lab mode
```

### A.9 Switching from lab mode (KVM) to VirtualBox

Install VirtualBox first if it is not present:

```bash
sudo apt install virtualbox
```

If VirtualBox later reports that its kernel driver is missing, install the module build tools and rebuild the modules:

```bash
sudo apt install virtualbox-dkms linux-headers-amd64
sudo /sbin/vboxconfig
```

Then switch the mode:

```bash
# [HOST] 1. Stop the lab VMs
sudo virsh list --name | xargs -r -n1 sudo virsh shutdown
sleep 30
sudo virsh list                        # must be empty; otherwise: sudo virsh destroy <name>

# [HOST] 2. Unload KVM from the running system
sudo modprobe -r kvm_intel
lsmod | grep kvm                       # must print nothing

# [HOST] 3. Block KVM at boot
sudo mv /etc/modprobe.d/blacklist-kvm.conf.bak /etc/modprobe.d/blacklist-kvm.conf
sudo update-initramfs -u

# [HOST] 4. Load the VirtualBox modules and check them
sudo modprobe vboxdrv
lsmod | grep vbox
VBoxManage --version

# [HOST] 5. Reboot to confirm the boot-time state
sudo reboot
```

If the `.bak` file does not exist, create the blacklist directly instead of step 3:

```bash
printf 'blacklist kvm\nblacklist kvm_intel\n' | sudo tee /etc/modprobe.d/blacklist-kvm.conf
sudo update-initramfs -u
```

On AMD, add `blacklist kvm_amd` to the same file.

After the reboot, `ls /dev/kvm` must report that the file does not exist, and `lsmod | grep kvm` must print nothing. Then start VirtualBox normally.

### A.10 Switching from VirtualBox back to lab mode (KVM)

Stop any VirtualBox VMs and close the VirtualBox window:

```bash
# [HOST] 1. Stop VirtualBox VMs
VBoxManage list runningvms
VBoxManage controlvm "<vm-name>" acpipowerbutton     # or: poweroff
VBoxManage list runningvms                           # must be empty
```

Then unload the VirtualBox modules and re-enable KVM:

```bash
# [HOST] 2. Unload the VirtualBox modules
sudo modprobe -r vboxnetadp vboxnetflt vboxdrv

# [HOST] 3. Allow KVM at boot again
sudo mv /etc/modprobe.d/blacklist-kvm.conf /etc/modprobe.d/blacklist-kvm.conf.bak
sudo update-initramfs -u

# [HOST] 4. Load KVM now and check it
sudo modprobe kvm_intel
ls -l /dev/kvm
sudo virt-host-validate qemu | grep kvm

# [HOST] 5. Reboot to confirm the boot-time state
sudo reboot
```

After the reboot, check that `/dev/kvm` exists, then start the lab VMs as described in Section 10.

Modprobe reports `FATAL: Module ... is not currently loaded` for any VirtualBox module that was never loaded. That message is harmless.

### A.11 Rules for switching safely

- Never run VirtualBox VMs and lab VMs at the same time. Check `lsmod | grep -E 'kvm|vbox'` before you start either one.
- Reboot after every switch. The commands above switch the running system, and the reboot confirms that the boot-time behaviour matches the mode you chose.
- Keep `blacklist-kvm.conf.bak` until you no longer need to switch back.

### A.12 Common problems when switching

| Symptom | Cause | Fix |
|---|---|---|
| `modprobe -r kvm_intel` reports "in use" | A lab VM or QEMU process is still running | `sudo virsh list`, then `sudo virsh destroy <name>` for any VM still listed. `pgrep -a qemu` shows remaining QEMU processes |
| VirtualBox reports that VT-x is unavailable or in use | KVM is loaded | Switch to VirtualBox mode (A.9) |
| VirtualBox reports that its kernel driver is missing or not loaded | Modules were not built for the current kernel | `sudo apt install virtualbox-dkms linux-headers-amd64`, `sudo /sbin/vboxconfig`, then reboot |
| KVM still loads after a reboot in VirtualBox mode | The file is misnamed, or `update-initramfs` was not run | Check the file name in `/etc/modprobe.d/`, run `sudo update-initramfs -u`, and reboot |
| `/dev/kvm` is missing in lab mode after a reboot | The blacklist file is still present | Follow A.3 |


