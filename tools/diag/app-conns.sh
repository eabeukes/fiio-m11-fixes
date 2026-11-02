#!/system/bin/sh
# Log an app uid's TCP sockets once a second (remote address in /proc/net hex form).
# usage (as root): app-conns.sh <uid> <seconds> > out.txt
B=/data/adb/magisk/busybox   # toybox here has no awk
uid=$1
n=$2
i=0
while [ "$i" -lt "$n" ]; do
  echo "T $(date +%T)"
  cat /proc/net/tcp /proc/net/tcp6 | $B awk -v u="$uid" '$8 == u { print $3, $4 }'
  sleep 1
  i=$((i + 1))
done
