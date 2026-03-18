#!/usr/bin/env bash

PWD=`pwd`
pushd ${PWD}
rm -rf a.out ../cpu0.hex *~ *.o *.bc *.s *.S
popd
