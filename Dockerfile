# Stage 1: Build FFmpeg with CUDA support
FROM nvidia/cuda:12.0.1-devel-ubuntu22.04 AS ffmpeg-builder

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/local/cuda/bin:${PATH}"

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    yasm \
    cmake \
    libtool \
    unzip \
    wget \
    git \
    pkg-config \
    libnuma1 \
    libnuma-dev \
    && rm -rf /var/lib/apt/lists/*

# Install NVIDIA codec headers
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git /tmp/nv-codec-headers && \
    cd /tmp/nv-codec-headers && \
    make install PREFIX=/usr && \
    cd -

# Build and install FFmpeg
RUN git clone https://git.ffmpeg.org/ffmpeg.git /tmp/ffmpeg && \
    cd /tmp/ffmpeg && \
    ./configure \
        --enable-nonfree \
        --enable-cuda-nvcc \
        --enable-libnpp \
        --extra-cflags=-I/usr/local/cuda/include \
        --extra-ldflags=-L/usr/local/cuda/lib64 \
        --disable-static \
        --enable-shared && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /tmp/ffmpeg


# Stage 2: Build Rails app
FROM icr.io/skills-network/ruby:3 AS builder

ENV APP_HOME /app
ENV RAILS_ENV production

WORKDIR /app
USER root

RUN apk upgrade

COPY Gemfile Gemfile.lock ./
RUN apk add --no-cache --virtual build_deps git
RUN apk add bind-tools gcompat build-base nodejs npm
RUN apk add --no-cache postgresql-dev
RUN bundle install --jobs="$(nproc --all)" --frozen --retry 3 -j4 --without development test
RUN rm -rf /usr/local/bundle/bundler/gems/*/.git /usr/local/bundle/cache/
RUN rm -rf /var/cache/apk/*
RUN apk del build_deps

COPY bin ./bin
COPY config ./config
COPY db ./db
COPY lib ./lib
COPY app/models ./app/models
COPY Rakefile config.ru ./
COPY app ./app

USER 1001


# Stage 3: Production image
FROM icr.io/skills-network/ruby:3 AS release
USER root
ENV APP_HOME /app

RUN apk add --no-cache \
      tzdata \
      file \
      libpq \
      bind-tools \
      gcompat && \
    rm -rf /var/cache/apk/*

# Copy Rails dependencies
COPY --from=builder /usr/local/bundle/ /usr/local/bundle/
COPY --from=builder $APP_HOME $APP_HOME

# Copy FFmpeg binaries + libs from ffmpeg-builder
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/lib/ /usr/local/lib/
COPY --from=ffmpeg-builder /usr/lib/x86_64-linux-gnu/ /usr/lib/x86_64-linux-gnu/

RUN ldconfig

WORKDIR $APP_HOME
USER 1001
ENTRYPOINT ["bin/rails"]
CMD ["server", "-b", "0.0.0.0"]
