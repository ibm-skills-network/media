# Media - GPU-Accelerated Video Transcoding Service

A video transcoding service built with Rails that leverages NVIDIA CUDA hardware acceleration to transcode videos to multiple quality levels. The service processes videos asynchronously using background jobs and stores outputs to cloud storage.

## Getting Started

### Prerequisites

- Ruby 3.4.7
- FFmpeg with CUDA support
- NVIDIA GPU with NVENC/NVDEC support
- Docker & Docker Compose

### Setup

1. **Clone the repository**

   ```bash
   git clone <repository-url>
   cd media
   ```

2. **Install dependencies**

   ```bash
   bundle install
   ```

3. **Start services and setup database**

   ```bash
   docker-compose up -d
   bin/rails db:create
   bin/rails db:prepare
   bin/rails data:migrate
   ```

4. **Start the application**

   ```bash
   bin/dev
   ```

5. **Access the application**
   - API: http://localhost:3009
   - Sidekiq UI: http://localhost:3009/sidekiq

## Key Features

- **GPU-Accelerated Transcoding** - NVIDIA CUDA hardware encoding/decoding
- **Multiple Quality Profiles** - Automatic transcoding to 480p, 720p, and 1080p
- **AV1 Encoding** - Modern AV1 codec with hardware acceleration
- **Asynchronous Processing** - Background job processing with Sidekiq
- **Cloud Storage** - S3 and IBM Cloud Object Storage integration

## GPU Compatibility

This service requires an NVIDIA GPU with AV1 NVENC support (RTX 40 series or newer). See the [NVIDIA Video Encode and Decode GPU Support Matrix](https://developer.nvidia.com/video-encode-and-decode-gpu-support-matrix-new) for compatible hardware.

FFmpeg is compiled from source with CUDA support. To build the FFmpeg image locally:

```bash
docker build -f utils/ffmpeg/Dockerfile -t ffmpeg-cuda:latest .
```

## Testing

```bash
bundle exec rspec
```

## License

Apache License 2.0
