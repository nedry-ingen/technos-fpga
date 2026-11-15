#!/bin/bash
# Runs inside the jotego/jtcore20 container (Quartus + Go), with jtcores at /jtcores.
# usage: build-in-docker.sh <core> <target>
set -e
CORE=$1
TARGET=${2:-mister}

git config --global --add safe.directory '*'
cd /jtcores
export PATH=$PATH:/usr/local/go/bin
source modules/jtframe/bin/setprj.sh > /dev/null

# Same beta-key handling as jtframe/devops/xjtcore.sh
BETAKEY=${BETAKEY:-$(printf "%04X%04X" $RANDOM $RANDOM)}
export JTUTIL=/jtutil
mkdir -p $JTUTIL
printf "%08x" 0x$BETAKEY | xxd -r -p > $JTUTIL/beta.bin

jtcore $CORE --target $TARGET --nodbg --nolinter
