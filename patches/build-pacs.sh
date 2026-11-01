#!/bin/bash
set -euo pipefail

# Establish the defect against the matching distribution library. A setup
# error must not masquerade as the expected red regression.
c++ -std=c++17 /patches/test-filename-reservation.cc -o /tmp/original-reservation-test \
    -ldcmqrdb -ldcmnet -ldcmdata -loflog -lofstd
if /tmp/original-reservation-test > /tmp/original-reservation.log; then
    echo 'Upstream now reserves filenames; reassess the local patch' >&2
    exit 1
fi
cat /tmp/original-reservation.log
grep -E 'allocations=128 .*reserved=0 child_failures=0 expected=128' /tmp/original-reservation.log

cd /src/dcmtk-*/
patch -p1 < /patches/atomic-store-filenames.patch
cat /patches/reservation-test.cmake >> CMakeLists.txt
cmake -S . -B /build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_CXX_STANDARD=17 -DDCMTK_ENABLE_STL=ON -DDCMTK_ENABLE_PRIVATE_TAGS=ON \
    -DDCMTK_WITH_OPENSSL=ON -DDCMTK_WITH_ZLIB=ON -DDCMTK_WITH_WRAP=ON \
    -DDCMTK_WITH_PNG=OFF -DDCMTK_WITH_TIFF=OFF -DDCMTK_WITH_XML=OFF \
    -DDCMTK_WITH_SNDFILE=OFF -DDCMTK_WITH_ICU=OFF \
    -DDCMTK_DEFAULT_DICT=builtin -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_DATADIC=share/dcmtk
cmake --build /build --parallel 4 --target dcmqrscp filename-reservation-test
/build/bin/filename-reservation-test
