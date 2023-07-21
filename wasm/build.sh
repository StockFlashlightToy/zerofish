#!/usr/bin/env -S bash -e

cd "$(dirname "${BASH_SOURCE:-$0}")/.."

function main() {

  setVariablesFromArgs "$@"

  CXX_FLAGS=(
    "${OPT_FLAGS[@]}"
    -Ilc0/src
    -IStockfish/src
    -Ieigen
    -Wno-deprecated-copy-with-user-provided-copy
    -Wno-deprecated-declarations
    -Wno-unused-command-line-argument
    -std=c++17
    -pthread
    -msse
    -msse2
    -mssse3
    -msse4.1
    -msimd128
    -D__i386__
    -DEIGEN_NO_CPUID
    -DEIGEN_DONT_VECTORIZE
    -DUSE_SSE2
    -DUSE_SSE41
    -DUSE_POPCNT
    -DNO_PEXT
  )
  LD_FLAGS=(
    "${CXX_FLAGS[@]}"
    --pre-js=${LOCAL+../src/emscripten/}initModule.js
    -sEXPORTED_FUNCTIONS=['_free','_malloc','_main']
    -sINITIAL_MEMORY=512MB
    -sSTACK_SIZE=512KB
    -sEXPORT_ES6
    -sMODULARIZE
    -sEXPORTED_RUNTIME_METHODS=[stringToNewUTF8]
    -sEXPORT_NAME=zerofish
    -sENVIRONMENT=$ENVIRONMENT
    -sPTHREAD_POOL_SIZE=7
  )
  SF_SOURCES=(
    bitbase.cpp bitboard.cpp endgame.cpp evaluate.cpp material.cpp misc.cpp movegen.cpp
    movepick.cpp pawns.cpp position.cpp psqt.cpp search.cpp thread.cpp timeman.cpp tt.cpp
    uci.cpp ucioption.cpp
  )
  LC0_SOURCES=(
    chess/bitboard.cc chess/board.cc chess/position.cc chess/uciloop.cc engine.cc mcts/node.cc
    mcts/params.cc mcts/search.cc mcts/stoppers/alphazero.cc mcts/stoppers/common.cc
    mcts/stoppers/factory.cc mcts/stoppers/legacy.cc mcts/stoppers/simple.cc
    mcts/stoppers/smooth.cc mcts/stoppers/stoppers.cc mcts/stoppers/timemgr.cc neural/cache.cc
    neural/decoder.cc neural/encoder.cc neural/factory.cc neural/loader.cc
    neural/network_check.cc neural/network_demux.cc neural/network_legacy.cc
    neural/network_mux.cc neural/network_random.cc neural/network_record.cc neural/network_rr.cc
    neural/network_trivial.cc neural/blas/convolution1.cc neural/blas/fully_connected_layer.cc
    neural/blas/se_unit.cc neural/blas/network_blas.cc neural/blas/winograd_convolution3.cc
    neural/shared/activation.cc neural/shared/winograd_filter.cc utils/histogram.cc
    utils/logging.cc utils/numa.cc utils/optionsdict.cc utils/optionsparser.cc
    utils/protomessage.cc utils/random.cc  utils/string.cc utils/weights_adapter.cc
    utils/fp16_utils.cc version.cc
  )

  for i in "${!LC0_SOURCES[@]}"; do
    SRCS+="lc0/src/${LC0_SOURCES[$i]} "
    OBJS+="lc0/src/${LC0_SOURCES[$i]%.cc}.o "
  done
  for i in "${!SF_SOURCES[@]}"; do
    SRCS+="Stockfish/src/${SF_SOURCES[$i]} "
    OBJS+="Stockfish/src/${SF_SOURCES[$i]%.cpp}.o "
  done

  OUT_DIR="$(pwd)/dist"
  mkdir -p "$OUT_DIR"

  generateMakefile

  if [ $LOCAL ]; then
    localBuild
  else
    dockerBuild
  fi
  maybeCreateRequire "$OUT_DIR/zerofishWasm.worker.js"
}

function localBuild() {
  pushd wasm > /dev/null
  . fetchSources.sh
  make
  mv zerofishWasm.* "$OUT_DIR"
  popd > /dev/null
}

function dockerBuild() {
  docker rm -f zerofish > /dev/null
  docker rmi -f zerofish-img > /dev/null
  docker build -t zerofish-img ${FORCE:+--no-cache} -f wasm/Dockerfile .
  docker create --name zerofish zerofish-img
  docker cp zerofish:/zf/dist/. "$OUT_DIR" # get the goodies
}

function maybeCreateRequire() { # coax the es6 emscripten output into working with nodejs
  if [ "$ENVIRONMENT" != "node" ]; then return; fi
  # if [ $2 ]; then sed -i '0,/require/{s/require/globalThis.require/}' "$1"; fi # ugh
  cat src/emscripten/createRequire.js "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

function setVariablesFromArgs() {
  # defaults
  ARTIFACT="zerofishWasm"
  OPT_FLAGS=(-O3 -DNDEBUG)
  ENVIRONMENT="web,worker"
  LOCAL=true
  unset FORCE DEBUG

  # override defaults with command line arguments
  while test $# -gt 0; do
    if [ "$1" == "debug" ]; then
      DEBUG=true
      OPT_FLAGS=(-O0 -DDEBUG -sASSERTIONS -g3 -sNO_DISABLE_EXCEPTION_CATCHING)
    elif [ "$1" == "docker" ]; then
      unset LOCAL
    elif [ "$1" == "force" ]; then
      FORCE=true
    elif [ "$1" == "node" ]; then
      ENVIRONMENT="node"
    else
      echo "Unknown argument: $1"
      exit 1
    fi
    shift
  done
}

function generateMakefile() {
  cat > wasm/Makefile<<EOL
  # generated with wasm/build.sh

  EXE = $ARTIFACT.js
  CXX = em++
  SRCS = $SRCS ${LOCAL+../src/emscripten/}main.cpp
  OBJS = $OBJS ${LOCAL+../src/emscripten/}main.o

  CXXFLAGS = ${CXX_FLAGS[@]}
  LDFLAGS = ${LD_FLAGS[@]}

  build:
	  @echo "SRCS=\$(SRCS) \$(OBJS) \$(CXXFLAGS) \$(LDFLAGS)"
	  \$(MAKE) \$(EXE)

  \$(EXE): \$(OBJS)
	  \$(CXX) -o \$@ \$(OBJS) \$(LDFLAGS)
EOL
}

main "$@"