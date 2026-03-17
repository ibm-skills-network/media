# Dockerfile for building FFmpeg with CUDA support
# This image can be used as a base for the main application
# Build with: docker build -f utils/ffmpeg/Dockerfile -t patch-ffmpeg-cuda:latest .

# --- Stage 1: Build ---
FROM nvidia/cuda:12.0.1-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /tmp

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential yasm nasm cmake libtool unzip wget git pkg-config \
    libnuma-dev libssl-dev libx264-dev libvpx-dev libopus-dev libpng-dev \
    zlib1g-dev libopenh264-dev \
    && rm -rf /var/lib/apt/lists/*

# Install NVIDIA codec headers
RUN git clone https://github.com/FFmpeg/nv-codec-headers.git && \
    cd nv-codec-headers && make install PREFIX=/usr && cd .. && rm -rf nv-codec-headers

# Build FFmpeg
RUN git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git && \
    cd ffmpeg && \
    ./configure \
        --prefix=/usr/local \
        --enable-gpl \
        --enable-version3 \
        --enable-nonfree \
        --enable-shared \
        --enable-cuda-nvcc \
        --enable-cuvid \
        --enable-nvenc \
        --enable-nvdec \
        --enable-libnpp \
        --enable-libx264 \
        --enable-libvpx \
        --enable-libopus \
        --enable-libopenh264 \
        --enable-openssl \
        --extra-cflags="-I/usr/local/cuda/include" \
        --extra-ldflags="-L/usr/local/cuda/lib64" && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/ffmpeg

# --- Stage 2: Runtime ---
FROM nvidia/cuda:12.0.1-runtime-ubuntu22.04 AS release

ENV DEBIAN_FRONTEND=noninteractive
# Ensure the system looks for libraries in /usr/local/lib
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"

# Install runtime dependencies
# libopenh264-cisco6 downloads the official Cisco pre-compiled binary at install
# time, which is required for H.264 patent compliance under Cisco's MPEG-LA license.
# See: https://launchpad.net/ubuntu/jammy/+package/libopenh264-cisco6
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnuma1 ca-certificates libssl3 libx264-163 libvpx7 libopus0 \
    libpng16-16 zlib1g libopenh264-cisco6 \
    && rm -rf /var/lib/apt/lists/*

# Copy binaries and compiled libraries from builder
COPY --from=builder /usr/local/bin/ffmpeg /usr/local/bin/
COPY --from=builder /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=builder /usr/local/lib/ /usr/local/lib/

# Update linker cache
RUN ldconfig

# Verify installation
RUN ffmpeg -version

CMD ["/bin/bash"]
