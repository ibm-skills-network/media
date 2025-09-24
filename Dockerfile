# Rails application with CUDA FFmpeg support
FROM nvidia/cuda:12.0.1-devel-ubuntu22.04 AS ffmpeg-builder

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/local/cuda/bin:${PATH}"

WORKDIR /app

# Install build tools for FFmpeg
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    yasm \
    cmake \
    libtool \
    libc6 \
    libc6-dev \
    unzip \
    wget \
    libnuma1 \
    libnuma-dev \
    git \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Install NVIDIA codec headers
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git /tmp/nv-codec-headers && \
    cd /tmp/nv-codec-headers && \
    make install PREFIX=/usr && \
    cd -

# Build and install FFmpeg with CUDA and AV1 support
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

# Rails application stage
FROM icr.io/skills-network/ruby:3 as builder

ENV APP_HOME /app
ENV RAILS_ENV production

WORKDIR /app

USER root

RUN apk upgrade

# Install Gem
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
COPY public ./public
COPY app/views ./app/views
COPY app/models ./app/models

# Config files
COPY Rakefile config.ru ./


# Compile/transpile static assets
# Added SECRET_KEY_BASE=dummysecret as it fixes an error in the assets:precompile job
RUN SECRET_KEY_BASE=dummysecret \
    MEDIA_URL=https://localhost:3000 \
    bundle exec bin/rake assets:precompile

COPY app ./app

USER 1001

# Production image build
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

COPY --from=builder /usr/local/bundle/ /usr/local/bundle/
COPY --from=builder $APP_HOME $APP_HOME

WORKDIR $APP_HOME
USER 1001
ENTRYPOINT ["bin/rails"]
CMD ["server", "-b", "0.0.0.0"]

# Default to `release`
FROM release AS monkey-patched
USER root

ENV APP_HOME /app
ENV RAILS_ENV production
ENV SECRET_KEY_BASE=dummysecret

ENV USER=skillsnetwork
ENV UID=1001
RUN adduser --disabled-password --gecos "" --uid $UID $USER
RUN chown -R $USER:$USER $APP_HOME

RUN apk upgrade --update-cache \
    busybox \
    ssl_client \
    libpq \
    expat \
    bind-libs\
    bind-tools\
  && rm -rf /var/cache/apk/*

USER 1001
