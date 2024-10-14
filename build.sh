#!/usr/bin/env bash
# Copyright ©2022-2024 XSans0

# Function to show an informational message
err() {
    echo -e "\e[1;41$*\e[0m"
}

# Environment checker
echo "Checking environment ..."
for environment in BOT_TOKEN CHAT_ID GH_TOKEN BRANCH; do
    [ -z "${!environment}" ] && {
        err "- $environment not set!"
        exit 1
    }
done

# Get home directory
HOME_DIR="$(pwd)"

# Telegram setup
send_msg() {
    bash "$HOME_DIR/tg_utils.sh" msg "$1"
}
send_file() {
    bash "$HOME_DIR/tg_utils.sh" up "$1" "$2"
}

# Git config
git config --global user.name "fukiame"
git config --global user.email "fukiame@proton.me"

GH_USER=fukiame
GH_REPO=clang-build

# Build LLVM
echo "building LLVM..."
send_msg "gh $RUN_NUM: building LLVM"

./build-llvm.py \
    --defines LLVM_PARALLEL_COMPILE_JOBS="$(nproc)" LLVM_PARALLEL_LINK_JOBS="$(nproc)" CMAKE_C_FLAGS=-O3 CMAKE_CXX_FLAGS=-O3 \
    --install-folder "$HOME_DIR/install" \
    --no-update \
    --no-ccache \
    --quiet-cmake \
    --ref "$BRANCH" \
    --shallow-clone \
    --targets AArch64 ARM X86 \
    --clang-vendor-string "Marija" \
    --lld-vendor-string "Lilith"

# Check if the final clang binary exists or not
for file in install/bin/clang-[1-9]*; do
    if [ -e "$file" ]; then
        msg "LLVM build successful"
    else
        err "LLVM build failed"
        send_msg "gh $RUN_NUM: LLVM build failed"
        exit 1
    fi
done

# Build binutils
echo "building binutils..."
send_msg "gh $RUN_NUM: building binutils"
./build-binutils.py \
    --install-folder "$HOME_DIR/install" \
    --targets arm aarch64 x86_64

# Remove unused products
rm -fr install/include
rm -f install/lib/*.a install/lib/*.la

# Strips remaining products
for f in $(find install -type f -exec file {} \; | grep 'not stripped' | awk '{print $1}'); do
    strip -s "${f::-1}"
done

# Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
for bin in $(find install -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
    # Remove last character from file output (':')
    bin="${bin::-1}"

    echo "$bin"
    patchelf --set-rpath "$DIR/../lib" "$bin"
done

# Get Clang Info
pushd "$HOME_DIR"/src/llvm-project || exit
llvm_commit="$(git rev-parse HEAD)"
short_llvm_commit="$(cut -c-8 <<<"$llvm_commit")"
popd || exit
llvm_commit_url="https://github.com/llvm/llvm-project/commit/$short_llvm_commit"
clang_version="$("$HOME_DIR"/install/bin/clang --version | head -n1 | cut -d' ' -f4)"
build_date="$(TZ=Asia/Jakarta date +"%Y-%m-%d")"
tags="Marija-Clang-$clang_version-release"
file="Marija-Clang-$clang_version.tar.gz"

# Get binutils version
binutils_version=$(grep "LATEST_BINUTILS_RELEASE" build-binutils.py)
binutils_version=$(echo "$binutils_version" | grep -oP '\(\s*\K\d+,\s*\d+,\s*\d+' | tr -d ' ')
binutils_version=$(echo "$binutils_version" | tr ',' '.')

# Create simple info
pushd "$HOME_DIR"/install || exit
{
    echo "build date: $build_date
clang version: $clang_version
binutils version: $binutils_version
llvm commit: $llvm_commit_url"
} > README.md
tar -czvf ../"$file" .
popd || exit

# Check tags already exists or not
overwrite=y
git tag -l | grep "$tags" || overwrite=n

# Upload to github release
failed=n
if [ "$overwrite" == "y" ]; then
    ./github-release edit \
        --security-token "$GH_TOKEN" \
        --user "$GH_USER" \
        --repo "$GH_REPO" \
        --tag "$tags" \
        --description "$(cat "$HOME_DIR"/install/README.md)"

    ./github-release upload \
        --security-token "$GH_TOKEN" \
        --user "$GH_USER" \
        --repo "$GH_REPO" \
        --tag "$tags" \
        --name "$file" \
        --file "$HOME_DIR/$file" \
        --replace || failed=y
else
    ./github-release release \
        --security-token "$GH_TOKEN" \
        --user "$GH_USER" \
        --repo "$GH_REPO" \
        --tag "$tags" \
        --description "$(cat "$HOME_DIR"/install/README.md)"

    ./github-release upload \
        --security-token "$GH_TOKEN" \
        --user "$GH_USER" \
        --repo "$GH_REPO" \
        --tag "$tags" \
        --name "$file" \
        --file "$HOME_DIR/$file" || failed=y
fi

# Handle uploader if upload failed
while [ "$failed" == "y" ]; do
    failed=n
    msg "Upload again"
    ./github-release upload \
        --security-token "$GH_TOKEN" \
        --user "$GH_USER" \
        --repo "$GH_REPO" \
        --tag "$tags" \
        --name "$file" \
        --file "$HOME_DIR/$file" \
        --replace || failed=y
done

# Send message to telegram
send_msg "gh $RUN_NUM: done in $((SECONDS / 60))m and $((SECONDS % 60))s%nlgh $RUN_NUM: clang version: $clang_version%nlgh $RUN_NUM: binutils version: $binutils_version%nlgh $RUN_NUM: llvm commit: $llvm_commit_url"
