# GPU のハードウェアエンコード対応を調べるコンテナ (VA-API / QSV / NVENC)
#   docker build -t hwenc-check .
#   docker run --rm --device /dev/dri hwenc-check qsv       # Intel (VA-API は vaapi、両方は intel)
#   docker run --rm --gpus all hwenc-check nvenc            # NVIDIA (NVIDIA Container Toolkit が必要)
ARG BASE_IMAGE=debian:trixie-slim
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
# NVENC 用。--gpus を付けたとき、NVIDIA Container Toolkit がエンコード用ライブラリ (video) と nvidia-smi (utility) を入れる
# ffmpeg は NVENC のライブラリを実行時に読み込むので、イメージに NVIDIA のパッケージは要らない
ENV NVIDIA_DRIVER_CAPABILITIES=video,utility

# Intel の HEVC エンコードには non-free の Intel Media Driver (iHD) が必要なので、contrib / non-free も有効にする
#   intel-media-va-driver-non-free : Intel Broadwell 以降の VA-API ドライバ (iHD)
#   mesa-va-drivers                : AMD の VA-API ドライバ (radeonsi)
#   libmfx-gen1.2                  : Intel Tiger Lake 以降の QSV ランタイム (oneVPL)
# 次のものはリポジトリにあるときだけ入れる
#   i965-va-driver-shaders         : Intel Haswell 以前の VA-API ドライバ (i965、エンコード用シェーダー入り)
#   libmfx1                        : Intel Ice Lake 以前の QSV ランタイム (Media SDK)
#   pci.ids                        : lspci で GPU の名前を出すための一覧
RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i -E 's/^(Components:.*main)$/\1 contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        vainfo \
        pciutils \
        intel-media-va-driver-non-free \
        mesa-va-drivers \
        libmfx-gen1.2; \
    for p in i965-va-driver-shaders libmfx1 pci.ids; do \
        if apt-cache show "$p" >/dev/null 2>&1; then \
            apt-get install -y --no-install-recommends "$p"; \
        fi; \
    done; \
    rm -rf /var/lib/apt/lists/*

COPY --chmod=755 hwenc-check.sh /usr/local/bin/hwenc-check

ENTRYPOINT ["hwenc-check"]
