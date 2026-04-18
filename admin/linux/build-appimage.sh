#! /bin/bash

# SPDX-FileCopyrightText: 2017 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: GPL-2.0-or-later

set -xeuo pipefail

export APPNAME=${APPNAME:-Nextcloud}
export EXECUTABLE_NAME=${EXECUTABLE_NAME:-nextcloud}
export BUILD_UPDATER=${BUILD_UPDATER:-OFF}
export BUILDNR=${BUILDNR:-0000}
export DESKTOP_CLIENT_ROOT=${DESKTOP_CLIENT_ROOT:-/home/user}
export VERSION_SUFFIX=${VERSION_SUFFIX:-stable}

skip_appimage() {
    local reason="$1"
    echo "Skipping AppImage generation: ${reason}"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        {
            echo "APPIMAGE_NAME="
            echo "APPIMAGE_AVAILABLE=false"
            echo "APPIMAGE_ARCH=${APPIMAGE_ARCH:-unknown}"
            echo "APPIMAGE_SKIP_REASON=${reason}"
        } >> "$GITHUB_OUTPUT"
    fi
    exit 0
}

RAW_ARCH=${APPIMAGE_ARCH:-$(uname -m)}
case "${RAW_ARCH}" in
    x86_64|amd64)
        export APPIMAGE_ARCH=x86_64
        export GNU_TRIPLET=x86_64-linux-gnu
        ;;
    aarch64|arm64)
        export APPIMAGE_ARCH=aarch64
        export GNU_TRIPLET=aarch64-linux-gnu
        ;;
    *)
        export APPIMAGE_ARCH=${RAW_ARCH}
        skip_appimage "unsupported architecture ${RAW_ARCH}"
        ;;
esac

if [ -z "${QT_BASE_DIR:-}" ]; then
    for candidate in "/root/linux-gcc-${APPIMAGE_ARCH}" "/usr"; do
        if [ -d "${candidate}" ]; then
            export QT_BASE_DIR=${candidate}
            break
        fi
    done
fi
export QT_BASE_DIR=${QT_BASE_DIR:-/usr}

if [ -z "${OPENSSL_ROOT_DIR:-}" ]; then
    for candidate in "/usr/lib/${GNU_TRIPLET}" "/usr/lib64" "/usr/lib"; do
        if [ -d "${candidate}" ]; then
            export OPENSSL_ROOT_DIR=${candidate}
            break
        fi
    done
fi
export OPENSSL_ROOT_DIR=${OPENSSL_ROOT_DIR:-/usr/lib/${GNU_TRIPLET}}

export SUFFIX=${PR_ID:=${DRONE_PULL_REQUEST:=master}}
if [ "$SUFFIX" != "master" ]; then
    SUFFIX="PR-$SUFFIX"
fi
if [ "$BUILD_UPDATER" != "OFF" ]; then
    BUILD_UPDATER=ON
fi

LINUXDEPLOY_APPIMAGE="linuxdeploy-${APPIMAGE_ARCH}.AppImage"
LINUXDEPLOY_PLUGIN_APPIMAGE="linuxdeploy-plugin-qt-${APPIMAGE_ARCH}.AppImage"
APPIMAGETOOL_APPIMAGE="appimagetool-${APPIMAGE_ARCH}.AppImage"
LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/${LINUXDEPLOY_APPIMAGE}"
LINUXDEPLOY_PLUGIN_URL="https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/${LINUXDEPLOY_PLUGIN_APPIMAGE}"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/${APPIMAGETOOL_APPIMAGE}"

WGET_CA_ARGS=()
if [ -d /etc/ssl/certs ]; then
    WGET_CA_ARGS=(--ca-directory=/etc/ssl/certs)
fi

ensure_tool_available() {
    local tool_url="$1"
    if ! wget --spider --quiet "${WGET_CA_ARGS[@]}" "$tool_url"; then
        skip_appimage "AppImage tooling unavailable for ${APPIMAGE_ARCH}: ${tool_url}"
    fi
}

extract_appimage_tool() {
    local tool_url="$1"
    local tool_name="$2"
    local extract_dir="$3"

    rm -rf "./${extract_dir}" ./squashfs-root
    wget -O "${tool_name}" "${WGET_CA_ARGS[@]}" -c "${tool_url}"
    chmod a+x "${tool_name}"
    "./${tool_name}" --appimage-extract
    rm "./${tool_name}"
    mv ./squashfs-root "./${extract_dir}"
}

move_optional_files() {
    local destination="$1"
    shift

    shopt -s nullglob
    for pattern in "$@"; do
        local matches=($pattern)
        if [ "${#matches[@]}" -gt 0 ]; then
            mv "${matches[@]}" "${destination}"/
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

collect_extra_library_args() {
    local -a libraries=(
        libharfbuzz.so.0
        libharfbuzz-subset.so.0
        libOpenGL.so.0
        libGLX.so.0
        libEGL.so.1
        libGLdispatch.so.0
        libdrm.so.2
        libgbm.so.1
        libuuid.so.1
        libgpg-error.so.0
        libz.so.1
        libpcre2-8.so.0
        libexpat.so.1
        libfreetype.so.6
        libglib-2.0.so.0
        libsoftokn3.so
    )
    local -a roots=(
        "${QT_BASE_DIR}/lib"
        "${QT_BASE_DIR}/lib64"
        "/usr/lib/${GNU_TRIPLET}"
        /usr/lib64
        /usr/lib
        "/usr/local/lib/${GNU_TRIPLET}"
        /usr/local/lib64
        /usr/local/lib
    )

    EXTRA_LIBRARY_ARGS=()
    local library root
    for library in "${libraries[@]}"; do
        for root in "${roots[@]}"; do
            if [ -e "${root}/${library}" ]; then
                EXTRA_LIBRARY_ARGS+=("--library=${root}/${library}")
                break
            fi
        done
    done
}

ensure_tool_available "${LINUXDEPLOY_URL}"
ensure_tool_available "${LINUXDEPLOY_PLUGIN_URL}"
ensure_tool_available "${APPIMAGETOOL_URL}"

# Ensure we use gcc-11 on RHEL-like systems
if [ -e "/opt/rh/gcc-toolset-14/enable" ]; then
    source /opt/rh/gcc-toolset-14/enable
fi

mkdir -p /app

# Build client
mkdir build-client
cd build-client
cmake \
    -G Ninja \
    -DCMAKE_PREFIX_PATH=${QT_BASE_DIR} \
    -DOPENSSL_ROOT_DIR=${OPENSSL_ROOT_DIR} \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DBUILD_TESTING=OFF \
    -DBUILD_UPDATER=$BUILD_UPDATER \
    -DMIRALL_VERSION_BUILD=$BUILDNR \
    -DMIRALL_VERSION_SUFFIX="$VERSION_SUFFIX" \
    -DCMAKE_UNITY_BUILD=ON \
    ${DESKTOP_CLIENT_ROOT}
cmake --build . --target all
DESTDIR=/app cmake --install .

# Move stuff around
cd /app

if [ -d "usr/lib/${GNU_TRIPLET}" ]; then
    mkdir -p usr/lib
    shopt -s nullglob
    triplet_libs=(usr/lib/${GNU_TRIPLET}/*)
    if [ "${#triplet_libs[@]}" -gt 0 ]; then
        mv "${triplet_libs[@]}" usr/lib/
    fi
    shopt -u nullglob
fi

mkdir -p AppDir/usr/plugins
move_optional_files AppDir/usr/plugins "usr/lib64/*sync_vfs_suffix.so" "usr/lib/*sync_vfs_suffix.so" || true
move_optional_files AppDir/usr/plugins "usr/lib64/*sync_vfs_xattr.so" "usr/lib/*sync_vfs_xattr.so" || true

rm -rf usr/lib/cmake
rm -rf usr/include
rm -rf usr/mkspecs
rm -rf "usr/lib/${GNU_TRIPLET}"

# Don't bundle the explorer extensions as we can't do anything with them in the AppImage
rm -rf usr/share/caja-python/
rm -rf usr/share/nautilus-python/
rm -rf usr/share/nemo-python/

# The client-specific data dir also contains the translations, we want to have those in the AppImage.
mkdir -p AppDir/usr/share
mv usr/share/${EXECUTABLE_NAME} AppDir/usr/share/${EXECUTABLE_NAME}

# Move sync exclude to right location
mv /app/etc/*/sync-exclude.lst usr/bin/
rm -rf etc

# com.nextcloud.desktopclient.nextcloud.desktop
DESKTOP_FILE=$(ls /app/usr/share/applications/*.desktop)

extract_appimage_tool "${LINUXDEPLOY_URL}" "${LINUXDEPLOY_APPIMAGE}" linuxdeploy-squashfs-root
extract_appimage_tool "${LINUXDEPLOY_PLUGIN_URL}" "${LINUXDEPLOY_PLUGIN_APPIMAGE}" linuxdeploy-plugin-qt-squashfs-root

export LD_LIBRARY_PATH="${QT_BASE_DIR}/lib:/app/usr/lib64:/app/usr/lib:/usr/local/lib/${GNU_TRIPLET}:/usr/local/lib:/usr/local/lib64:${LD_LIBRARY_PATH:-}"
./linuxdeploy-squashfs-root/AppRun --desktop-file="${DESKTOP_FILE}" --icon-file=usr/share/icons/hicolor/512x512/apps/Nextcloud.png --executable="usr/bin/${EXECUTABLE_NAME}" --appdir=AppDir

# Use linuxdeploy-plugin-qt to deploy qt dependencies
export PATH="${QT_BASE_DIR}/bin:${PATH}"
export QML_SOURCES_PATHS=${DESKTOP_CLIENT_ROOT}/src/gui
./linuxdeploy-plugin-qt-squashfs-root/AppRun --appdir=AppDir

collect_extra_library_args
./linuxdeploy-squashfs-root/AppRun --desktop-file="${DESKTOP_FILE}" \
    "${EXTRA_LIBRARY_ARGS[@]}" \
    --icon-file=usr/share/icons/hicolor/512x512/apps/Nextcloud.png --executable="usr/bin/${EXECUTABLE_NAME}" --appdir=AppDir --output appimage

# Workaround issue #103 and #7231
extract_appimage_tool "${APPIMAGETOOL_URL}" "${APPIMAGETOOL_APPIMAGE}" appimagetool-squashfs-root
APPIMAGE=$(ls *.AppImage)
./"${APPIMAGE}" --appimage-extract
rm ./"${APPIMAGE}"
LD_LIBRARY_PATH="$PWD/appimagetool-squashfs-root/usr/lib:${LD_LIBRARY_PATH:-}" PATH="$PWD/appimagetool-squashfs-root/usr/bin:${PATH}" appimagetool -n ./squashfs-root "${APPIMAGE}"

#move AppImage
export COMMIT=${GITHUB_SHA:=${DRONE_COMMIT}}
if [ ! -z "$COMMIT" ]
then
    export APPIMAGE_NAME="${EXECUTABLE_NAME}-${SUFFIX}-${COMMIT}-${APPIMAGE_ARCH}.AppImage"
else
    export APPIMAGE_NAME="${EXECUTABLE_NAME}-${SUFFIX}-${APPIMAGE_ARCH}.AppImage"
fi
mv *.AppImage ${DESKTOP_CLIENT_ROOT}/$APPIMAGE_NAME

# tell GitHub Actions the name of our appimage
if [ ! -z "${GITHUB_OUTPUT:-}" ]; then
  echo "AppImage name: ${APPIMAGE_NAME}"
  {
      echo "APPIMAGE_NAME=${APPIMAGE_NAME}"
      echo "APPIMAGE_AVAILABLE=true"
      echo "APPIMAGE_ARCH=${APPIMAGE_ARCH}"
  } >> "$GITHUB_OUTPUT"
fi
