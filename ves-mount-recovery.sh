#!/bin/bash
# VES: self-heals NFS mounts + cachefilesd after any restart.
#
# Boot-time automount via remote-fs.target has proven unreliable on this
# fleet's WSL2 machines — observed failure modes: an early-boot race where
# WSL's own fstab pass runs before the nfs/nfsv4 kernel modules finish
# loading ("No such device"), a resvport-driven mount timeout, and (after
# the host merely sleeps rather than fully reboots) systemd's dependency
# graph never pulling remote-fs.target in at all. Once a mount unit fails
# once, systemd does not retry it for the rest of that boot.
#
# This unconditionally retries mount -a plus cachefilesd recovery a few
# times with backoff, independent of whichever specific mechanism failed
# that particular boot.
set -u

for i in 1 2 3 4 5 6; do
  systemctl reset-failed cachefilesd 2>/dev/null || true
  systemctl is-active --quiet cachefilesd || systemctl start cachefilesd 2>/dev/null || true
  mount -a 2>/dev/null

  all_up=true
  for mp in /mnt/BigMomma /mnt/BigPoppa /mnt/BabyBear; do
    mountpoint -q "$mp" 2>/dev/null || all_up=false
  done

  if [ "$all_up" = true ]; then
    logger -t ves-mount-recovery "NFS mounts confirmed active after $i attempt(s)"
    exit 0
  fi
  sleep 5
done

logger -t ves-mount-recovery "WARNING: NFS mounts still not fully active after 6 attempts"
exit 0
