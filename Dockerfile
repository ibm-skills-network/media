# Stage 1: Build FFmpeg with CUDA support
FROM nvidia/cuda:12.0.1-devel-ubuntu22.04 AS ffmpeg-builder

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/local/cuda/bin:${PATH}"

WORKDIR /app

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
    && rm -rf /var/lib/apt/lists/*

# Install NVIDIA codec headers
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git /tmp/nv-codec-headers && \
    cd /tmp/nv-codec-headers && \
    make install PREFIX=/usr && \
    cd -

# Build FFmpeg
RUN git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git /tmp/ffmpeg && \
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
FROM ubuntu:22.04 AS builder

ENV APP_HOME /app
ENV RAILS_ENV production
ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /app
USER root

# Install Ruby 3.4.6 from source
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    wget \
    libssl-dev \
    libreadline-dev \
    zlib1g-dev \
    libyaml-dev \
    libffi-dev \
    libgmp-dev \
    git \
    libpq-dev \
    nodejs \
    npm \
    && wget https://cache.ruby-lang.org/pub/ruby/3.4/ruby-3.4.6.tar.gz \
    && tar -xzf ruby-3.4.6.tar.gz \
    && cd ruby-3.4.6 \
    && ./configure --disable-install-doc \
    && make -j$(nproc) \
    && make install \
    && cd .. \
    && rm -rf ruby-3.4.6 ruby-3.4.6.tar.gz \
    && gem install bundler \
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local deployment 'true' \
    && bundle config set --local without 'development test' \
    && bundle install --jobs="$(nproc --all)" --frozen --retry 3 -j4 \
    && find /usr/local/lib/ruby/gems -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true

COPY bin ./bin
COPY config ./config
COPY db ./db
COPY lib ./lib
COPY app/models ./app/models
COPY Rakefile config.ru ./
COPY app ./app
ENV SECRET_KEY_BASE=dummysecret


# Stage 3: Production image - Switch to Ubuntu base for glibc compatibility
FROM nvidia/cuda:12.0.1-runtime-ubuntu22.04 AS release
USER root
ENV APP_HOME /app
ENV SECRET_KEY_BASE=dummysecret
ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    tzdata \
    file \
    libpq5 \
    libnuma1 \
    ca-certificates \
    libyaml-0-2 \
    libssl3 \
    libreadline8 \
    zlib1g \
    libffi8 \
    libgmp10 \
    && rm -rf /var/lib/apt/lists/*

# Copy Ruby and all dependencies from builder
COPY --from=builder /usr/local/bin/ruby /usr/local/bin/ruby
COPY --from=builder /usr/local/bin/gem /usr/local/bin/gem
COPY --from=builder /usr/local/bin/bundle /usr/local/bin/bundle
COPY --from=builder /usr/local/bin/bundler /usr/local/bin/bundler
COPY --from=builder /usr/local/lib/ruby /usr/local/lib/ruby
COPY --from=builder /usr/local/lib/libruby.so* /usr/local/lib/
COPY --from=builder /usr/local/include/ruby-3.4.0 /usr/local/include/ruby-3.4.0
COPY --from=builder $APP_HOME $APP_HOME

# Copy FFmpeg binaries + libs from ffmpeg-builder (careful not to overwrite Ruby libs)
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/lib/libav*.so* /usr/local/lib/
COPY --from=ffmpeg-builder /usr/local/lib/libsw*.so* /usr/local/lib/
COPY --from=ffmpeg-builder /usr/local/lib/libpostproc*.so* /usr/local/lib/
# Copy CUDA runtime libraries needed for FFmpeg
COPY --from=ffmpeg-builder /usr/local/cuda/lib64/ /usr/local/cuda/lib64/

RUN ldconfig

WORKDIR $APP_HOME

ENV USER=skillsnetwork
ENV UID=1001
RUN useradd -m -u $UID $USER
RUN chown -R $USER:$USER $APP_HOME

USER $USER

ENTRYPOINT ["bin/rails"]
CMD ["server", "-b", "0.0.0.0"]
