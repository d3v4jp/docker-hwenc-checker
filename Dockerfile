# GPU のハードウェアエンコード対応を調べるコンテナ (VA-API / QSV / NVENC)
#   docker build -t hwenc-check .
#   docker run --rm --device /dev/dri hwenc-check qsv       # Intel (VA-API は vaapi、両方は intel)
#   docker run --rm --gpus all hwenc-check nvenc            # NVIDIA (NVIDIA Container Toolkit が必要)
ARG BASE_IMAGE=debian:trixie-slim
FROM ${BASE_IMAGE}

# Ice Lake 以前の Intel GPU で QSV を使うための Media SDK ランタイム (libmfx1) を入れるか (1 = 入れる / 0 = 入れない)
# libmfx1 は Debian trixie で削除されたので、ベースイメージのリポジトリに無いときは bookworm から入れる
ARG LIBMFX1=1

ENV DEBIAN_FRONTEND=noninteractive
# NVENC 用。--gpus を付けたとき、NVIDIA Container Toolkit がエンコード用ライブラリ (video) と nvidia-smi (utility) を入れる
# ffmpeg は NVENC のライブラリを実行時に読み込むので、イメージに NVIDIA のパッケージは要らない
ENV NVIDIA_DRIVER_CAPABILITIES=video,utility

# Intel の HEVC エンコードには non-free の Intel Media Driver (iHD) が必要なので、contrib / non-free も有効にする
#   intel-media-va-driver-non-free : Intel Broadwell 以降の VA-API ドライバ (iHD)
#   mesa-va-drivers                : AMD の VA-API ドライバ (radeonsi)
# 次のものはリポジトリにあるときだけ入れる
#   libmfx-gen1.2                  : Intel Tiger Lake 以降の QSV ランタイム (oneVPL)
#   i965-va-driver-shaders         : Intel Haswell 以前の VA-API ドライバ (i965、エンコード用シェーダー入り)
#   pci.ids                        : lspci で GPU の名前を出すための一覧
# libmfx1 (Intel Ice Lake 以前の QSV ランタイム、Media SDK) は LIBMFX1=1 のときに入れる
#   ffmpeg (oneVPL のディスパッチャ) は、新しいランタイムが使えない GPU では Media SDK のランタイムを読み込む
#   ベースイメージのリポジトリに無いときは、libmfx1 だけを bookworm から入れる
#   依存するライブラリはベースイメージのものを使い、入れ終わったら bookworm のリポジトリは外す
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
        mesa-va-drivers; \
    for p in libmfx-gen1.2 i965-va-driver-shaders pci.ids; do \
        if apt-cache show "$p" >/dev/null 2>&1; then \
            apt-get install -y --no-install-recommends "$p"; \
        fi; \
    done; \
    if [ "$LIBMFX1" = 1 ]; then \
        if apt-cache show libmfx1 >/dev/null 2>&1; then \
            apt-get install -y --no-install-recommends libmfx1; \
        else \
            printf '%s\n' 'Types: deb' 'URIs: http://deb.debian.org/debian' 'Suites: bookworm' 'Components: main' \
                'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' > /etc/apt/sources.list.d/bookworm.sources; \
            apt-get update; \
            apt-get install -y --no-install-recommends libmfx1; \
            rm -f /etc/apt/sources.list.d/bookworm.sources; \
        fi; \
    fi; \
    rm -rf /var/lib/apt/lists/*

COPY --chmod=755 hwenc-check.sh /usr/local/bin/hwenc-check

ENTRYPOINT ["hwenc-check"]
