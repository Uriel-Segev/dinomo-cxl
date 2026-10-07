The `setup_vms.sh` script has a problem where it does not get rid of the old ssh keys if VMs are destroyed and recreated. This leads to the user not being able to access the VMs without first running this command on local host:

``` bash
ssh -i ~/.ssh/sabro_ed25519 lredivo@sabro.idav.ucdavis.edu "
  for ip in 192.168.122.25 192.168.122.150 192.168.122.99 192.168.122.114 192.168.122.167; do
    ssh-keygen -R \"\${ip}\" -f ~/.ssh/known_hosts 2>/dev/null || true
  done
  echo Done
"
```
