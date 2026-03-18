#!/usr/bin/env bash

# for example:
# bash build-run_backend.sh cpu032I el
# bash build-run_backend.sh cpu032II eb

source functions.sh

sh_name=build-run_backend.sh
ARG_NUM=$#
CPU=$1
ENDIAN=$2

DEFFLAGS=""
if [ "$CPU" == cpu032II ] ; then
  DEFFLAGS=${DEFFLAGS}" -DCPU032II"
fi
echo ${DEFFLAGS}

prologue;

# ch8_2_select_global_pic.cpp just for compile build test only, without running
# on verilog.
$CLANG ${DEFFLAGS} -target mips-unknown-linux-gnu -c ch8_2_select_global_pic.cpp \
-emit-llvm -o ch8_2_select_global_pic.bc
${TOOLDIR}/llc -march=cpu0${ENDIAN} -mcpu=${CPU} -relocation-model=pic \
-filetype=obj ch8_2_select_global_pic.bc -o ch8_2_select_global_pic.cpu0.o

$CLANG ${DEFFLAGS} -target mips-unknown-linux-gnu -c ch_run_backend.cpp \
-emit-llvm -o ch_run_backend.bc
echo "${TOOLDIR}/llc -march=cpu0${ENDIAN} -mcpu=${CPU} -relocation-model=static \
-filetype=obj -enable-cpu0-tail-calls ch_run_backend.bc -o ch_run_backend.cpu0.o"
${TOOLDIR}/llc -march=cpu0${ENDIAN} -mcpu=${CPU} -relocation-model=static \
-filetype=obj -enable-cpu0-tail-calls ch_run_backend.bc -o ch_run_backend.cpu0.o
# Extract raw .text section bytes and convert to hex format for Verilog $readmemh.
# Uses llvm-objcopy to avoid disassembler issues with certain instruction encodings.
${TOOLDIR}/llvm-objcopy -O binary --only-section=.text ch_run_backend.cpu0.o ch_run_backend.text.bin
xxd -p ch_run_backend.text.bin | fold -w2 | \
awk '{printf "%s%s", $0, (NR%4==0 ? "\n" : " ")}' > ../cpu0.hex

ENDIAN=`${TOOLDIR}/llvm-readobj -h ch_run_backend.cpu0.o|grep "DataEncoding"|awk '{print $2}'`
isLittleEndian;

if [ $LE == "true" ] ; then
  echo "1   /* 0: big ENDIAN, 1: little ENDIAN */" > ../cpu0.config
else
  echo "0   /* 0: big ENDIAN, 1: little ENDIAN */" > ../cpu0.config
fi
cat ../cpu0.config
