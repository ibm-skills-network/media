# Dockerfile for building FFmpeg with CUDA support
# This image can be used as a base for the main application
# Build with: docker build -f utils/ffmpeg/Dockerfile -t patch-ffmpeg-cuda:latest .

FROM nvidia/cuda:12.0.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/local/cuda/bin:${PATH}"

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    yasm \
    nasm \
    cmake \
    libtool \
    unzip \
    wget \
    git \
    pkg-config \
    libnuma1 \
    libnuma-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Install NVIDIA codec headers
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git /tmp/nv-codec-headers && \
    cd /tmp/nv-codec-headers && \
    make install PREFIX=/usr && \
    cd - && \
    rm -rf /tmp/nv-codec-headers

# Build FFmpeg with CUDA support
RUN git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git /tmp/ffmpeg && \
    cd /tmp/ffmpeg && \
    ./configure \
        --enable-nonfree \
        --enable-cuda-nvcc \
        --enable-cuvid \
        --enable-nvenc \
        --enable-nvdec \
        --enable-libnpp \
        --enable-openssl \
        --extra-cflags=-I/usr/local/cuda/include \
        --extra-ldflags=-L/usr/local/cuda/lib64 \
        --disable-static \
        --enable-shared && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /tmp/ffmpeg

# Switch to runtime base to reduce image size
FROM nvidia/cuda:12.0.1-runtime-ubuntu22.04 AS release

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnuma1 \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Copy FFmpeg binaries and libraries from builder
COPY --from=0 /usr/local/bin/ffmpeg /usr/local/bin/
COPY --from=0 /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=0 /usr/local/lib/libav*.so* /usr/local/lib/
COPY --from=0 /usr/local/lib/libsw*.so* /usr/local/lib/
COPY --from=0 /usr/local/lib/libpostproc*.so* /usr/local/lib/
COPY --from=0 /usr/local/cuda/lib64/ /usr/local/cuda/lib64/

RUN ldconfig

# Verify installation
RUN ffmpeg -version && ffprobe -version

CMD ["/bin/bash"]
