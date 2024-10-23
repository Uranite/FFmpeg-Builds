#!/bin/bash

SCRIPT_REPO="https://github.com/mm2/Little-CMS.git"
SCRIPT_COMMIT="47a261e0b1579558184499ae5aadd0a04b1fb76f"

ffbuild_enabled() {
    return 0
}

ffbuild_dockerbuild() {
    mkdir build && cd build

    local myconf=(
        --prefix="$FFBUILD_PREFIX"
        -Ddefault_library=static
        -Dutils=false
        -Dfastfloat=true
        -Dthreaded=true
    )

    if [[ $TARGET == win* || $TARGET == linux* ]]; then
        myconf+=(
            --cross-file=/cross.meson
        )
    else
        echo "Unknown target"
        return -1
    fi

    export CFLAGS="$CFLAGS -fpermissive"

    meson setup "${myconf[@]}" ..
    ninja -j$(nproc)
    ninja install
}
