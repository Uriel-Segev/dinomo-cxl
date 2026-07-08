# c6525-25g Single-Server VM Setup Notes

## Goal
Run all 5 DINOMO components on one physical server using KVM VMs connected via Soft-RoCE (virtual RDMA).

## Hardware
- Node: amd225.utah.cloudlab.us
- CPU: AMD EPYC 7302P, 32 cores (16 physical, SMT)
- RAM: 125GB
- Disk: /dev/sda (447GB), /dev/sdb (447GB)
  - /dev/sda4 mounted at /mnt/data (396GB) — VM images stored here
- NICs:
  - 01:00.0 (eno33) → mlx5_0: ConnectX-5, PORT_ACTIVE, Ethernet — management/control, NO SR-IOV
  - 41:00.0 (ens1f0) → mlx5_2: ConnectX-5, PORT_DOWN — SR-IOV capable (4 VFs) but no cable

## Why Soft-RoCE instead of SR-IOV
SR-IOV VFs exist on mlx5_2/mlx5_3 (4 VFs each) but the physical ports are DOWN —
no cable plugged in, CloudLab doesn't let us change that. Without a physical link,
RoCE won't establish. Soft-RoCE (rdma_rxe kernel module) runs RDMA over any ethernet
interface including virtual VM NICs on a bridge. This is exactly "virtual RDMA" as
described in the research meeting.

Soft-RoCE confirmed working on host: 5.8 Gbps loopback, 11µs latency via ibv_rc_pingpong.

## Network Design
Two virtual networks:
- virbr0 (192.168.122.0/24): libvirt NAT — management SSH into each VM
- br-rdma (10.0.0.0/24): Linux bridge — RDMA network, Soft-RoCE runs on this inside VMs

### VM IP assignments
| VM | Role | virbr0 (mgmt) | br-rdma (RDMA) |
|----|------|----------------|-----------------|
| dinomo-storage | storage backend | DHCP → static | 10.0.0.1 |
| dinomo-kvs | memory node | DHCP → static | 10.0.0.2 |
| dinomo-route | routing | DHCP → static | — (ZMQ only) |
| dinomo-monitor | monitoring | DHCP → static | — (ZMQ only) |
| dinomo-bench | benchmark client | DHCP → static | — (ZMQ only) |

Storage and kvs are the only VMs that do RDMA — they each get a br-rdma interface.
Route/monitor/bench only use ZMQ over virbr0.

## VM Specs
| VM | vCPUs | RAM |
|----|-------|-----|
| storage | 8 | 24GB |
| kvs | 8 | 24GB |
| route | 4 | 8GB |
| monitor | 4 | 8GB |
| bench | 4 | 16GB |

Total: 28 vCPUs (have 32), 80GB RAM (have 125GB). Fits comfortably.

## Base Image
Ubuntu 20.04 cloud image: focal-server-cloudimg-amd64.img
Downloaded to /mnt/data/ubuntu-20.04-base.img
Each VM gets a qcow2 overlay on top of the base image (copy-on-write, saves disk).

## Soft-RoCE Setup (inside each VM that needs RDMA)
```bash
sudo modprobe rdma_rxe
sudo rdma link add rxe0 type rxe netdev eth1   # eth1 = br-rdma interface
ibv_devinfo -d rxe0   # should show PORT_ACTIVE
```

## DINOMO Config Changes vs c6220
- storage_node_ips: 10.0.0.1  (storage VM's br-rdma IP)
- clover_memc_ips: 10.0.0.1
- routing IP: virbr0 IP of route VM
- monitoring IP: virbr0 IP of monitor VM
- rank: 0 (same as before)
- All other params same as c6220 config

## Scripts
- 00_create_vms.sh — create and boot all 5 VMs
- 01_setup_vms.sh — install deps, build DINOMO inside each VM
- 02_run_storage.sh — start dinomo-storage in storage VM
- 03_run_kvs.sh — start dinomo-kvs in kvs VM
- 04_run_route.sh — start dinomo-route in route VM
- 05_run_monitor.sh — start dinomo-monitor in monitor VM
- 06_run_bench.sh — start dinomo-bench in bench VM
- 00_cleanup.sh — kill all processes in all VMs

## Key Differences from c6220 Setup
1. No physical IB — Soft-RoCE via rdma_rxe on br-rdma virtual interface
2. Single host — all VMs on amd225.utah.cloudlab.us
3. SSH into VMs via their virbr0 IPs (not cloudlab hostnames)
4. Must load rdma_rxe in each VM at startup (not persistent across reboot by default)
5. DINOMO build: still need to remove -mavx2 (AMD EPYC supports AVX2, but safer to keep removed)
   Actually: EPYC 7302P DOES support AVX2 — can leave flags in or remove, either works
6. Pool path: /dev/shm/pool (same as c6220, tmpfs available in VMs)
