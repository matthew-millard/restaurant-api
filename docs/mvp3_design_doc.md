# Restaurant Ordering Platform — MVP 3 Design Document

Version 3.0 • April 2026 • Pre-implementation

---

## 1. Overview

MVP 2 proved the end-to-end flow with a single restaurant: Claude chat → MCP server → Rails API → Square POS → email confirmation. Menu sync and order push work against the Square sandbox. The POS adapter pattern is established.

MVP 3 is a **complete rewrite in a fresh repo**. It introduces multi-restaurant support from day one, replaces raw Faraday HTTP calls with the official `square.rb` SDK, adds comprehensive test coverage (RSpec + Factory Bot), adopts Standard Ruby linting (matching hw-admin patterns), and sets up CI/CD with GitHub Actions deploying to Render.

## 2. Goals

- Multi-restaurant support: any number of restaurants, each with their own Square credentials and menu catalog
- Official Square SDK (`square.rb` v45+) replacing raw Faraday calls
- Sorbet with RBS inline annotations (no `T.*` DSL)
- Full test coverage: RSpec unit, integration, and request specs with Factory Bot and WebMock
- Standard Ruby linting with split config files (matching hw-admin patterns)
- CI/CD pipeline: GitHub Actions running specs, linting, type checking, and security scanning
- Production deployment on Render
- Well-scoped PRs — each PR is independently reviewable and CI-green

**Out of scope (deferred to MVP 4+):**

- Payment processing (Square Payments API)
- Authentication / API keys (acceptable risk since no payments flow through the system)
- Additional POS adapters (Toast, Maitre'd)
- Square webhooks (real-time catalog/order status updates)
- Admin dashboard
- WhatsApp/SMS channels
- Customer accounts
- Cart / draft orders
- Order modifications mapped to Square modifier catalog objects

---

## 3. System Architecture

### 3.1 High-Level Flow

```
Customer (Claude.ai chat)
    "I want to order from Joe's Burgers"
        |
MCP Server (Node.js, stdio transport)
    Passes restaurant_slug with every tool call
        |
Rails API (business logic, POS adapter layer)
    Resolves restaurant by slug, scopes all queries
        |
   +---------+---------+
   |                   |
PostgreSQL         Square REST API
(shared DB,        (per-restaurant credentials,
 all restaurants)   catalog sync, order push)
```

### 3.2 Components

| Component | Technology | Responsibility |
|-----------|-----------|----------------|
| LLM + Chat UI | Claude (claude.ai) | Natural language understanding, tool orchestration |
| MCP Server | Node.js + TypeScript (@modelcontextprotocol/sdk) | Exposes tools to Claude with `restaurant_slug`, translates to HTTP |
| Rails API | Ruby on Rails 8 (API mode) + Sorbet | Business logic, multi-restaurant scoping, POS adapter orchestration |
| POS Adapter | Ruby service classes (app/services/pos/) | Per-restaurant adapter instantiation, Square SDK integration |
| Database | PostgreSQL (single shared) | Restaurants, menu items, orders, order items |
| Email | Action Mailer + letter_opener (dev) | Order confirmation emails |
| Square SDK | `square.rb` gem (v45+) | Official client for Catalog API, Orders API |

### 3.3 Directory Structure

```
restaurant-api/
├── app/
│   ├── controllers/
│   │   ├── application_controller.rb
│   │   └── api/v1/
│   │       ├── base_controller.rb          (resolves restaurant by slug)
│   │       ├── menu_controller.rb
│   │       └── orders_controller.rb
│   ├── models/
│   │   ├── application_record.rb
│   │   ├── restaurant.rb                   (encrypted Square credentials)
│   │   ├── menu_item.rb                    (belongs_to :restaurant)
│   │   ├── order.rb                        (belongs_to :restaurant)
│   │   └── order_item.rb
│   ├── services/
│   │   └── pos/
│   │       ├── base_adapter.rb             (accepts restaurant arg)
│   │       └── square_adapter.rb           (square.rb SDK)
│   ├── mailers/
│   │   ├── application_mailer.rb
│   │   └── order_mailer.rb
│   └── views/
│       └── order_mailer/
│           ├── confirmation.html.erb
│           └── confirmation.text.erb
├── mcp-server/
│   ├── package.json
│   ├── tsconfig.json
│   └── src/
│       └── index.ts                        (4 tools, all with restaurant_slug)
├── config/
│   └── credentials.yml.enc                 (Active Record Encryption keys)
├── db/
│   └── migrate/
├── lib/
│   └── tasks/
│       └── square.rake
├── spec/
│   ├── models/
│   ├── services/
│   ├── requests/
│   ├── factories/
│   ├── support/
│   └── spec_helper.rb / rails_helper.rb
├── .rubocop.yml
├── .rubocop_rails.yml
├── .rubocop_rspec.yml
├── .rubocop_sorbet.yml
├── .rubocop_factory_bot.yml
├── .github/
│   └── workflows/
│       └── ci.yml
└── docs/
    └── mvp3_design_doc.md
```

---

## 4. Data Model

Four tables. All resource tables (except `restaurants`) have a `restaurant_id` foreign key for multi-tenant scoping. Single shared database — no per-restaurant database separation.

### 4.1 restaurants

| Column | Type | Notes |
|--------|------|-------|
| id | bigint PK | |
| name | string | NOT NULL |
| slug | string | NOT NULL, UNIQUE INDEX, used in URLs |
| pos_type | string | NOT NULL, e.g. `"square"` |
| square_access_token | string | Encrypted (Active Record Encryption) |
| square_location_id | string | Encrypted |
| square_environment | string | `"sandbox"` or `"production"`, default `"sandbox"` |
| created_at | datetime | |
| updated_at | datetime | |

### 4.2 menu_items

| Column | Type | Notes |
|--------|------|-------|
| id | bigint PK | |
| restaurant_id | bigint FK | NOT NULL, indexed |
| name | string | NOT NULL |
| description | string | |
| price_cents | integer | NOT NULL, >= 0 |
| category | string | NOT NULL |
| available | boolean | DEFAULT true |
| square_catalog_id | string | UNIQUE INDEX |
| square_variation_id | string | UNIQUE INDEX |
| last_synced_at | datetime | |
| created_at | datetime | |
| updated_at | datetime | |

**Change from MVP 2:** `price_cents` (integer) replaces `price` (decimal). Matches Square's native format (`price_money.amount` is already in cents), eliminates floating-point arithmetic entirely.

### 4.3 orders

| Column | Type | Notes |
|--------|------|-------|
| id | uuid PK | `gen_random_uuid()` |
| restaurant_id | bigint FK | NOT NULL, indexed |
| customer_name | string | NOT NULL |
| customer_email | string | NOT NULL, email format validation |
| status | string | DEFAULT `"pending"`, enum: pending/preparing/ready/completed/cancelled |
| pickup_time | string | Free-text from customer |
| total_cents | integer | NOT NULL, >= 0 |
| square_order_id | string | UNIQUE INDEX, nullable |
| created_at | datetime | |
| updated_at | datetime | |

### 4.4 order_items

| Column | Type | Notes |
|--------|------|-------|
| id | bigint PK | |
| order_id | uuid FK | NOT NULL |
| menu_item_id | bigint FK | NOT NULL |
| quantity | integer | NOT NULL, > 0 |
| modifications | string | Free-text special requests |
| unit_price_cents | integer | NOT NULL, >= 0 |
| created_at | datetime | |
| updated_at | datetime | |

### 4.5 Entity Relationships

```
Restaurant 1──* MenuItem
Restaurant 1──* Order
Order      1──* OrderItem
OrderItem  *──1 MenuItem
```

---

## 5. API Design

### 5.1 Routes

All routes are nested under the restaurant slug:

```ruby
# config/routes.rb
namespace :api do
  namespace :v1 do
    scope ":restaurant_slug" do
      get  "menu",                to: "menu#index"
      post "orders",              to: "orders#create"
      get  "orders/:id",         to: "orders#show"
      patch "orders/:id/cancel", to: "orders#cancel"
    end
  end
end

get "up" => "rails/health#show"
```

**Resulting endpoints:**

| Method | Path | Controller#Action |
|--------|------|-------------------|
| GET | `/api/v1/:restaurant_slug/menu` | `menu#index` |
| POST | `/api/v1/:restaurant_slug/orders` | `orders#create` |
| GET | `/api/v1/:restaurant_slug/orders/:id` | `orders#show` |
| PATCH | `/api/v1/:restaurant_slug/orders/:id/cancel` | `orders#cancel` |
| GET | `/up` | Health check |

### 5.2 Base Controller

```ruby
# app/controllers/api/v1/base_controller.rb
module Api
  module V1
    class BaseController < ApplicationController
      before_action :set_restaurant

      private

      def set_restaurant
        @restaurant = Restaurant.find_by!(slug: params[:restaurant_slug])
      end
    end
  end
end
```

All `Api::V1` controllers inherit from `BaseController`. The restaurant is resolved once and available as `@restaurant` for scoping queries and instantiating adapters.

### 5.3 Response Formats

**Order response:**

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "pending",
  "customer_name": "John Doe",
  "customer_email": "john@example.com",
  "pickup_time": "7:00 PM",
  "total": "$25.99",
  "items": [
    {
      "name": "Burger",
      "quantity": 2,
      "modifications": "No onions",
      "price": "$12.99"
    }
  ]
}
```

**Menu response:** Array of menu item objects with `price` formatted as dollars (e.g. `"$12.99"` — converted from `price_cents`).

### 5.4 Error Handling

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound do |e|
    render json: { error: e.message }, status: :not_found
  end
end
```

- 404 for unknown restaurant slug or order ID
- 422 for validation failures (invalid order params, non-pending cancel)
- 201 for successful order creation

---

## 6. POS Adapter Pattern

### 6.1 Base Interface

All POS adapters accept a `Restaurant` in the constructor. The Rails API never calls a POS API directly — it always goes through the adapter.

```ruby
# app/services/pos/base_adapter.rb
# typed: true
# frozen_string_literal: true

module Pos
  class BaseAdapter
    #: (Restaurant restaurant) -> void
    def initialize(restaurant)
      @restaurant = restaurant
    end

    #: -> void
    def sync_menu
      raise NotImplementedError, "#{self.class}#sync_menu is not implemented"
    end

    #: (Order order) -> void
    def push_order(order)
      raise NotImplementedError, "#{self.class}#push_order is not implemented"
    end

    #: (String external_order_id) -> String
    def get_order_status(external_order_id)
      raise NotImplementedError, "#{self.class}#get_order_status is not implemented"
    end
  end
end
```

**Change from MVP 2:** The constructor now takes a `restaurant` argument. Credentials are read from the restaurant's encrypted attributes instead of shared Rails credentials.

### 6.2 Square Adapter

```ruby
# app/services/pos/square_adapter.rb
# typed: true
# frozen_string_literal: true

module Pos
  class SquareAdapter < BaseAdapter
    #: (Restaurant restaurant) -> void
    def initialize(restaurant)
      super
      @client = Square::Client.new(
        token: restaurant.square_access_token,
        base_url: square_environment,
      )
    end

    def sync_menu
      # 1. Fetch categories via @client.catalog.list_catalog(types: "CATEGORY")
      # 2. Fetch items via @client.catalog.list_catalog(types: "ITEM")
      # 3. Handle pagination via cursor
      # 4. For each item/variation: find_or_initialize_by square_catalog_id, upsert
      # 5. Mark items not seen in sync as available: false
    end

    def push_order(order)
      # 1. Build order body with line_items mapped via square_variation_id
      # 2. Include PICKUP fulfillment with parsed pickup_at time (RFC 3339)
      # 3. Call @client.orders.create_order(body: ...)
      # 4. Store response.data.order.id as order.square_order_id
      # 5. Failures logged but don't block local order
    end

    def get_order_status(external_order_id)
      raise NotImplementedError # Future
    end

    private

    def square_environment
      case @restaurant.square_environment
      when "production" then "production"
      else "sandbox"
      end
    end
  end
end
```

### 6.3 Adapter Resolution

```ruby
# In controllers / services:
adapter = ::Pos::SquareAdapter.new(@restaurant)
adapter.push_order(order)
```

The `::Pos` prefix is required when calling from inside the `Api::V1` namespace to avoid Zeitwerk constant resolution issues. Future POS adapters (Toast, etc.) would be resolved by `restaurant.pos_type`.

---

## 7. Square SDK Usage

### 7.1 Gem

```ruby
# Gemfile
gem "square.rb", "~> 45.0"
```

This is the **official Square SDK** (not the old community `square` gem v0.0.4 that was in MVP 2). It provides typed client methods, automatic API versioning, and structured error objects.

### 7.2 Client Instantiation

Per-restaurant. Each restaurant has its own Square credentials stored as encrypted columns.

```ruby
@client = Square::Client.new(
  token: restaurant.square_access_token,
  base_url: square_environment,
)
```

### 7.3 Catalog API

```ruby
# Fetch categories
result = @client.catalog.list_catalog(types: "CATEGORY")
categories = result.data.objects # Array of CatalogObject

# Fetch items (with pagination)
cursor = nil
loop do
  result = @client.catalog.list_catalog(types: "ITEM", cursor: cursor)
  items = result.data.objects
  # Process items...
  cursor = result.data.cursor
  break if cursor.nil?
end
```

### 7.4 Orders API

```ruby
result = @client.orders.create_order(body: {
  idempotency_key: order.id,
  order: {
    location_id: @restaurant.square_location_id,
    line_items: order.order_items.map { |oi|
      {
        catalog_object_id: oi.menu_item.square_variation_id,
        quantity: oi.quantity.to_s,
        note: oi.modifications,
      }.compact
    },
    fulfillments: [{
      type: "PICKUP",
      state: "PROPOSED",
      pickup_details: {
        recipient: {
          display_name: order.customer_name,
          email_address: order.customer_email,
        },
        pickup_at: parse_pickup_time(order.pickup_time),
        note: "Ordered via AI assistant",
      },
    }],
  },
})

order.update!(square_order_id: result.data.order.id)
```

### 7.5 Error Handling

```ruby
rescue Square::ApiError => e
  error_details = e.errors.map(&:detail).join(", ")
  Rails.logger.error("Square push failed for order #{order.id}: #{error_details}")
  # Local order still saved — square_order_id remains nil
end
```

Square push failures do not block local order creation. The customer still gets their confirmation email.

### 7.6 Pickup Time Parsing

Square requires `pickup_at` in RFC 3339 format. The customer provides free-text like "7:00 PM". The adapter parses this:

1. `Time.zone.parse(pickup_time_string)` anchored to today
2. If the parsed time is in the past, roll to tomorrow
3. Fallback: 1 hour from now if parsing fails
4. Return `.iso8601` (RFC 3339)

---

## 8. MCP Server

### 8.1 Architecture

One MCP server instance serves all restaurants. The customer tells Claude which restaurant they want (e.g. "I want to order from Joe's Burgers"), and Claude passes `restaurant_slug` with every tool call. This avoids needing separate MCP server instances per restaurant.

### 8.2 Tools

| Tool | Method | Endpoint | Description |
|------|--------|----------|-------------|
| `get_menu` | GET | `/api/v1/:slug/menu` | Returns available menu items with prices |
| `place_order` | POST | `/api/v1/:slug/orders` | Places an order with items, customer info, pickup time |
| `track_order` | GET | `/api/v1/:slug/orders/:id` | Returns order status and details |
| `cancel_order` | PATCH | `/api/v1/:slug/orders/:id/cancel` | Cancels a pending order |

### 8.3 Zod Schemas

```typescript
// get_menu
{
  restaurant_slug: z.string().describe("Restaurant identifier (URL slug)")
}

// place_order
{
  restaurant_slug: z.string().describe("Restaurant identifier (URL slug)"),
  customer_name: z.string(),
  customer_email: z.string().email(),
  pickup_time: z.string().describe("e.g. '7:00 PM'"),
  items: z.array(z.object({
    menu_item_id: z.number(),
    quantity: z.number().min(1),
    modifications: z.string().optional().describe("e.g. 'No pickles'"),
  })),
}

// track_order
{
  restaurant_slug: z.string().describe("Restaurant identifier (URL slug)"),
  order_id: z.string().uuid(),
}

// cancel_order
{
  restaurant_slug: z.string().describe("Restaurant identifier (URL slug)"),
  order_id: z.string().uuid(),
}
```

### 8.4 Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `MCP_API_BASE_URL` | Rails API URL | `http://localhost:3000` |

**Claude Desktop config:**

```json
{
  "mcpServers": {
    "restaurant": {
      "command": "node",
      "args": ["/path/to/mcp-server/dist/index.js"]
    }
  }
}
```

### 8.5 Response Format

All tool responses wrapped as MCP text content:

```typescript
return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
```

---

## 9. Testing Strategy

### 9.1 Stack

| Tool | Purpose |
|------|---------|
| RSpec | Test framework |
| Factory Bot | Test data factories |
| Shoulda Matchers | One-liner model validation/association tests |
| WebMock | Stub Square HTTP requests (no real API calls in tests) |

**Why WebMock over VCR:** Explicit stubs are less brittle when the SDK version changes. VCR cassettes become stale when API response shapes evolve. WebMock stubs document exactly what the test expects.

### 9.2 Spec Organization

```
spec/
├── models/
│   ├── restaurant_spec.rb
│   ├── menu_item_spec.rb
│   ├── order_spec.rb
│   └── order_item_spec.rb
├── services/
│   └── pos/
│       └── square_adapter_spec.rb     (WebMock stubs for Square API)
├── requests/
│   ├── menu_spec.rb                   (GET /api/v1/:slug/menu)
│   └── orders_spec.rb                 (POST, GET, PATCH)
├── factories/
│   ├── restaurants.rb
│   ├── menu_items.rb
│   ├── orders.rb
│   └── order_items.rb
├── support/
│   ├── factory_bot.rb
│   └── webmock.rb
├── spec_helper.rb
└── rails_helper.rb
```

### 9.3 Coverage Targets

- **Model specs:** Validations, associations, scopes, encrypted attribute access
- **Adapter specs:** `sync_menu` and `push_order` with WebMock stubs simulating Square API responses (success and error paths)
- **Request specs:** Full endpoint tests — happy path, validation errors, not-found, cancel constraints

### 9.4 Factory Examples

```ruby
# spec/factories/restaurants.rb
FactoryBot.define do
  factory :restaurant do
    name { "Joe's Burgers" }
    sequence(:slug) { |n| "joes-burgers-#{n}" }
    pos_type { "square" }
    square_access_token { "test-token-#{SecureRandom.hex(8)}" }
    square_location_id { "L#{SecureRandom.hex(8).upcase}" }
    square_environment { "sandbox" }
  end
end
```

---

## 10. Linting & Style

### 10.1 Approach

Adopt **Standard Ruby** as the base (replacing `rubocop-rails-omakase` from MVP 2). Use `DisabledByDefault: true` with split config files — only explicitly enabled cops are active. This matches the patterns from hw-admin (minus company-specific custom cops).

### 10.2 Config Files

**`.rubocop.yml`** — Main config:

```yaml
inherit_from:
  - .rubocop_rails.yml
  - .rubocop_rspec.yml
  - .rubocop_sorbet.yml
  - .rubocop_factory_bot.yml

require:
  - standard
  - rubocop-rails
  - rubocop-rspec
  - rubocop-sorbet
  - rubocop-factory_bot

AllCops:
  DisabledByDefault: true
  NewCops: enable
  ParserEngine: parser_prism
  TargetRubyVersion: 3.4

Style/FrozenStringLiteralComment:
  Enabled: true
  EnforcedStyle: always

Style/TrailingCommaInArrayLiteral:
  Enabled: true
  EnforcedStyleForMultiline: comma

Style/TrailingCommaInHashLiteral:
  Enabled: true
  EnforcedStyleForMultiline: comma

Style/EndlessMethod:
  Enabled: true
  EnforcedStyle: disallow

Style/Lambda:
  Enabled: true
  EnforcedStyle: literal

Layout/IndentationConsistency:
  Enabled: true
  EnforcedStyle: indented_internal_methods

Layout/LeadingCommentSpace:
  Enabled: true
  AllowRBSInlineAnnotation: true
```

**`.rubocop_rails.yml`** — Rails cops (enabled selectively).

**`.rubocop_rspec.yml`** — RSpec cops:

```yaml
RSpec/ExplicitPredicateMatcher:
  Enabled: true

RSpec/MessageSpies:
  Enabled: true
  EnforcedStyle: have_received
```

**`.rubocop_sorbet.yml`** — Sorbet RBS-only rules:

```yaml
Sorbet/ValidSigil:
  Enabled: true
  MinimumStrictness: "true"
  Include:
    - "app/**/*.rb"

Sorbet/FalseSigil:
  Enabled: true
  Exclude:
    - "app/**/*.rb"

# Forbid all T.* DSL — RBS inline annotations only
Sorbet/ForbidTStruct:
  Enabled: true

Sorbet/ForbidTUnsafe:
  Enabled: true

Sorbet/ForbidSuperclassConstLiteral:
  Enabled: false
```

**`.rubocop_factory_bot.yml`** — Factory Bot cops (most rules enabled).

### 10.3 Gems

```ruby
# Gemfile (development/test group)
gem "standard"
gem "rubocop-rails"
gem "rubocop-rspec"
gem "rubocop-sorbet"
gem "rubocop-factory_bot"
```

### 10.4 Sorbet Conventions

- `# typed: true` sigil on all `app/**/*.rb` files
- `# frozen_string_literal: true` on all Ruby files
- RBS inline `#:` annotations only — no `T.let`, `T.cast`, `T.sig`, `T.must`, `T::Struct`
- `AllowRBSInlineAnnotation: true` to permit `#:` comment syntax without lint warnings

---

## 11. CI/CD

### 11.1 GitHub Actions Workflow

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: postgres
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    env:
      RAILS_ENV: test
      DATABASE_URL: postgres://postgres:postgres@localhost:5432/restaurant_api_test

    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - run: bin/rails db:setup
      - run: bundle exec rspec
      - run: bundle exec rubocop
      - run: bundle exec srb tc
      - run: bundle exec brakeman --no-pager
```

### 11.2 Checks

| Check | Command | Purpose |
|-------|---------|---------|
| Tests | `bundle exec rspec` | Unit, integration, request specs |
| Lint | `bundle exec rubocop` | Style enforcement |
| Types | `bundle exec srb tc` | Sorbet static type checking |
| Security | `bundle exec brakeman --no-pager` | Vulnerability scanning |

All four checks must pass before a PR can merge.

---

## 12. Deployment

### 12.1 Platform: Render

| Service | Type | Notes |
|---------|------|-------|
| Web service | Ruby (Docker) | Rails 8 API, auto-deploy from `main` |
| Database | PostgreSQL | Render managed, free tier available |

### 12.2 Render Configuration

- **Build command:** `bundle install && bin/rails db:migrate`
- **Start command:** `bin/rails server`
- **Auto-deploy:** On push to `main` branch
- **Health check:** `GET /up`

### 12.3 Trade-offs

- **Pros:** Simple setup, free tier for PostgreSQL, native Docker support, auto-deploy from GitHub
- **Cons:** Cold starts on free tier, limited regions

---

## 13. Configuration

### 13.1 Per-Restaurant Square Credentials

Stored as **encrypted columns on the Restaurant model** using Rails Active Record Encryption. This means:

- Zero extra infrastructure (no Vault, no external secrets manager)
- Encryption keys live in Rails credentials (`config/credentials.yml.enc`), protected by `RAILS_MASTER_KEY`
- Encrypted at rest in PostgreSQL, decrypted transparently by ActiveRecord

```ruby
# app/models/restaurant.rb
class Restaurant < ApplicationRecord
  encrypts :square_access_token, deterministic: false
  encrypts :square_location_id, deterministic: false
end
```

### 13.2 Rails Credentials

```yaml
# config/credentials.yml.enc (decrypted view)
active_record_encryption:
  primary_key: <generated>
  deterministic_key: <generated>
  key_derivation_salt: <generated>
```

Generate encryption keys:

```bash
bin/rails db:encryption:init
```

### 13.3 Environment Variables

| Variable | Purpose | Required |
|----------|---------|----------|
| `RAILS_MASTER_KEY` | Decrypts Rails credentials (Active Record Encryption keys) | Production |
| `DATABASE_URL` | PostgreSQL connection string | Production |
| `MCP_API_BASE_URL` | Rails API URL for MCP server | MCP server (default: `http://localhost:3000`) |

---

## 14. Email

Same approach as MVP 2. Order confirmation via Action Mailer, triggered after successful order creation.

### 14.1 Trigger

```ruby
OrderMailer.confirmation(order).deliver_later
```

Uses ActiveJob queue (Solid Queue in production, inline in development).

### 14.2 Contents

- Order ID (truncated UUID for readability)
- Customer name
- Restaurant name
- Itemized order summary with quantities, modifications, and prices
- Order total
- Pickup time
- Cancellation instructions

### 14.3 Templates

- `confirmation.html.erb` — styled HTML table layout with inline CSS
- `confirmation.text.erb` — plain text fallback

### 14.4 Development

Uses `letter_opener` gem — emails open in the browser automatically. No SMTP configuration needed locally.

---

## 15. Build Order

10 well-scoped PRs. Each PR is independently reviewable and CI-green. No circular dependencies — each PR builds on the ones before it.

| PR | Scope | Details |
|----|-------|---------|
| 1 | **Rails skeleton** | New repo, Gemfile, RuboCop (all split configs), Sorbet setup, RSpec + Factory Bot, GitHub Actions CI workflow, health check endpoint (`GET /up`) |
| 2 | **Restaurant model** | Migration with encrypted attributes, model validations, factory, model specs |
| 3 | **MenuItem model** | Migration with `restaurant_id` FK, `price_cents` (integer), factory, model specs |
| 4 | **Order + OrderItem models** | Migrations (UUID PK for orders), associations, factories, model specs |
| 5 | **POS adapters** | `BaseAdapter` (with restaurant arg), `SquareAdapter` using `square.rb` (`sync_menu`, `push_order`), adapter specs with WebMock stubs |
| 6 | **Menu controller** | `BaseController` with restaurant slug resolution, `GET /api/v1/:slug/menu`, request specs |
| 7 | **Orders controller** | `POST`, `GET`, `PATCH cancel` endpoints, wire `push_order` + mailer, request specs |
| 8 | **Rake task + seed data** | `square:sync_menu` rake task (accepts slug), seed data for development |
| 9 | **MCP server** | Rewrite with `restaurant_slug` parameter on all 4 tools, updated Zod schemas |
| 10 | **Email + deploy prep** | Email templates, Render config, end-to-end verification |

---

## 16. Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Fresh repo | Over incremental rewrite | Clean foundation without MVP 2 baggage (wrong Square gem, no tests, single-restaurant assumptions baked in) |
| `price_cents` (integer) | Over `price` (decimal) | Matches Square's native format (`price_money.amount`), eliminates floating-point arithmetic |
| Single shared database | Over per-restaurant databases | Simplest for MVP scale (handful of restaurants), one schema/migration path, easy to query across restaurants |
| Encrypted columns | Over Rails credentials for POS creds | Per-restaurant credentials don't belong in a single credentials file; Active Record Encryption requires zero extra infrastructure |
| No auth | Deferred to MVP 4 | Acceptable risk since no payments flow through the system; keeps MVP 3 focused on multi-restaurant + Square.rb + test coverage |
| `square.rb` (official SDK) | Over raw Faraday | Proper client methods, structured error objects (`Square::ApiError`), automatic API versioning, no manual URL construction |
| WebMock | Over VCR | Explicit stubs are less brittle with SDK version changes; VCR cassettes become stale when API response shapes evolve |
| Standard Ruby | Over rubocop-rails-omakase | `DisabledByDefault` approach gives explicit control; matches hw-admin patterns |
| RBS inline annotations | Over `T.*` DSL | Cleaner syntax, works with standard Ruby parser, enforced by `rubocop-sorbet` forbid rules |
| One MCP server with `restaurant_slug` | Over one server per restaurant | Scalable, single deployment, Claude passes context per tool call |
| Render | Over Fly.io / Railway / Kamal | Simple, free PostgreSQL tier, auto-deploy from GitHub |
| Well-scoped PRs | Over monolithic implementation | Each PR is reviewable, CI-green, and builds incrementally |

---

## 17. Lessons Carried Forward from MVP 2

These lessons from MVP 2 inform MVP 3 design decisions:

1. **`square` gem != `square.rb`** — The `square` gem (v0.0.4) is an old community gem wrapping Square's deprecated Connect V1 API. MVP 3 uses `square.rb` (v45+), the official SDK.
2. **`::Pos` namespace prefix** — Required when referencing from inside `Api::V1` controllers due to Zeitwerk autoloading.
3. **RFC 3339 timestamps** — Square requires `pickup_at` in RFC 3339 format, not free-text. The adapter must parse "7:00 PM" into proper ISO 8601.
4. **Sorbet RBS + blocks** — RBS annotations on instance variable assignments with blocks need a local variable workaround (assign to local first, then to ivar).
5. **Square sandbox limitations** — Sandbox orders don't appear in the Square Dashboard. Verify via the Orders API only.
6. **Square catalog seeding** — Use `description_html` (not `description_plaintext` which is read-only). Include `item_id` in variation data. Currency must match account country.
7. **Fire-and-forget POS push** — Square push failures should not block local order creation. Log the error, keep `square_order_id` as nil, and send the confirmation email regardless.

---

End of Document
