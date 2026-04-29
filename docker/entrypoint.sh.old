#!/bin/env bash
set -e

echo $(date -Iseconds) [INFO] "Starting NavAPI app..."
/app/NavAPIServer/bin/naviapiserv.bin \
    --config /data/NavAPIServer/etc/navapiserv-config.toml &

echo $(date -Iseconds) [INFO] "Starting NDTP client app(s)!!! "

for conf in /data/NDTPClient/etc/*.toml; do
    echo -e "Starting NDTP client with $conf"
    /app/NDTPClient/bin/NDTP_Client --config $conf &
done

wait -n
exit $?

