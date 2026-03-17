---
name: rspec-test-writer
description: Create RSpec tests for Rails backend. Use when user needs tests for models, services, actors, or controllers. Analyzes code, identifies test scenarios, writes comprehensive specs with proper stubs.
allowed-tools: Read, Grep, Glob, Edit, Write, Bash(bundle exec rspec:*)
---

# RSpec Test Writer

Expert Rails testing specialist for creating well-structured RSpec tests following established conventions.

## Core Testing Principles

1. **No External API Calls**: Never make actual external API calls in tests. Always create stubs for API clients that return happy path expected responses using RSpec's stubbing mechanisms.

2. **Test Classification**:
   - **Unit Tests**: Models, Services, Actors in isolation (spec/models/, spec/services/, spec/actors/)
   - **Integration Tests**: Controllers through request specs (spec/requests/)
   - **System Tests**: Full-stack with Capybara (spec/system/) - rarely needed, see note below
   - **Policy Tests**: Pundit authorization (spec/policies/)

3. **System Tests are Expensive**: System tests with Capybara are slow and rarely needed. Prefer request specs for controller testing. Only consider system tests for critical multi-step user flows (e.g., onboarding, checkout). If you think system tests might be beneficial, ask the user first.

4. **Factory Usage**: Use FactoryBot factories efficiently - prefer `build` for unit tests and `create` for integration tests when database persistence is needed.

5. **Keep it Simple (Stupid)**: Keep testing minimal and easy to maintain. Avoid over-engineering.

## Required Test Structure

### Unit Tests (Models/Services/Actors)
```ruby
RSpec.describe ModelName, type: :model do
  let(:model_instance) { build(:model_name) }

  describe "#method_name" do
    it "descriptive test case" do
      # test implementation
    end
  end
end
```

### Actor Tests
```ruby
RSpec.describe Actors::SomeActor do
  let(:user) { create(:user) }

  describe ".call" do
    it "performs the expected action" do
      result = described_class.call(user: user)
      expect(result).to be_success
    end
  end
end
```

### Integration Tests (Controllers)
```ruby
RSpec.describe SomeController, type: :request do
  include_context "with some client"  # Use shared contexts for API stubs

  let(:user) { create(:user) }
  let(:resource) { create(:resource) }

  before { sign_in user }

  describe "#index" do
    it "loads the page successfully" do
      get resources_path
      expect(response).to be_successful
    end
  end
end
```

### Policy Tests
```ruby
RSpec.describe ResourcePolicy, type: :policy do
  let(:user) { create(:user) }
  let(:resource) { create(:resource) }

  subject { described_class.new(user, resource) }

  describe "#show?" do
    context "when user owns resource" do
      it { is_expected.to permit_action(:show) }
    end
  end
end
```

### System Tests (Capybara) - Rarely Needed
```ruby
RSpec.describe "Feature name", type: :system do
  let(:user) { create(:user) }

  before do
    driven_by(:rack_test)
    sign_in user
  end

  it "completes the user flow" do
    visit some_path
    click_on "Button"
    expect(page).to have_content("Expected text")
  end
end
```

## Shared Contexts

Use `include_context` for common setup patterns, especially API client stubs:

```ruby
# In spec file
include_context "with rug client"
include_context "with podcasts client"
```

Check `spec/support/` for available shared contexts before creating new stubs.

## Testing Approach

1. **Analyze the Code**: Examine the provided code to understand its functionality, dependencies, and edge cases.

2. **Identify Test Scenarios**: Determine what needs testing:
   - Happy path scenarios
   - Edge cases and error conditions
   - Validation logic
   - Business logic methods
   - Controller actions and responses
   - Authorization rules

3. **Create Comprehensive Coverage**: Write tests that cover:
   - All public methods
   - Validation rules
   - Associations and callbacks
   - Error handling
   - Different response formats (JSON, HTML)
   - Authentication/authorization

4. **Stub External Dependencies**: Use `instance_double`, `allow`, and `expect` to stub:
   - API clients (use shared contexts when available)
   - External services
   - Third-party integrations
   - File system operations

5. **Follow Rails Conventions**: Ensure tests align with Rails testing patterns and the project's established practices from AGENTS.md.

## Quality Standards

- Write descriptive test names that clearly explain what is being tested
- Use appropriate RSpec matchers and be specific in assertions
- Keep tests focused and atomic - one concept per test
- Use proper setup with `let` statements for test data
- Include both positive and negative test cases
- Ensure tests are deterministic and don't depend on external state

## Workflow

When asked to write tests:

1. Check `git diff master..HEAD` to see what code changed (if testing branch changes)
2. Read the files that need testing
3. Check `spec/support/` for existing shared contexts
4. Identify existing test patterns in similar spec files
5. Write tests following the patterns above
6. Run tests with `bundle exec rspec path/to/spec.rb` to verify they pass