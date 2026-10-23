#!/bin/sh -l
set -e
set -x

WORKSPACE="${1}"
ARCH="$2"

echo "Workspace: ${WORKSPACE}; arch: ${ARCH}"
cd "$WORKSPACE"

if [ "$(uname -s)" = "Linux" ]; then
  ~/.pyenv/bin/pyenv global 3.11
  export PATH="/root/.pyenv/shims:${PATH}"
  export CODON_OS_TEST_REQUIRE_RAW_PATHS=1

  # needed for dylib test
  ln -s -f $(pwd)/build-${ARCH}/libcodonrt.so .
else
  # needed for dylib test
  ln -s -f $(pwd)/build-${ARCH}/libcodonrt.dylib .
fi
export CODON_PYTHON=$(python ${WORKSPACE}/test/python/find-python-library.py)
export PYTHONPATH=${WORKSPACE}/test/python
export CODON_DIR=$(pwd)/codon-deploy-${ARCH}

echo "=> Unit tests..."
mkdir -p build  # needed for some tests that write into this directory
GTEST_FILTER_ARG=""
if [ "${ARCH}" = "darwin-x86_64" ]; then
  # Disable numpy tests on Intel macOS since it breaks on macOS 13
  # (macOS 14 Intel runners are not free).
  # arithmetic.codon fails in debug mode on x86 due to float16 (TODO: why?)
  export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
  GTEST_FILTER_ARG="--gtest_filter=-*numpy*:*core_arithmetic_codon_debug*"
  # :*python*:*core_arithmetic*:*stdlib_random_test*"
fi

# Run the suite as one gtest shard per CPU. Each shard runs in its own
# directory that mirrors the workspace (symlinks) but has a private build/,
# so tests that write fixed paths under build/ cannot collide.
# Two shards: with one shard per CPU (4 on ubuntu-latest) the runner lost
# communication mid-suite twice (memory/CPU starvation from parallel JIT tests).
SHARDS=${CODON_TEST_SHARDS:-2}
SHARD_ROOT="$(pwd)/build/shards"
rm -rf "${SHARD_ROOT}"
start=$(date +%s)
i=0
while [ "$i" -lt "$SHARDS" ]; do
  d="${SHARD_ROOT}/$i"
  mkdir -p "$d/build"
  for f in "$(pwd)"/* "$(pwd)"/.[!.]*; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "build" ] && continue
    ln -s "$f" "$d/"
  done
  (set +e; cd "$d" && GTEST_TOTAL_SHARDS=$SHARDS GTEST_SHARD_INDEX=$i \
     "${WORKSPACE}/build-${ARCH}/codon_test" ${GTEST_FILTER_ARG} > "${SHARD_ROOT}/$i.log" 2>&1; \
   echo $? > "${SHARD_ROOT}/$i.rc") &
  i=$((i + 1))
done
wait
failed=0
i=0
while [ "$i" -lt "$SHARDS" ]; do
  echo "::group::codon_test shard $i/$SHARDS"
  cat "${SHARD_ROOT}/$i.log"
  echo "::endgroup::"
  rc=$(cat "${SHARD_ROOT}/$i.rc")
  grep -E "^\[  (PASSED|FAILED)  \]|tests from .* ran" "${SHARD_ROOT}/$i.log" | sed "s/^/shard $i: /"
  [ "$rc" = "0" ] || { echo "shard $i failed (exit $rc)"; failed=1; }
  i=$((i + 1))
done
echo "unit tests: $SHARDS shards, $(( $(date +%s) - start )) s wall"
[ "$failed" = "0" ] || exit 1

echo "=> OS differential tests..."
python test/stdlib/os_differential.py --codon "${CODON_DIR}/bin/codon"

echo "=> Standalone test..."
CODON_PATH=${CODON_DIR}/lib/codon/stdlib test/app/test.sh build-${ARCH}

echo "=> Cython test..."
CODON_PATH=${CODON_DIR}/lib/codon/stdlib python test/python/cython_jit.py

echo "=> pyext debug test..."
(cd test/python && python setup.py build_ext --inplace --debug --force && python pyext.py)

echo "=> pyext release test..."
(cd test/python && python setup.py build_ext --inplace --force && python pyext.py)

# GPU test; only on select platforms
if command -v nvcc &> /dev/null; then
  echo "=> CUDA test..."
  nvcc_version=$(nvcc --version | grep "release" | awk '{print $NF}')
  echo "CUDA Version: $nvcc_version"
  ${CODON_DIR}/bin/codon run -release test/transform/gpu.codon
fi
