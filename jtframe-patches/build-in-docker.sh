#!/bin/bash
# Runs inside the jotego/jtcore20 container (Quartus + Go), with jtcores at /jtcores.
# usage: build-in-docker.sh <core> [target]
set -e
BUILD_CORE=$1
BUILD_TARGET=${2:-mister}

git config --global --add safe.directory '*'
cd /jtcores
export PATH=$PATH:/usr/local/go/bin
# note: setprj.sh exports TARGET=sidi128, so it is sourced before anything else
source modules/jtframe/bin/setprj.sh > /dev/null

# Same beta-key handling as jtframe/devops/xjtcore.sh
BETAKEY=${BETAKEY:-$(printf "%04X%04X" $RANDOM $RANDOM)}
export JTUTIL=/jtutil
mkdir -p $JTUTIL
printf "%08x" 0x$BETAKEY | xxd -r -p > $JTUTIL/beta.bin

echo "Building $BUILD_CORE for $BUILD_TARGET"
jtcore $BUILD_CORE --target $BUILD_TARGET --nodbg --nolinter
