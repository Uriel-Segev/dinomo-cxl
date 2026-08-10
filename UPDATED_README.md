# DINOMO on CloudLab c6525-25g with Soft-RoCE

This guide documents the working single-host deployment used for DINOMO. One Utah CloudLab c6525-25g host runs five KVM guests. The guests communicate over a private libvirt network, and the storage/KVS guests use Soft-RoCE (rdma_rxe) over a second private bridge.

## 1. Architecture

| Role | Management IP | Soft-RoCE IP |
|---|---:|---:|
| storage | 192.168.122.25 | 10.0.0.1 |
| kvs | 192.168.122.150 | 10.0.0.2 |
| route | 192.168.122.99 | — |
| monitor | 192.168.122.114 | — |
| benchmark client | 192.168.122.167 | — |

The physical CloudLab host is the only bare-metal node. DINOMO itself runs inside the five guests.

## 2. CloudLab allocation

Allocate one Utah CloudLab node of type c6525-25g (or a compatible node with KVM support). After the node becomes ready, connect using the SSH command shown by CloudLab:

~~~bash
ssh vinothg@<cloudlab-host>.utah.cloudlab.us
~~~

Verify the host:

~~~bash
hostname -f
uname -r
nproc
free -h
df -h
ls -l /dev/kvm
sudo -v
~~~

The tested host had at least 24 CPUs, approximately 64 GB RAM, and approximately 900 GB of local NVMe storage.

## 3. Clone the repository

~~~bash
cd ~
git clone https://github.com/Uriel-Segev/dinomo-cxl.git
cd ~/dinomo-cxl
~~~

If you have a working branch:

~~~bash
git switch cloudlab-softroce
~~~

## 4. Configure the CloudLab host

Edit vm-configs/c6525-25g/config.sh:

~~~bash
vi vm-configs/c6525-25g/config.sh
~~~

Set the allocation-specific values:

~~~bash
CLOUDLAB_HOST="<actual-hostname>.utah.cloudlab.us"
SSH_USER="vinothg"
SSH_KEY="\${HOME}/.ssh/id_ed25519"
NODE_TYPE="c6525-25g"
VM_RDMA_IFACE="enp2s0"
DINOMO_REPO="https://github.com/Uriel-Segev/dinomo-cxl.git"
~~~

Use the exact hostname returned by hostname -f. The fixed guest IPs should remain as listed above unless every generated DINOMO configuration is also updated.

Check syntax:

~~~bash
bash -n vm-configs/c6525-25g/config.sh
bash -n vm-configs/c6525-25g/setup_vms.sh
~~~

## 5. SSH key used by the guests

The setup script copies the first non-comment key from the host authorized_keys file into guest cloud-init data:

~~~bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "dinomo-self-ssh"
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
~~~

Verify host self-SSH:

~~~bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes \
  vinothg@$(hostname -f) hostname
~~~

Do not put a literal # or an empty value in ssh_authorized_keys in generated cloud-init data.

## 6. Guest network configuration

The final working configuration uses two virtio NICs in storage and KVS:

- enp1s0: management NIC on libvirt default, static 192.168.122.x address.
- enp2s0: RDMA NIC on rdma-net/br-rdma, static 10.0.0.x address.

The setup script matches each NIC by pinned MAC address and keeps the names enp1s0 and enp2s0. Do not use ens3/ens4 unless those names have been verified inside the guests.

The management network uses gateway 192.168.122.1. The RDMA network has no gateway; it is only for storage/KVS traffic.

## 7. Create the VMs

~~~bash
bash vm-configs/c6525-25g/setup_vms.sh
~~~

The script installs KVM/libvirt, creates br-rdma and rdma-net, creates five qcow2 guests, boots them, waits for cloud-init, clones DINOMO, and builds the binaries. The first run may take 15–30 minutes.

Verify:

~~~bash
sudo virsh list --all
sudo virsh domiflist dinomo-storage
sudo virsh domiflist dinomo-kvs
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.122.25 hostname
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.122.150 hostname
~~~

With static guest addresses, virsh net-dhcp-leases default can be empty. That is not itself an error.

## 8. Build dependencies and libbloom

The build requires Protobuf, jemalloc, TBB, RDMA, PMDK, ZeroMQ, Boost, and yaml-cpp. If cloud-init did not install the packages, run this on each guest:

~~~bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential cmake git python3 wget \
  protobuf-compiler libprotobuf-dev \
  libibverbs-dev librdmacm-dev rdma-core \
  libtbb-dev libjemalloc-dev libzmq3-dev \
  libboost-all-dev libyaml-cpp-dev \
  libpmemobj-dev libpmem-dev numactl
~~~

If CMake reports:

~~~text
No rule to make target '../src/kvs/libbloom/build/libbloom.so'
~~~

build the bundled library first on each guest:

~~~bash
cd ~/projects/DINOMO
make -C src/kvs/libbloom -j$(nproc)
cmake --build build -j$(nproc)
~~~

For build failures:

~~~bash
tail -100 /tmp/cmake.log
tail -100 /tmp/make.log
~~~

The libbloom build step should eventually be incorporated into setup_vms.sh so a fresh setup does not require manual intervention.

## 9. DINOMO configuration

Each guest needs conf/dinomo-config.yml. Start with conf/dinomo-vm-config.yml and add a role-specific server block:

~~~yaml
server:
  public_ip: <management-ip>
  private_ip: <rdma-ip-or-management-ip>
  seed_ip: 192.168.122.99
  mgmt_ip: "NULL"
  routing:
    - 192.168.122.99
  monitoring:
    - 192.168.122.114
~~~

For storage and KVS, private_ip is 10.0.0.1 and 10.0.0.2. Their ib_config.storage_node_ips and clover_memc_ips point to 10.0.0.1.

The benchmark guest also needs:

~~~yaml
user:
  monitoring:
    - 192.168.122.114
  routing:
    - 192.168.122.99
  ip: 192.168.122.167

trigger:
  benchmark:
    - 192.168.122.167
  management:
    - 192.168.122.114
~~~

Missing server, user, or trigger configuration can cause bad_alloc, stoi, or trigger failures even when RDMA is healthy.

## 10. Benchmark hostname fix

The benchmark originally attempted to parse a numeric node ID from the hostname. A hostname such as dinomo-bench causes stoi to fail. The working fix sets the node ID explicitly:

~~~cpp
node_id = 0;
~~~

After changing the source, rebuild:

~~~bash
cd ~/projects/DINOMO
make -C src/kvs/libbloom -j$(nproc)
cmake --build build -j$(nproc)
~~~

## 11. Start DINOMO and Soft-RoCE

~~~bash
bash vm-configs/c6525-25g/start.sh
~~~

The script stops old processes, loads rdma_rxe, creates rxe0 on enp2s0, starts storage, waits for its socket, starts KVS/route/monitor/benchmark, and waits for the KVS handshake.

Successful output ends with:

~~~text
4/4 threads ready... done.
DINOMO is ready.
~~~

Validate Soft-RoCE:

~~~bash
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.122.25 \
  'sudo rdma link show; ip addr show enp2s0'

ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.122.150 \
  'sudo rdma link show; ip addr show enp2s0'
~~~

Expected output includes rxe0/1 state ACTIVE and the 10.0.0.x/24 address.

An error: File exists message while adding rxe0 usually means a stale link already exists. If rdma link show reports an active rxe0, the setup is usable. Otherwise reset it inside the affected guest:

~~~bash
sudo rdma link delete rxe0/1 2>/dev/null || true
sudo modprobe rdma_rxe
sudo rdma link add rxe0 type rxe netdev enp2s0
~~~

## 12. Run the built-in test

With DINOMO running:

~~~bash
bash vm-configs/c6525-25g/test.sh
~~~

The test performs a load and read workloads. The trigger may repeatedly print help text and command>; that is normal. Check the benchmark log:

~~~bash
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.122.167 \
  'tail -80 ~/projects/DINOMO/log_0.txt'
~~~

Successful runs contain Loading data took ... and end with Finished.

## 13. Manual benchmark triggers

Keep trigger input open briefly after sending a command:

~~~bash
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.122.167 '
cd ~/projects/DINOMO
{
  printf "%s\n" "LOAD:100000:64:1:1"
  sleep 5
} | ./build/target/benchmark/dinomo-bench-trigger 1
'
~~~

A 30-second read workload:

~~~bash
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.122.167 '
cd ~/projects/DINOMO
{
  printf "%s\n" "RUN:100:100000:64:5:30:0:64:0"
  sleep 35
} | ./build/target/benchmark/dinomo-bench-trigger 1
'
~~~

Command formats:

~~~text
LOAD:num_keys:value_size:threads_per_node:num_nodes
RUN:read_ratio:num_keys:value_size:report_period:duration:zipf:outstanding:update_only
WARM:num_keys:value_size:num_requests:zipf
ADD:num_bench_nodes
REMOVE:num_bench_nodes
FAIL:num_failed_nodes
~~~

Run one trigger workload at a time.

## 14. Writing custom tests

Create a wrapper such as vm-configs/c6525-25g/my_test.sh:

~~~bash
#!/usr/bin/env bash
set -euo pipefail

BENCH_IP="192.168.122.167"
KEY="$HOME/.ssh/id_ed25519"

run_trigger() {
  local command="$1"
  local wait_seconds="$2"
  ssh -i "$KEY" "ubuntu@$BENCH_IP" "
    cd ~/projects/DINOMO
    { printf '%s\\n' '$command'; sleep $wait_seconds; } |
      ./build/target/benchmark/dinomo-bench-trigger 1
  " >/tmp/custom-trigger.log 2>&1
}

run_trigger "LOAD:100000:64:1:1" 5
run_trigger "RUN:100:100000:64:5:30:0:64:0" 35

ssh -i "$KEY" "ubuntu@$BENCH_IP" \
  'tail -80 ~/projects/DINOMO/log_0.txt'
~~~

Run it:

~~~bash
chmod +x vm-configs/c6525-25g/my_test.sh
./vm-configs/c6525-25g/my_test.sh
~~~

## 15. Logs and troubleshooting

~~~bash
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.122.25 \
  'sudo tail -100 /tmp/dinomo-storage.log'
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.122.150 \
  'sudo tail -100 /tmp/dinomo-kvs.log'
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.122.167 \
  'tail -100 ~/projects/DINOMO/log_0.txt'
~~~

| Symptom | Likely cause |
|---|---|
| No route to host to 192.168.122.x | Guest NIC names/MAC matching or cloud-init network configuration is wrong. Check virsh domiflist, guest ip addr, and generated /tmp/network-*.yaml. |
| Empty virsh net-dhcp-leases default | Expected for static management addresses. |
| modprobe: Module rdma_rxe not found | Guest kernel modules do not match rdma-core. Check uname -r and modinfo rdma_rxe inside the guest. |
| Storage says YAML::BadFile | conf/dinomo-config.yml is missing or the process started from the wrong directory. |
| dinomo-storage binary is missing | CMake/build failed. Inspect /tmp/cmake.log and /tmp/make.log; build libbloom first. |
| KVS exits with bad_alloc | Generated server configuration is incomplete or incorrect. |
| Benchmark exits with stoi | Apply the explicit node_id = 0 fix and rebuild. |
| Trigger prints help repeatedly | Normal trigger behavior; inspect log_0.txt for Finished. |

## 16. Stop and recreate the VMs

Stop services:

~~~bash
bash vm-configs/c6525-25g/stop.sh
~~~

For a complete clean rebuild, this removes guest domains and disk overlays:

~~~bash
for vm in storage kvs route monitor bench; do
  sudo virsh destroy "dinomo-$vm" 2>/dev/null || true
  sudo virsh undefine "dinomo-$vm" 2>/dev/null || true
  sudo rm -f "/mnt/data/dinomo-$vm.qcow2"
done

sudo rm -f /tmp/seed-{storage,kvs,route,monitor,bench}.iso
sudo rm -f /tmp/user-data-{storage,kvs,route,monitor,bench}.yaml
sudo rm -f /tmp/network-{storage,kvs,route,monitor,bench}.yaml

bash vm-configs/c6525-25g/setup_vms.sh
~~~

## 17. Save working changes in Git

Commit only source and setup scripts:

~~~bash
git switch -c cloudlab-softroce
git add vm-configs/c6525-25g/config.sh \
        vm-configs/c6525-25g/setup_vms.sh \
        vm-configs/c6525-25g/start.sh \
        vm-configs/c6525-25g/test.sh
git diff --cached --check
git commit -m "Make CloudLab Soft-RoCE setup reproducible"
~~~

To publish to the original repository, you need write permission on Uriel-Segev/dinomo-cxl:

~~~bash
git remote set-url origin git@github.com:Uriel-Segev/dinomo-cxl.git
git push -u origin cloudlab-softroce
~~~

## 18. Expected working result

The deployment is healthy when:

1. All five guests are running.
2. Storage and KVS report rxe0/1 state ACTIVE.
3. start.sh reports 4/4 threads ready... done.
4. The benchmark log reports Loading data took ...
5. RUN workloads report throughput/latency epochs and end with Finished.

The tested setup achieved successful loads and read workloads over Soft-RoCE on one c6525-25g CloudLab host.
