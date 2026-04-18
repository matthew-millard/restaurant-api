# Restaurant Ordering Platform — MVP 2 Design Document

Version 2.0 • April 2026 • Confidential

---

## 1. Overview

MVP 1 proved the end-to-end flow: customer chats with Claude, MCP server translates to API calls, Rails API manages orders, email confirmation goes out. Menu data was manually seeded.

MVP 2 introduces **Square as the first POS adapter**. The restaurant manages their menu in Square. Our platform syncs it, lets customers order through Claude, and fires completed orders back to Square. This establishes the POS adapter pattern that future integrations (Toast, Maitre'd, etc.) will follow.

## 2. MVP 2 Goals

**In scope:**

- Sync menu catalog from Square sandbox into local database
- Establish the POS adapter interface pattern (starting with Square)
- Push placed orders to Square Orders API
- MCP server lives in the same repo as the Rails API
- Continue using Claude as the conversational interface
- Email confirmation on order placement (carried over from MVP 1)

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
MCP Server (Node.js, same repo under /mcp-server)
        |
Rails API (business logic, POS adapter layer)
        |
   +---------+---------+
   |                   |
PostgreSQL         Square API
(local data)       (catalog sync, order push)
```

### 3.2 Components

| Component | Technology | Responsibility |
|-----------|-----------|----------------|
| LLM + Chat UI | Claude (claude.ai) | Natural language understanding, tool orchestration |
| MCP Server | Node.js (@modelcontextprotocol/sdk) | Exposes tools to Claude, translates to HTTP |
| Rails API | Ruby on Rails 8 (API mode) | Business logic, POS adapter orchestration |
| POS Adapter | Ruby service classes | Abstracts POS-specific API calls behind a common interface |
| Database | PostgreSQL | Menu items, orders, order items, sync metadata |
| Email | Action Mailer | Order confirmation emails |
| Square SDK | square Ruby gem | HTTP client for Square API |

### 3.3 Directory Structure (additions to existing project)

```
restaurant-api/
├── app/
│   ├── controllers/api/v1/
│   │   ├── menu_controller.rb        (existing)
│   │   └── orders_controller.rb      (existing, modified)
│   ├── models/
│   │   ├── menu_item.rb              (existing, modified)
│   │   ├── order.rb                  (existing)
│   │   └── order_item.rb             (existing)
│   ├── services/
│   │   └── pos/
│   │       ├── base_adapter.rb       (new — adapter interface)
│   │       └── square_adapter.rb     (new — Square implementation)
│   ├── jobs/
│   │   └── sync_menu_job.rb          (new — background catalog sync)
│   └── mailers/
│       └── order_mailer.rb           (new — confirmation email)
├── mcp-server/                       (new — MCP server)
│   ├── package.json
│   ├── src/
│   │   └── index.ts
│   └── tsconfig.json
├── config/
│   └── square.yml                    (new — Square credentials per env)
├── lib/
│   └── tasks/
│       └── square.rake               (new — manual sync rake task)
└── docs/
    └── mvp2_design_doc.md            (this file)
```

## 4. POS Adapter Pattern

### 4.1 Base Interface

All POS adapters implement a common interface. This is what the Rails API calls — it never touches a POS SDK directly.

```ruby
# app/services/pos/base_adapter.rb
class Pos::BaseAdapter
  def sync_menu
    # Pull catalog from POS, upsert into local menu_items table
    raise NotImplementedError
  end

  def push_order(order)
    # Send a placed order to the POS system
    raise NotImplementedError
  end

  def get_order_status(external_order_id)
    # Check order status on the POS side
    raise NotImplementedError
  end
end
```

### 4.2 Square Adapter

```ruby
# app/services/pos/square_adapter.rb
class Pos::SquareAdapter < Pos::BaseAdapter
  def initialize
    @client = Square::Client.new(
      token: credentials[:access_token],
      environment: credentials[:environment]
    )
  end

  def sync_menu
    # 1. Fetch categories from Square catalog API
    # 2. Fetch items + variations from Square catalog API
    # 3. Upsert into local menu_items table
    # 4. Mark items not in Square as unavailable
  end

  def push_order(order)
    # 1. Build Square CreateOrder request from local order
    # 2. Map menu_item.square_item_variation_id to line items
    # 3. POST to Square Orders API
    # 4. Store Square order ID on local order record
  end

  def get_order_status(external_order_id)
    # GET from Square Orders API, map to local status enum
  end

  private

  def credentials
    Rails.application.credentials.square
  end
end
```

### 4.3 Adapter Resolution

For MVP 2 (single restaurant), adapter selection is simple:

```ruby
# Used in controllers and jobs
def pos_adapter
  Pos::SquareAdapter.new
end
```

In a future multi-tenant version, this becomes:

```ruby
def pos_adapter
  Pos::AdapterFactory.for(restaurant) # reads restaurant.pos_type
end
```

## 5. Data Model Changes

### 5.1 menu_items — New Columns

| Column | Type | Notes |
|--------|------|-------|
| square_catalog_id | string | Square catalog object ID (e.g. `UBHQI324J3LAYQNFEX5YMJJT`) |
| square_variation_id | string | Square item variation ID (the purchasable unit) |
| last_synced_at | datetime | When this item was last synced from Square |

These columns allow the sync job to match Square catalog objects to local records and detect stale data.

### 5.2 orders — New Columns

| Column | Type | Notes |
|--------|------|-------|
| square_order_id | string | Square order ID after push, null until pushed |

### 5.3 Migration

```ruby
class AddSquareFieldsToMenuItems < ActiveRecord::Migration[8.0]
  def change
    add_column :menu_items, :square_catalog_id, :string
    add_column :menu_items, :square_variation_id, :string
    add_column :menu_items, :last_synced_at, :datetime

    add_index :menu_items, :square_catalog_id, unique: true
    add_index :menu_items, :square_variation_id, unique: true

    add_column :orders, :square_order_id, :string
    add_index :orders, :square_order_id, unique: true
  end
end
```

## 6. Menu Sync

### 6.1 Flow

```
Square Catalog API
        |
  GET /v2/catalog/list (types: CATEGORY, ITEM)
        |
  SquareAdapter#sync_menu
        |
  For each item + variation:
    - Find or initialize local menu_item by square_catalog_id
    - Update name, description, price, category
    - Set square_variation_id (needed for order push)
    - Set last_synced_at
    - Save
        |
  Mark any menu_items not seen in sync as available: false
```

### 6.2 Mapping Square → Local

| Square field | Local field |
|-------------|-------------|
| `item.item_data.name` | `menu_item.name` |
| `item.item_data.description_plaintext` | `menu_item.description` |
| `variation.item_variation_data.price_money.amount` | `menu_item.price` (convert cents → dollars) |
| `item.item_data.categories[0].id` → category name lookup | `menu_item.category` |
| `item.id` | `menu_item.square_catalog_id` |
| `variation.id` | `menu_item.square_variation_id` |

### 6.3 Triggering Sync

- **Rake task** for manual runs: `rails square:sync_menu`
- **Background job** for scheduled runs: `SyncMenuJob` via Solid Queue
- **Future:** Square webhook on `catalog.version.updated` for real-time sync

## 7. Order Push

### 7.1 Flow

```
Customer places order via Claude
        |
MCP Server calls POST /api/v1/orders
        |
OrdersController#create
  1. Build order + order_items (existing logic)
  2. Calculate total_cents (existing logic)
  3. Save to database
  4. Call pos_adapter.push_order(order)
  5. Send confirmation email
  6. Return response
```

### 7.2 Square Orders API Mapping

```ruby
# Inside SquareAdapter#push_order
{
  idempotency_key: order.id, # UUID, naturally unique
  order: {
    location_id: credentials[:location_id],
    line_items: order.order_items.map { |item|
      {
        catalog_object_id: item.menu_item.square_variation_id,
        quantity: item.quantity.to_s,
        modifiers: [],  # future: map modifications to Square modifiers
        note: item.modifications
      }
    },
    fulfillments: [
      {
        type: "PICKUP",
        state: "PROPOSED",
        pickup_details: {
          recipient: {
            display_name: order.customer_name,
            email_address: order.customer_email
          },
          pickup_at: order.pickup_time,
          note: "Ordered via AI assistant"
        }
      }
    ]
  }
}
```

### 7.3 Error Handling

If the Square push fails:
- The local order is still saved (status: `pending`)
- The `square_order_id` remains null
- Log the error for debugging
- The customer still gets their confirmation email with order ID
- Future: retry job, admin alert, manual push option

## 8. MCP Server

### 8.1 Location

Lives at `/mcp-server` in the same repo. Separate Node.js project with its own `package.json`.

### 8.2 Tools

| Tool | Maps to | Description |
|------|---------|-------------|
| `get_menu` | `GET /api/v1/menu` | Returns available menu items with prices |
| `place_order` | `POST /api/v1/orders` | Places an order with items, customer info, pickup time |
| `track_order` | `GET /api/v1/orders/:id` | Returns order status and details |
| `cancel_order` | `PATCH /api/v1/orders/:id/cancel` | Cancels a pending order |

### 8.3 Tool Schema Example

```typescript
{
  name: "place_order",
  description: "Place a new order. Requires customer name, email, pickup time, and at least one item.",
  inputSchema: {
    type: "object",
    properties: {
      customer_name: { type: "string", description: "Customer's name" },
      customer_email: { type: "string", description: "Customer's email address" },
      pickup_time: { type: "string", description: "Requested pickup time, e.g. '7:00 PM'" },
      items: {
        type: "array",
        items: {
          type: "object",
          properties: {
            menu_item_id: { type: "number", description: "ID of the menu item" },
            quantity: { type: "number", description: "Quantity to order" },
            modifications: { type: "string", description: "Special requests, e.g. 'No pickles'" }
          },
          required: ["menu_item_id", "quantity"]
        }
      }
    },
    required: ["customer_name", "customer_email", "pickup_time", "items"]
  }
}
```

## 9. Configuration

### 9.1 Square Credentials

Stored in Rails encrypted credentials (`rails credentials:edit`):

```yaml
square:
  environment: sandbox         # or production
  access_token: EAAAl...       # Square access token
  location_id: L...            # Square location ID
```

### 9.2 Environment Variables

| Variable | Purpose |
|----------|---------|
| `RAILS_MASTER_KEY` | Decrypts Rails credentials (includes Square token) |
| `MCP_API_BASE_URL` | Rails API URL for MCP server (default: `http://localhost:3000`) |

## 10. Email (Carried from MVP 1)

Order confirmation via Action Mailer. Triggered after successful order creation.

### 10.1 Contents

- Order ID (for tracking)
- Customer name
- Itemized order summary with quantities, modifications, and prices
- Order total
- Pickup time
- Cancellation instructions

### 10.2 Setup

- **Development:** `letter_opener` gem (opens email in browser)
- **Production:** SMTP provider (SendGrid, Mailgun, etc.)

## 11. Build Order

| Step | Task | Dependencies |
|------|------|-------------|
| 1 | Add `square` gem to Gemfile | None |
| 2 | Add Square credentials to Rails encrypted credentials | None |
| 3 | Create migration for Square fields on menu_items and orders | None |
| 4 | Build `Pos::BaseAdapter` interface | None |
| 5 | Build `Pos::SquareAdapter#sync_menu` | Steps 1-4 |
| 6 | Build rake task `square:sync_menu` and test sync against sandbox | Step 5 |
| 7 | Build `Pos::SquareAdapter#push_order` | Steps 1-4 |
| 8 | Modify `OrdersController#create` to call `push_order` after save | Step 7 |
| 9 | Add Action Mailer for order confirmation | None |
| 10 | Build MCP server under `/mcp-server` | None |
| 11 | Connect MCP server to Claude and test end-to-end | Steps 6, 8, 9, 10 |
| 12 | Polish and demo | Step 11 |

## 12. Testing Strategy

- **Menu sync:** Run rake task against Square sandbox, verify local menu_items match Square catalog
- **Order push:** Place order via Bruno/Postman, verify order appears in Square sandbox dashboard
- **MCP flow:** Chat with Claude, place order, verify it hits Rails API AND Square
- **Email:** Verify letter_opener shows confirmation email in development
- **Error cases:** Square API down, invalid item IDs, cancelled order push

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

---

End of Document
