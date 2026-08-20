The `setup_vms.sh` script has a problem where it does not get rid of the old ssh keys if VMs are destroyed and recreated. This leads to the user not being able to access the VMs without first running this command on local host:

``` bash
ssh -i ~/.ssh/sabro_ed25519 lredivo@sabro.idav.ucdavis.edu "
  for ip in 192.168.122.25 192.168.122.150 192.168.122.99 192.168.122.114 192.168.122.167; do
    ssh-keygen -R \"\${ip}\" -f ~/.ssh/known_hosts 2>/dev/null || true
  done
  echo Done
"
```

If you see this error:
```shell
================ IB Echo Server ================

  

  

************ Configuraion ************

  

is_server                 = true

rank                      = 0

msg_size                  = 8388608

threads per memory        = 8

threads per storage       = 4

sock_port                 = 1

storage capacities        = 110GB

  

************ End of Configuraion ************

  

failed to open the pool

: No space left on device
```

When first running the `setup_vms.sh` and `start.sh` scripts we need to change the yml file to have a different capacity, since the vms have lower storage and ram limits on local host.  Do the following:
```bash
nano ~/projects/DINOMO/conf/dinomo-base.yml

# Change from 110GB (118111600640) or similar to 4GB / 8GB
storage_capacity: 4096  # 4 GB in bytes (or set to 4GB depending on format)

# link the file so its findable when opening RDMA
ln -sf dinomo-base.yml conf/dinomo-config.yml
```