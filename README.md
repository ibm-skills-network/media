![Build Status](https://github.com/ibm-skills-network/mark/actions/workflows/release.yml/badge.svg)

# Media - GPU-Accelerated Video Transcoding Service

**Media** is a high-performance video transcoding service built with Rails that leverages NVIDIA CUDA hardware acceleration to efficiently transcode videos to multiple quality levels. The service processes videos asynchronously using background jobs and stores outputs to cloud storage.

---

## Quick Links

- [Getting Started](#getting-started)
- [Key Features](#key-features)
- [Technology Stack](#technology-stack)
- [API Documentation](#api-documentation)
- [Setup Guide](#setup-guide)
- [Architecture Overview](#architecture-overview)

---

## Getting Started

### Prerequisites

**Required:**
- Ruby 3.4.7
- PostgreSQL 14+
- Redis 7+
- FFmpeg with CUDA support
- NVIDIA GPU with NVENC/NVDEC support
- NVIDIA CUDA Toolkit 12.0.1

**Optional:**
- Docker & Docker Compose
- asdf version manager

### Quick Setup

1. **Clone the repository**

   ```bash
   git clone <repository-url>
   cd media
   ```

2. **Install dependencies**

   ```bash
   # Using asdf for version management
   asdf install

   # Install Ruby gems
   bundle install
   ```

3. **Start services and setup database**

   ```bash
   # Start PostgreSQL and Redis
   docker-compose up -d

   # Create database, load schema, and seed transcoding profiles
   bin/rails db:setup
   ```

4. **Start the application**

   ```bash
   # Start web server and background workers
   bin/dev
   ```

5. **Access the application**
   - API: http://localhost:3009
   - Sidekiq UI: http://localhost:3009/sidekiq

---

## Key Features

### Core Capabilities
- **GPU-Accelerated Transcoding** - NVIDIA CUDA hardware encoding/decoding with NVENC/NVDEC
- **Multiple Quality Profiles** - Automatic transcoding to 480p, 720p, and 1080p
- **AV1 Encoding** - Modern AV1 codec with hardware acceleration (av1_nvenc)
- **Asynchronous Processing** - Background job processing with Sidekiq
- **Quality Validation** - Automatic resolution detection and upscaling prevention
- **Cloud Storage** - S3 and IBM Cloud Object Storage integration
- **RESTful API** - JWT-authenticated API endpoints
- **Concurrent Processing** - Multi-queue job management with dedicated GPU queue

### Supported Formats

**Input Video Formats:**
- MP4 (video/mp4)
- WebM (video/webm)
- QuickTime/MOV (video/quicktime)

**Output Specifications:**
| Quality | Resolution | Codec | Video Bitrate | Audio |
|---------|-----------|-------|---------------|-------|
| 480p | 854×480 | av1_nvenc | 1000k | AAC 128k |
| 720p | 1280×720 | av1_nvenc | 1800k | AAC 128k |
| 1080p | 1920×1080 | av1_nvenc | 2900k | AAC 128k |

---

## Technology Stack

| Component | Technology |
|-----------|-----------|
| **Framework** | Ruby on Rails 8.1.0 (API-only) |
| **Language** | Ruby 3.4.7 |
| **Database** | PostgreSQL 16 with pgvector |
| **Cache/Queue** | Redis 7 |
| **Job Processing** | Sidekiq 8.x with sidekiq-cron |
| **Web Server** | Puma |
| **Video Processing** | FFmpeg with CUDA 12.0.1 |
| **GPU Acceleration** | NVIDIA NVENC, NVDEC, CUVID, LibNPP |
| **Storage** | Active Storage (S3/IBM COS) |
| **Authentication** | JWT |
| **Testing** | RSpec 6.0+, FactoryBot |
| **Monitoring** | Instana APM |
| **CI/CD** | GitHub Actions |

---

## API Documentation

### Base URL
```
http://localhost:3009/api/v1/async/videos/qualities
```

### Authentication
All endpoints require JWT authentication (except in development mode).

```bash
Authorization: Bearer <jwt_token>
```

JWT token must contain `admin: true` claim.

### Endpoints

#### Create Transcoding Job

**POST** `/api/v1/async/videos/qualities`

Request:
```json
{
  "external_video_link": "https://example.com/video.mp4",
  "transcoding_profile_label": "720p"
}
```

Response (201 Created):
```json
{
  "id": 1,
  "label": "720p",
  "status": "pending"
}
```

**Parameters:**
- `external_video_link` (string, required) - URL to source video
- `transcoding_profile_label` (string, required) - Quality level: `"480p"`, `"720p"`, or `"1080p"`

#### Get Quality Status

**GET** `/api/v1/async/videos/qualities/:id`

Response (200 OK):
```json
{
  "status": "success",
  "url": "https://s3.amazonaws.com/bucket/video.mp4",
  "label": "720p"
}
```

**Status Values:**
- `pending` - Job queued but not started
- `processing` - Currently transcoding
- `success` - Transcoding completed successfully
- `failed` - Transcoding failed
- `unavailable` - Source video inaccessible or lower quality than requested

---

## Setup Guide

### Development Setup

#### 1. Install System Dependencies

**Ubuntu/Debian:**
```bash
# Install Docker and Docker Compose (recommended)
# PostgreSQL and Redis will run via docker-compose

# FFmpeg with CUDA (see Docker build for full instructions)
# Or use Docker image: icr.io/skills-network/media/ffmpeg:0.2.3
```

**macOS:**
```bash
# Install Docker Desktop (includes Docker Compose)
# PostgreSQL and Redis will run via docker-compose
```

#### 2. Environment Variables

Create `config/settings/development.local.yml`:
```yaml
jwt_secret: your_development_jwt_secret

sidekiq:
  credentials:
    username: admin
    password: password
```

For production, use environment variables:
```bash
# Rails
export RAILS_ENV=production
export SECRET_KEY_BASE=your_secret_key
export PORT=3000

# JWT
export SETTINGS_JWT_SECRET=your_jwt_secret

# Database - Use your production database URL
export DATABASE_URL=your_database_url

# Redis - Production uses Redis Sentinel for high availability
export REDIS_URL=your_redis_sentinel_url

# Storage (S3/IBM COS)
export SETTINGS_IBMCOS_ACCESS_KEY_ID=your_key
export SETTINGS_IBMCOS_SECRET_ACCESS_KEY=your_secret
export SETTINGS_IBMCOS_ENDPOINT=https://s3.region.cloud-object-storage.appdomain.cloud
export SETTINGS_IBMCOS_REGION=us-south
export SETTINGS_IBMCOS_BUCKET=your_bucket
```

### Docker Setup

#### Build Images

**Build FFmpeg with CUDA:**
```bash
cd utils/ffmpeg
docker build -t ffmpeg-cuda:latest .
```

**Build Application:**
```bash
# From project root
docker build -t media:latest .
```

#### Run with Docker Compose

```bash
# Start PostgreSQL and Redis
docker-compose up -d

# Run application
docker run -p 3009:3009 \
  -e DATABASE_URL=postgresql://postgres:password@host.docker.internal:5437/media_development \
  -e REDIS_URL=redis://host.docker.internal:6381 \
  --gpus all \
  media:latest
```

**Note:** GPU access requires NVIDIA Docker runtime (`--gpus all` flag).

---

## Testing

### Running Tests

```bash
# All tests
bundle exec rspec

# Specific test file
bundle exec rspec spec/models/videos/quality_spec.rb

# With coverage report
bundle exec rspec --format documentation
```

### Test Structure

```
spec/
├── models/          # Model tests
├── jobs/            # Background job tests
├── requests/        # API endpoint tests
├── factories/       # Test data factories
└── support/         # Shared contexts and helpers
```

### Test Database

Tests use a separate database (`media_test`) configured in `config/database.yml`.

---

## Architecture Overview

### Request Flow

1. **API Request** → `QualitiesController` creates `Videos::Quality` record with status `pending`
2. **Job Enqueue** → `Videos::EncodeQualityJob` queued to `gpu` queue in Sidekiq
3. **Job Processing**:
   - Download video from `external_video_link`
   - Validate resolution meets profile requirements
   - Transcode using FFmpeg with CUDA acceleration
   - Upload output to cloud storage (Active Storage)
   - Update status to `success` or `failed`
4. **Status Check** → Client polls GET endpoint for completion

### Database Schema

**videos_qualities**
- `id`, `transcoding_profile_id`, `external_video_link`, `status`, `created_at`, `updated_at`
- Has one attached `video_file` via Active Storage

**videos_qualities_transcoding_profiles**
- `id`, `label`, `codec`, `width`, `height`, `bitrate_string`, `bitrate_int`, `created_at`, `updated_at`

### Background Jobs

**Queue Priority:**
- `critical` - Highest priority
- `high` - High priority
- `gpu` - **GPU-intensive encoding jobs**
- `default` - Normal priority
- `low` - Lowest priority

**Job Class:** `Videos::EncodeQualityJob`
- Queue: `gpu`
- Retry: Enabled with exhaustion handler
- Timeout: Default Sidekiq timeout

### FFmpeg Integration

The service uses a custom FFmpeg wrapper (`lib/ffmpeg/video.rb`) that:
- Executes FFmpeg commands with CUDA flags
- Extracts video metadata (resolution, codec, bitrate)
- Handles tempfile management
- Provides error handling and logging

**Key FFmpeg Options:**
```bash
ffmpeg -hwaccel cuda -hwaccel_output_format cuda \
  -i input.mp4 \
  -c:v av1_nvenc -preset p4 -b:v 1800k \
  -vf scale_cuda=1280:720 \
  -c:a aac -b:a 128k -ac 2 \
  output.mp4
```

### Storage Architecture

**Development:** Local disk storage
**Production:** S3-compatible storage (AWS S3 or IBM Cloud Object Storage)

Files managed by Active Storage with automatic attachment handling.

---

## Configuration

### Settings Management

The application uses the `config` gem for settings:

**Load Order:**
1. `config/settings.yml` - Base settings
2. `config/settings/#{Rails.env}.yml` - Environment-specific
3. `config/settings/#{Rails.env}.local.yml` - Local overrides (gitignored)
4. Environment variables with `SETTINGS_` prefix

### Key Settings

Access settings via `Settings.key`:
```ruby
Settings.jwt_secret
Settings.sidekiq.credentials.username
Settings.ibmcos.bucket
```

Override with environment variables:
```bash
export SETTINGS_JWT_SECRET=secret
export SETTINGS_SIDEKIQ__CREDENTIALS__USERNAME=admin
```

---

## GPU Requirements

### Hardware
- NVIDIA GPU with NVENC/NVDEC support (e.g., GeForce RTX 20/30/40 series, Tesla, Quadro)
- Minimum 4GB VRAM recommended
- CUDA Compute Capability 5.0+

### Software
- NVIDIA Driver 525.60.13+
- CUDA Toolkit 12.0.1
- NVIDIA Docker runtime (for containerized deployment)

### Verify GPU Access

```bash
# Check NVIDIA driver
nvidia-smi

# Check CUDA
nvcc --version

# Test FFmpeg CUDA support
ffmpeg -hwaccels  # Should list 'cuda'
ffmpeg -encoders | grep nvenc  # Should show av1_nvenc
```

---

## Monitoring & Observability

### Sidekiq Web UI
- URL: `/sidekiq`
- Monitor job queues, retries, and dead jobs
- View job processing stats

### Health Check
- URL: `/up`
- Returns 200 OK if application is healthy

### Logging
- Rails logs: `log/development.log`
- Sidekiq logs: STDOUT (captured by process manager)

### Production Monitoring
- Instana APM integration enabled in production
- Tracks performance, errors, and traces

---

## CI/CD

### GitHub Actions Workflows

**Lint** (`.github/workflows/lint.yml`)
- Runs Rubocop on pull requests
- Uses Reviewdog for inline PR comments

**Test** (`.github/workflows/rspec-tests.yml`)
- Runs RSpec test suite
- Compares code coverage
- Requires PostgreSQL and Redis services

**Release** (`.github/workflows/release.yml`)
- Builds and pushes Docker images
- Detects FFmpeg Dockerfile changes
- Publishes to IBM Container Registry

---

## Deployment

### Docker Deployment

```bash
# Build images
docker build -t media:latest .

# Run with GPU support
docker run --gpus all \
  -p 3000:3000 \
  -e RAILS_ENV=production \
  -e SECRET_KEY_BASE=... \
  -e DATABASE_URL=... \
  -e REDIS_URL=... \
  -e SETTINGS_JWT_SECRET=... \
  media:latest
```

### Production Checklist

- [ ] Configure production database with connection pooling
- [ ] Set up Redis with persistence
- [ ] Configure S3/IBM COS credentials
- [ ] Set `SECRET_KEY_BASE` and `SETTINGS_JWT_SECRET`
- [ ] Enable Instana monitoring
- [ ] Configure NVIDIA Docker runtime
- [ ] Set up log aggregation
- [ ] Configure backup strategy for PostgreSQL
- [ ] Set up SSL/TLS termination
- [ ] Configure rate limiting
- [ ] Set appropriate Sidekiq concurrency

### Scaling Considerations

**Horizontal Scaling:**
- Run multiple Puma processes
- Add more Sidekiq workers
- Use dedicated GPU workers for encoding jobs

**Vertical Scaling:**
- Increase GPU memory for higher resolution videos
- Add more CPU cores for Sidekiq concurrency
- Increase database connection pool size

---

## Troubleshooting

### Common Issues

**GPU not detected:**
```bash
# Verify NVIDIA driver
nvidia-smi

# Check Docker GPU access
docker run --rm --gpus all nvidia/cuda:12.0.1-base-ubuntu22.04 nvidia-smi
```

**FFmpeg encoding fails:**
```bash
# Check CUDA support
ffmpeg -hwaccels
ffmpeg -encoders | grep nvenc

# Test encoding
ffmpeg -hwaccel cuda -i input.mp4 -c:v av1_nvenc output.mp4
```

**Database connection issues:**
```bash
# Check PostgreSQL
psql postgresql://postgres:password@localhost:5437/media_development

# Verify DATABASE_URL
echo $DATABASE_URL
```

**Sidekiq jobs not processing:**
```bash
# Check Redis
redis-cli -h localhost -p 6381 ping

# Verify Sidekiq is running
ps aux | grep sidekiq

# Check Sidekiq logs
tail -f log/sidekiq.log
```

---

## Development

### Code Style
- Follow Rubocop rules (`.rubocop.yml`)
- Run linter: `bundle exec rubocop`
- Auto-fix: `bundle exec rubocop -a`

### Database Migrations
```bash
# Create migration
bin/rails generate migration AddFieldToTable

# Run migrations
bin/rails db:migrate

# Rollback
bin/rails db:rollback
```

### Adding Transcoding Profiles
Profiles are seeded via data migrations in `db/data/`. To add a new profile:
1. Create profile record in data migration
2. Define encoding parameters (codec, bitrate, resolution)
3. Run: `bin/rails db:data:migrate`

---

## License

Apache License 2.0

---

## Acknowledgments

Built with Ruby on Rails, FFmpeg, NVIDIA CUDA, PostgreSQL, Redis, and Sidekiq.

Special thanks to the open-source community for the amazing tools and libraries.
