prologue() {
  if [ $ARG_NUM == 0 ]; then
    echo "useage: bash $sh_name cpu_type endian"
    echo "  cpu_type: cpu032I or cpu032II"
    echo "  endian: eb (big endian, default) or el (little endian)"
    echo "for example:"
    echo "  bash build-run_backend.sh cpu032I eb"
    exit 1;
  fi
  if [ $CPU != cpu032I ] && [ $CPU != cpu032II ]; then
    echo "1st argument is cpu032I or cpu032II"
    exit 1
  fi

  OS=`uname -s`
  echo "OS =" ${OS}

  TOOLDIR=$HOME/Documents/llvm-project/build/bin
  CLANG=${TOOLDIR}/clang

  CPU=$CPU
  echo "CPU =" "${CPU}"

  if [ "$ENDIAN" != "" ] && [ $ENDIAN != el ] && [ $ENDIAN != eb ]; then
    echo "2nd argument is eb (big endian, default) or el (little endian)"
    exit 1
  fi
  if [ $ENDIAN == eb ]; then
    ENDIAN=
  fi
  echo "ENDIAN =" "${ENDIAN}"

  bash clean.sh
}

isLittleEndian() {
  echo "ENDIAN = " "$ENDIAN"
  if [ "$ENDIAN" == "LittleEndian" ] ; then
    LE="true"
  elif [ "$ENDIAN" == "BigEndian" ] ; then
    LE="false"
  else
    echo "!ENDIAN unknown"
    exit 1
  fi
}
