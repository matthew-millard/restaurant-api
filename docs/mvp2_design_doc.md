# Restaurant Ordering Platform — MVP 2 Design Document

Version 2.0 • April 2026 • Updated post-implementation

---

## 1. Overview

MVP 1 proved the end-to-end flow: customer chats with Claude, MCP server translates to API calls, Rails API manages orders, email confirmation goes out. Menu data was manually seeded.

MVP 2 introduces **Square as the first POS adapter**. The restaurant manages their menu in Square. Our platform syncs it, lets customers order through Claude, and fires completed orders back to Square. This establishes the POS adapter pattern that future integrations (Toast, Maitre'd, etc.) will follow.

## 2. MVP 2 Goals

**Delivered:**

- Sync menu catalog from Square sandbox into local database
- POS adapter interface pattern (`Pos::BaseAdapter` → `Pos::SquareAdapter`)
- Push placed orders to Square Orders API with pickup fulfillment
- MCP server in the same repo under `/mcp-server`
- Claude as the conversational interface (tested end-to-end)
- Email confirmation on order placement via Action Mailer

**Out of scope (future iterations):**

- Payment processing (Square Payments API)
- Multi-restaurant / tenant model
- Additional POS adapters (Toast, Maitre'd)
- Additional channels (WhatsApp, SMS, Alexa)
- Customer authentication / accounts
- Real-time order status updates from Square webhooks
- Admin dashboard

## 3. System Architecture

### 3.1 High-Level Flow

```
Customer (Claude.ai chat)
        |
MCP Server (Node.js, stdio transport)
        |
Rails API (business logic, POS adapter layer)
        |
   +---------+---------+
   |                   |
PostgreSQL         Square REST API
(local data)       (catalog sync, order push)
```

### 3.2 Components

| Component | Technology | Responsibility |
|-----------|-----------|----------------|
| LLM + Chat UI | Claude (claude.ai) | Natural language understanding, tool orchestration |
| MCP Server | Node.js + TypeScript (@modelcontextprotocol/sdk) | Exposes tools to Claude, translates to HTTP |
| Rails API | Ruby on Rails 8 (API mode) + Sorbet | Business logic, POS adapter orchestration |
| POS Adapter | Ruby service classes (app/services/pos/) | Abstracts POS-specific API calls behind a common interface |
| Database | PostgreSQL | Menu items, orders, order items, sync metadata |
| Email | Action Mailer + letter_opener (dev) | Order confirmation emails |
| Square HTTP | Faraday (direct REST calls) | HTTP client for Square API |

### 3.3 Directory Structure

```
restaurant-api/
├── app/
│   ├── controllers/
│   │   ├── application_controller.rb   (RecordNotFound handler)
│   │   └── api/v1/
│   │       ├── menu_controller.rb
│   │       └── orders_controller.rb    (calls push_order + mailer)
│   ├── models/
│   │   ├── menu_item.rb               (square_catalog_id, square_variation_id, last_synced_at)
│   │   ├── order.rb                   (square_order_id)
│   │   └── order_item.rb
│   ├── services/
│   │   └── pos/
│   │       ├── base_adapter.rb        (interface: sync_menu, push_order, get_order_status)
│   │       └── square_adapter.rb      (Faraday-based Square implementation)
│   ├── mailers/
│   │   ├── application_mailer.rb
│   │   └── order_mailer.rb            (confirmation email)
│   └── views/
│       └── order_mailer/
│           ├── confirmation.html.erb
│           └── confirmation.text.erb
├── mcp-server/
│   ├── package.json
│   ├── tsconfig.json
│   └── src/
│       └── index.ts                   (4 tools: get_menu, place_order, track_order, cancel_order)
├── config/
│   └── credentials.yml.enc            (Square credentials encrypted)
├── db/
│   └── migrate/
│       └── *_add_square_fields_to_menu_items_and_orders.rb
├── lib/
│   └── tasks/
│       └── square.rake                (square:sync_menu)
└── docs/
    └── mvp2_design_doc.md             (this file)
```

## 4. POS Adapter Pattern

### 4.1 Base Interface

All POS adapters implement a common interface. The Rails API calls this — it never touches a POS API directly.

```ruby
# app/services/pos/base_adapter.rb
module Pos
  class BaseAdapter
    def sync_menu       # Pull catalog from POS, upsert into local menu_items
    def push_order(order)  # Send a placed order to the POS system
    def get_order_status(external_order_id)  # Check order status on the POS side
  end
end
```

### 4.2 Square Adapter

**Implementation note:** The `square` gem (v0.0.4) is an old community gem without the modern Catalog/Orders API. The adapter uses **Faraday** directly against the Square REST API instead of a client SDK.

```ruby
# app/services/pos/square_adapter.rb
module Pos
  class SquareAdapter < BaseAdapter
    def initialize
      # Reads credentials from Rails.application.credentials.square
      # Sets up Faraday connection to sandbox or production URL
    end

    def sync_menu
      # 1. GET /v2/catalog/list?types=CATEGORY — build category name map
      # 2. GET /v2/catalog/list?types=ITEM — fetch all items with variations
      # 3. For each item/variation: find_or_initialize_by square_catalog_id, upsert
      # 4. Mark items not seen in sync as available: false
      # Handles pagination via cursor
    end

    def push_order(order)
      # 1. POST /v2/orders with line_items mapped via square_variation_id
      # 2. Includes PICKUP fulfillment with parsed pickup_at time (RFC 3339)
      # 3. Stores returned square_order_id on the local order
      # 4. Failures logged but don't block local order
    end

    def get_order_status(external_order_id)
      raise NotImplementedError  # Future: GET /v2/orders/:id
    end
  end
end
```

### 4.3 Adapter Resolution

For MVP 2 (single restaurant), adapter is instantiated directly:

```ruby
::Pos::SquareAdapter.new.push_order(order)
```

Note the `::` prefix — required when calling from inside the `Api::V1` namespace to avoid constant resolution issues.

## 5. Data Model Changes

### 5.1 menu_items — New Columns

| Column | Type | Notes |
|--------|------|-------|
| square_catalog_id | string (unique index) | Square catalog object ID |
| square_variation_id | string (unique index) | Square item variation ID (the purchasable unit) |
| last_synced_at | datetime | When this item was last synced from Square |

### 5.2 orders — New Columns

| Column | Type | Notes |
|--------|------|-------|
| square_order_id | string (unique index) | Square order ID after push, null if push fails |

All columns nullable — existing records predate Square integration.

## 6. Menu Sync

### 6.1 Flow

```
Square Catalog API
        |
  GET /v2/catalog/list?types=CATEGORY  →  category ID → name map
  GET /v2/catalog/list?types=ITEM      →  items with nested variations
        |
  SquareAdapter#sync_menu
        |
  For each item + variation:
    - find_or_initialize_by(square_catalog_id: item.id)
    - Update name, description (from description_plaintext), price, category
    - Set square_variation_id, last_synced_at, available: true
    - Save
        |
  Mark any menu_items with square_catalog_id not in sync as available: false
```

### 6.2 Mapping Square → Local

| Square field | Local field |
|-------------|-------------|
| `item.item_data.name` | `menu_item.name` |
| `item.item_data.description_plaintext` | `menu_item.description` |
| `variation.item_variation_data.price_money.amount` | `menu_item.price` (cents ÷ 100 via BigDecimal) |
| `item.item_data.categories[0].id` → category name lookup | `menu_item.category` |
| `item.id` | `menu_item.square_catalog_id` |
| `variation.id` | `menu_item.square_variation_id` |

### 6.3 Triggering Sync

- **Rake task:** `bin/rails square:sync_menu`
- **Future:** Background job via Solid Queue, Square webhook on `catalog.version.updated`

### 6.4 Seeding the Square Catalog

The Square sandbox catalog was seeded via the Catalog API (`POST /v2/catalog/batch-upsert`) using Bruno. Key learnings:

- Use `description_html` (not `description_plaintext` which is read-only)
- Include `item_id` in each variation's `item_variation_data`
- Currency must match the Square account's country (CAD for Canada)
- Use `#temp-id` format for temporary IDs in batch upsert

## 7. Order Push

### 7.1 Flow

```
Customer places order via Claude
        |
MCP Server calls POST /api/v1/orders
        |
OrdersController#create
  1. Build order + order_items (existing logic)
  2. Calculate total_cents
  3. Save to database
  4. ::Pos::SquareAdapter.new.push_order(order)
  5. OrderMailer.confirmation(order).deliver_later
  6. Return JSON response
```

### 7.2 Square Orders API Request

```ruby
{
  idempotency_key: order.id,  # UUID, naturally unique
  order: {
    location_id: credentials[:location_id],
    line_items: order.order_items.map { |oi|
      {
        catalog_object_id: oi.menu_item.square_variation_id,
        quantity: oi.quantity.to_s,
        note: oi.modifications  # free-text modifications
      }.compact
    },
    fulfillments: [{
      type: "PICKUP",
      state: "PROPOSED",
      pickup_details: {
        recipient: {
          display_name: order.customer_name,
          email_address: order.customer_email
        },
        pickup_at: parse_pickup_time(order.pickup_time),  # RFC 3339
        note: "Ordered via AI assistant"
      }
    }]
  }
}
```

### 7.3 Pickup Time Parsing

Square requires `pickup_at` in RFC 3339 format. The customer provides free-text like "7:00 PM". The adapter parses this to today's date at that time, rolling to tomorrow if the time has passed. Falls back to 1 hour from now if parsing fails.

### 7.4 Error Handling

If the Square push fails:
- The local order is still saved (status: `pending`)
- The `square_order_id` remains null
- Error + Square response body are logged
- The customer still gets their confirmation email
- Future: retry job, admin alert

## 8. MCP Server

### 8.1 Setup

Lives at `/mcp-server`. Node.js + TypeScript project using `@modelcontextprotocol/sdk`. Communicates via stdio transport.

Build and run:
```bash
cd mcp-server && npm install && npm run build
node dist/index.js
```

Claude Desktop config (`claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "restaurant": {
      "command": "node",
      "args": ["/path/to/restaurant-api/mcp-server/dist/index.js"]
    }
  }
}
```

### 8.2 Tools

| Tool | Method | Endpoint | Description |
|------|--------|----------|-------------|
| `get_menu` | GET | `/api/v1/menu` | Returns available menu items with prices |
| `place_order` | POST | `/api/v1/orders` | Places an order with items, customer info, pickup time |
| `track_order` | GET | `/api/v1/orders/:id` | Returns order status and details |
| `cancel_order` | PATCH | `/api/v1/orders/:id/cancel` | Cancels a pending order |

Tool schemas use Zod for validation. The `place_order` tool accepts `customer_name`, `customer_email`, `pickup_time`, and an `items` array with `menu_item_id`, `quantity`, and optional `modifications`.

### 8.3 Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `MCP_API_BASE_URL` | Rails API URL | `http://localhost:3000` |

## 9. Configuration

### 9.1 Square Credentials

Stored in Rails encrypted credentials (`EDITOR="code --wait" bin/rails credentials:edit`):

```yaml
square:
  environment: sandbox         # or production
  access_token: EAAAl...       # Square sandbox access token
  location_id: L...            # Square location ID
```

Access pattern: `Rails.application.credentials.square[:access_token]`

### 9.2 Environment Variables

| Variable | Purpose |
|----------|---------|
| `RAILS_MASTER_KEY` | Decrypts Rails credentials (includes Square token) |
| `MCP_API_BASE_URL` | Rails API URL for MCP server (default: `http://localhost:3000`) |

## 10. Email

Order confirmation via Action Mailer. Triggered by `OrderMailer.confirmation(order).deliver_later` after successful order creation.

### 10.1 Contents

- Order ID (truncated UUID for readability)
- Customer name
- Itemized order summary with quantities, modifications, and prices
- Order total
- Pickup time
- Cancellation instructions

### 10.2 Templates

- `confirmation.html.erb` — styled HTML table layout
- `confirmation.text.erb` — plain text fallback

### 10.3 Development

Uses `letter_opener` gem — emails open in the browser automatically. Configured in `config/environments/development.rb`.

## 11. Build Order (As Executed)

| Step | Task | Status |
|------|------|--------|
| 1 | Add `square` gem to Gemfile + Tapioca RBI | Done |
| 2 | Add Square credentials to Rails encrypted credentials | Done |
| 3 | Migration for Square fields on menu_items and orders | Done |
| 4 | Build `Pos::BaseAdapter` interface | Done |
| 5 | Build `Pos::SquareAdapter#sync_menu` using Faraday | Done |
| 6 | Build rake task `square:sync_menu`, test against sandbox | Done |
| 7 | Build `Pos::SquareAdapter#push_order` | Done |
| 8 | Wire `push_order` into `OrdersController#create` | Done |
| 9 | Add `OrderMailer#confirmation` + letter_opener | Done |
| 10 | Build MCP server with 4 tools | Done |
| 11 | End-to-end test: Claude → MCP → Rails → Square + email | Done |
| 12 | Polish: cleanup dupes, gitignore, error handling, linting | Done |

## 12. Lessons Learned

- The `square` gem (v0.0.4) is an old community gem, not the official Square SDK. Faraday direct HTTP calls work fine as an alternative.
- Square's `description_plaintext` is read-only on write endpoints — use `description_html` when creating catalog items.
- Square requires `pickup_at` in RFC 3339 format for PICKUP fulfillments — free-text times need parsing.
- The `::Pos` root namespace prefix is required when referencing from inside `Api::V1` controllers.
- Square sandbox dashboard does not display API-created orders. Use the Orders API (`GET /v2/orders/:id`) to verify orders exist.
- Sorbet RBS inline annotations (`#:`) on instance variable assignments with blocks need workarounds (assign to local var first).

## 13. Future Considerations (Post MVP 2)

| Feature | Notes |
|---------|-------|
| Square Payments | Charge via Square Payments API at order time |
| Square Webhooks | Real-time catalog updates and order status changes |
| Toast Adapter | Second POS adapter, proving the pattern generalizes |
| Multi-restaurant | Restaurant model, per-restaurant POS config |
| WhatsApp Channel | Twilio adapter + Claude API for conversational ordering |
| Cart / Draft Orders | Multi-turn order building before submission |
| Order Modifications | Map `modifications` string to Square modifier catalog objects |
| Background Sync Job | Scheduled catalog sync via Solid Queue |
| `get_order_status` | Implement Square order status retrieval in adapter |

---

End of Document
