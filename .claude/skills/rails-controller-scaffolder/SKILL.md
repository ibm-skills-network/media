---
name: rails-controller-scaffolder
description: Scaffold Rails controllers following DHH's REST philosophy. Use when user needs to create new controllers, nested resources, or RESTful endpoints with proper authorization and patterns.
allowed-tools: Read, Grep, Glob, Edit, Write, Bash(bin/rails routes:*)
---

# Rails Controller Scaffolder

Expert Rails controller scaffolding following DHH's controller organization philosophy and established codebase patterns.

## Controller Organization Principles (DHH Style)

1. **Only the 7 CRUD Actions**: Controllers should ONLY contain `index`, `show`, `new`, `edit`, `create`, `update`, `destroy`. No custom actions ever.

2. **Split Controllers, Don't Add Actions**: If you need behavior outside CRUD, create a new namespaced controller:
   ```
   # BAD - custom action
   InboxesController#pendings

   # GOOD - new controller with index
   Inboxes::PendingsController#index
   ```

3. **Think Nouns, Not Verbs**: Model everything as a resource. You "create a payment" not "pay". You "create a cancellation" not "cancel".
   ```
   # BAD
   OrdersController#cancel

   # GOOD
   Orders::CancellationsController#create
   ```

4. **Single Purpose**: Each controller has one clear responsibility with its own filters and concerns. This prevents bloated controllers and keeps code predictable.

## Codebase Patterns

### Standard Controller Structure (HTML/Turbo)

```ruby
class ResourcesController < ApplicationController
  include SomeScoped  # Concern for parent resource context

  before_action :set_resource, only: %i[show edit update destroy]

  def index
    @search_resources = Resource.filter(
      params: params,
      items: Pundit.policy_scope(current_user, Resource),
      default_sort: ["created_at", :desc].freeze
    )
  end

  def show
    authorize @resource
  end

  def new
    @resource = Resource.new
    authorize @resource
  end

  def create
    @resource = Resource.new(resource_params)
    authorize @resource

    if @resource.save
      redirect_to @resource, success: "#{@resource.name} was successfully created."
    else
      flash[:alert] = @resource.errors.full_messages.join(", ")
      render :new, status: :unprocessable_content
    end
  end

  def update
    authorize @resource

    if @resource.update(resource_params)
      redirect_to @resource, success: "#{@resource.name} was successfully updated."
    else
      flash[:alert] = @resource.errors.full_messages.join(", ")
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    authorize @resource
    name = @resource.name
    @resource.destroy

    redirect_to resources_path, success: "#{name} has been deleted."
  end

  private

  def set_resource
    @resource = Resource.find(params[:id])
  end

  def resource_params
    params.require(:resource).permit(:name, :description)
  end
end
```

### API Controller Structure

```ruby
module Api
  module V1
    class ResourcesController < Api::V1::ApiController
      include Pundit::Authorization
      include ResourceScoped  # Concern for parent resource context if needed

      before_action :set_resource, only: %i[show update destroy]

      def index
        @resources = Pundit.policy_scope(current_user, Resource)
                          .includes(:association)
        render json: @resources
      end

      def show
        authorize @resource
        render json: @resource
      end

      def create
        @resource = Resource.new(resource_params)
        authorize @resource

        if @resource.save
          render json: @resource, status: :created, location: api_v1_resource_url(@resource)
        else
          render json: { errors: @resource.errors }, status: :unprocessable_content
        end
      end

      def update
        authorize @resource

        if @resource.update(resource_params)
          render json: @resource
        else
          render json: { errors: @resource.errors }, status: :unprocessable_content
        end
      end

      def destroy
        authorize @resource
        @resource.destroy!
        head :no_content
      end

      private

      def set_resource
        @resource = Resource.find(params[:id])
      end

      def resource_params
        params.require(:resource).permit(:name, :description)
      end
    end
  end
end
```

### Key Patterns to Follow

1. **Scoped concerns**: Use concerns like `PodcastHolderScoped`, `LabsApiScoped` when controller operates within a parent context
2. **Pundit authorization**: Use `authorize @resource` for single records, `Pundit.policy_scope(current_user, Resource)` for collections
3. **Filter pattern**: Use `Resource.filter(params:, items:, default_sort:)` for index actions with search/sort
4. **Strong parameters**: Use `params.require(:resource).permit(...)` for parameter filtering
5. **Flash messages**: Use `success:` key for redirects with success messages
6. **Error responses**: Render with `status: :unprocessable_content` for validation failures
7. **Includes**: Use `.includes()` to prevent N+1 queries in index actions
8. **Nested modules**: Use explicit module nesting (rubocop enforced)

### Route Organization

```ruby
# config/routes.rb
resources :resources do
  resources :nested_resources, only: [:index, :show, :create], module: :resources
end

# API routes
namespace :api do
  namespace :v1 do
    resources :resources, only: [:index, :show, :create, :update, :destroy]
  end
end
```

## Scoped Concern Pattern

```ruby
module ResourceScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_parent_resource
  end

  private

  def set_parent_resource
    @parent = ParentResource.find(params[:parent_resource_id])
  end
end
```

## Scaffolding Process

When asked to scaffold controllers:

1. **Analyze the request** to determine if it's:
   - Standard resource controller (HTML responses with Turbo)
   - API controller (JSON responses)
   - Nested controller (belongs to a parent resource)

2. **Generate the controller** following established patterns:
   - Proper module namespacing (nested modules for API)
   - Correct inheritance (`ApplicationController` or `Api::V1::ApiController`)
   - Include appropriate concerns if scoped to parent
   - Standard CRUD actions only
   - Proper authorization with Pundit
   - Strong parameters
   - Appropriate response format (HTML/JSON)
   - Use `.includes()` for index actions

3. **Generate corresponding routes** in `config/routes.rb`

4. **Identify any required models/policies** that might need to be created

## Response Format

When scaffolding controllers, provide:

1. **Controller file** with full path and complete implementation
2. **Route definition** for `config/routes.rb`
3. **Any required policy** if authorization is needed
4. **Any additional concerns** needed

## Quality Standards

- Follow "skinny controller, fat model" pattern
- Optimize for clarity over performance
- Keep it simple - only make changes that are directly requested
- Use semantic naming conventions
- Ensure proper error handling with appropriate HTTP status codes
- Follow Rails security best practices

**Note**: Testing is handled separately by the rspec-test-writer skill after scaffolding is complete.