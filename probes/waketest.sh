#!/bin/bash
# 1) wake + stream as root  2) stream unprivileged afterwards, to see if the wake persists.
set -u
cd "$(dirname "$0")"
[ "$(id -u)" = "0" ] || { echo "run: sudo bash $0" >&2; exit 1; }

echo "################ ROOT: wake + stream ################"
./imuwake 5
echo
echo "################ UNPRIVILEGED: stream after wake ################"
echo "(driver already woken above; does a non-root reader get data?)"
sudo -u "${SUDO_USER:-nobody}" ./imu100 5
