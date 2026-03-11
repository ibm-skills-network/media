---
name: background-jobs
description: Create and orchestrate background jobs with ActiveJob and Sidekiq. Use when user needs to create jobs, pipelines, polling patterns, or handle async processing with proper error handling and retry logic.
allowed-tools: Read, Grep, Glob, Edit, Write
---

# Background Jobs

Expert guidance for creating background jobs using ActiveJob + Sidekiq following established codebase patterns.

## Architecture Overview

- **Queue Backend**: Sidekiq (Redis-backed)
- **Configuration**: Jobs use `queue_as` and `sidekiq_options` for queue and retry settings

## ApplicationJob Base Class

All jobs inherit from `ApplicationJob` which provides:

```ruby
class ApplicationJob < ActiveJob::Base
  sidekiq_options retry: 5

  sidekiq_retries_exhausted do |msg, exception|
    Rails.logger.error("Failed #{msg['class']} with #{msg['args']}: #{exception.message}")
  end

  # Cached client singletons for external services
  # See app/jobs/application_job.rb for available clients
end
```

## Job Patterns

### 1. Simple Worker Job

For straightforward async work:

```ruby
class SyncMetricsJob < ApplicationJob
  queue_as :default

  def perform(course)
    MetricsService.sync(course)
  end
end

# Trigger
SyncMetricsJob.perform_later(course)
```

### 2. Polling Job (External Service)

For long-running external operations that require status checking:

```ruby
class PollExternalServiceJob < ApplicationJob
  queue_as :default
  sidekiq_options retry: 20

  # Custom error for "still processing" state
  StillProcessing = Class.new(StandardError)

  def perform(record)
    response = external_client.check_status(record.task_id)

    case response[:status]
    when "processing"
      # Re-enqueue with delay instead of raising
      self.class.set(wait: 20.seconds).perform_later(record)
    when "failed"
      record.mark_failed!(response[:error])
    when "completed"
      record.complete!(response[:data])
      # Trigger next job in pipeline
      NextStepJob.perform_later(record)
    end
  end
end
```

**Key polling conventions:**
- Re-enqueue with `set(wait:)` for polling instead of relying on retry
- Add randomized delays to prevent thundering herd: `wait: rand(15..25).seconds`
- Handle all terminal states (failed, completed) explicitly

### 3. State Machine Job

Jobs that manage record state transitions (common pattern in author-workbench):

```ruby
class ProcessContentJob < ApplicationJob
  queue_as :default
  sidekiq_options retry: 3

  def perform(record)
    record.processing!

    begin
      result = SomeService.call(record)
      record.success!
    rescue StandardError => e
      Rails.logger.error "Failed to process #{record.id}: #{e.message}"
      record.failure!
      raise e  # Re-raise to trigger Sidekiq retry
    end
  end
end
```

### 4. Initiator Job (Pipeline Starter)

Jobs that kick off a pipeline with delayed follow-up:

```ruby
class StartProcessingJob < ApplicationJob
  queue_as :default

  def perform(record)
    # Start external process
    task_id = external_client.start_processing(record.file)
    record.update!(task_id: task_id, status: :processing)

    # Schedule polling to start after initial processing time
    PollProcessingJob.set(wait: 15.seconds).perform_later(record)
  end
end
```

## Pipeline Orchestration

### Sequential Pipeline

Chain jobs where each depends on the previous:

```ruby
# Job A completes -> triggers Job B
class JobA < ApplicationJob
  def perform(record)
    result = do_work(record)
    JobB.perform_later(record) if result.success?
  end
end

# Job B completes -> triggers Job C (with delay)
class JobB < ApplicationJob
  def perform(record)
    do_more_work(record)
    JobC.set(wait: 10.seconds).perform_later(record)
  end
end
```

## Error Handling Patterns

### Preferred: Use `sidekiq_retries_exhausted` for Failure State

**Accessing job arguments in `sidekiq_retries_exhausted`:**
- ActiveJob serializes arguments differently than Sidekiq
- Use `msg["args"].first["arguments"]` to get the arguments array
- First argument: `msg["args"].first["arguments"].first`

### Legacy Pattern (Avoid)

```ruby
class MyJob < ApplicationJob
  queue_as :low
  sidekiq_options retry: 3

  def perform(record)
    record.processing!

    # Do work here
    result = SomeService.call(record)

    if result.success?
      record.success!
    else
      record.failure!
    end
  rescue StandardError => e
    Rails.logger.error "Job failed: #{e.message}"
    record.failure!
    raise e  # Re-raise for Sidekiq retry
  end
end
```

### Sidekiq Options Reference

| Option | Description | Default |
|--------|-------------|---------|
| `retry` | Max retry count | 25 |
| `queue` | Queue name | "default" |
| `backtrace` | Lines of backtrace to save | false |
| `dead` | Send to dead queue when exhausted | true |

**Sidekiq retry timing:** Exponential backoff formula: `(retry_count ** 4) + 15 + (rand(10) * (retry_count + 1))`
- First retry: ~15-30 seconds
- Fifth retry: ~10 minutes
- Tenth retry: ~3 hours

### When to Re-enqueue vs Rely on Retry

| Scenario | Strategy |
|----------|----------|
| External API "still processing" | Re-enqueue with `set(wait:)` |
| Network timeout | Let Sidekiq retry (default) |
| Rate limited | Re-enqueue with longer delay |
| Validation error | Don't retry - log and fail |
| Resource not found | Don't retry - log and fail |

## Queue Configuration

Queues are about keeping lanes open, not priority. Long-running jobs go in `:low` (even if important) to keep faster queues responsive:

| Queue | Use for |
|-------|---------|
| `:critical` | Must run immediately, very fast operations |
| `:high` | Fast operations that need quick turnaround |
| `:default` | Standard fast jobs |
| `:low` | Long-running jobs (even if important) |

```ruby
class QuickSyncJob < ApplicationJob
  queue_as :default  # Fast job - keeps express lanes clear
end

class TranslationGeneratorJob < ApplicationJob
  queue_as :low  # Long-running job goes here, even if important
end
```

**Rule of thumb:** If the job takes more than a few seconds, put it in `:low` to keep the other queues responsive.

## Checklist for New Jobs

- [ ] Inherit from `ApplicationJob`
- [ ] Set appropriate `queue_as` (:critical, :high, :default for fast jobs; :low for long-running)
- [ ] Configure `sidekiq_options retry:` based on job type
- [ ] Keep job logic thin - delegate to models/services
- [ ] Manage record state (processing!, success!, failure!) when applicable
- [ ] Log errors with context (IDs, state) before re-raising
- [ ] Consider: does this job trigger another job? Document the pipeline
- [ ] Add randomized delays for polling to prevent thundering herd