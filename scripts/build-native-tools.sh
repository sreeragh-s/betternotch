#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
base="$PWD/.build/native"
mkdir -p "$base/lib" "$base/licenses"
if ! command -v cmake >/dev/null 2>&1; then
    if [ ! -x "$base/tooling/bin/cmake" ]; then
        python3 -m venv "$base/tooling"
        "$base/tooling/bin/pip" install 'cmake==4.4.4'
    fi
    export PATH="$base/tooling/bin:$PATH"
fi
if [ ! -d "$base/whisper-source/.git" ]; then
    git clone --depth 1 --branch v1.9.5 https://github.com/ggml-org/whisper.cpp.git "$base/whisper-source"
fi
[ "$(git -C "$base/whisper-source" rev-parse HEAD)" = 'd1be6fde11ac6e0407606b4e42fe72d34add8037' ]
cmake -S "$base/whisper-source" -B "$base/whisper-build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DGGML_OPENMP=OFF
cmake --build "$base/whisper-build" --config Release -j 4
archives=()
while IFS= read -r archive; do archives+=("$archive"); done < <(find "$base/whisper-build" -name '*.a')
xcrun clang++ -std=c++17 -O2 -dynamiclib -mmacosx-version-min=14.0 Native/WhisperBridge.cpp -I "$base/whisper-source/include" -I "$base/whisper-source/ggml/include" "${archives[@]}" -framework Foundation -framework Accelerate -framework Metal -framework MetalKit -install_name @rpath/libSMMWhisper.dylib -o "$base/lib/libSMMWhisper.dylib"
cp "$base/whisper-source/LICENSE" "$base/licenses/whisper.cpp-LICENSE"
# libwebp's output is optional only for development builds; the packaged release includes it.
if [ ! -d "$base/webp-source/.git" ]; then
    git clone --depth 1 --branch v1.5.0 https://github.com/webmproject/libwebp.git "$base/webp-source"
fi
[ "$(git -C "$base/webp-source" rev-parse HEAD)" = 'a4d7a715337ded4451fec90ff8ce79728e04126c' ]
cmake -S "$base/webp-source" -B "$base/webp-build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=ON -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF
cmake --build "$base/webp-build" --config Release --target webp -j 4
cp -L "$base/webp-build/libwebp.dylib" "$base/lib/libwebp.dylib"
cp -L "$base/webp-build/libsharpyuv.0.dylib" "$base/lib/libsharpyuv.0.dylib"
install_name_tool -change @rpath/libsharpyuv.0.dylib @loader_path/libsharpyuv.0.dylib "$base/lib/libwebp.dylib"
install_name_tool -id @rpath/libwebp.dylib "$base/lib/libwebp.dylib"
cp "$base/webp-source/COPYING" "$base/licenses/libwebp-LICENSE"
