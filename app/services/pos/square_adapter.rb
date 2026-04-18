# typed: true
# frozen_string_literal: true

module Pos
  class SquareAdapter < BaseAdapter
    BASE_URLS = {
      "sandbox" => "https://connect.squareupsandbox.com",
      "production" => "https://connect.squareup.com"
    } #: Hash[String, String]

    #: -> void
    def initialize
      creds = Rails.application.credentials.square
      @access_token = creds[:access_token] #: String
      conn = Faraday.new(url: BASE_URLS.fetch(creds[:environment])) do |f|
        f.request :json
        f.response :json
        f.response :raise_error
      end
      @connection = conn #: Faraday::Connection
    end

    #: -> void
    def sync_menu
      categories = fetch_category_map
      items = fetch_catalog_items
      synced_ids = [] #: Array[String]

      items.each do |item|
        item_data = item["item_data"]
        next unless item_data

        category_id = item_data.dig("categories", 0, "id")
        category_name = category_id ? categories.fetch(category_id, "uncategorized") : "uncategorized"

        Array(item_data["variations"]).each do |variation|
          variation_data = variation["item_variation_data"]
          next unless variation_data

          price_cents = variation_data.dig("price_money", "amount") || 0
          price_dollars = BigDecimal(price_cents.to_s) / 100

          menu_item = MenuItem.find_or_initialize_by(square_catalog_id: item["id"])
          menu_item.assign_attributes(
            name: item_data["name"],
            description: item_data["description_plaintext"],
            price: price_dollars,
            category: category_name,
            square_variation_id: variation["id"],
            last_synced_at: Time.current,
            available: true
          )
          menu_item.save!
          synced_ids << item["id"]
        end
      end

      MenuItem.where.not(square_catalog_id: [ nil, *synced_ids ]).update_all(available: false) # rubocop:disable Rails/SkipsModelValidations
    end

    #: (Order order) -> void
    def push_order(order)
      body = {
        idempotency_key: order.id,
        order: {
          location_id: Rails.application.credentials.square[:location_id],
          line_items: order.order_items.includes(:menu_item).map { |oi|
            {
              catalog_object_id: oi.menu_item&.square_variation_id,
              quantity: oi.quantity.to_s,
              note: oi.modifications
            }.compact
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
                pickup_at: parse_pickup_time(order.pickup_time),
                note: "Ordered via AI assistant"
              }
            }
          ]
        }
      }

      response = @connection.post("/v2/orders") do |req|
        req.headers["Authorization"] = "Bearer #{@access_token}"
        req.body = body
      end

      square_order_id = response.body.dig("order", "id")
      order.update!(square_order_id: square_order_id) if square_order_id
    rescue Faraday::Error => e
      body = e.response&.dig(:body) if e.respond_to?(:response)
      Rails.logger.error("Square push_order failed for Order##{order.id}: #{e.message} — #{body}")
    end

    #: (String external_order_id) -> String
    def get_order_status(external_order_id)
      raise NotImplementedError, "#{self.class}#get_order_status is not implemented"
    end

    private

    #: -> Hash[String, String]
    def fetch_category_map
      categories = {} #: Hash[String, String]
      cursor = nil #: String?

      loop do
        response = catalog_list("CATEGORY", cursor)
        Array(response["objects"]).each do |obj|
          categories[obj["id"]] = obj.dig("category_data", "name") || "uncategorized"
        end
        cursor = response["cursor"]
        break unless cursor
      end

      categories
    end

    #: -> Array[Hash[String, untyped]]
    def fetch_catalog_items
      items = [] #: Array[Hash[String, untyped]]
      cursor = nil #: String?

      loop do
        response = catalog_list("ITEM", cursor)
        items.concat(Array(response["objects"]))
        cursor = response["cursor"]
        break unless cursor
      end

      items
    end

    #: (String?) -> String
    def parse_pickup_time(time_string)
      parsed = Time.zone.parse(time_string.to_s)
      parsed = parsed.change(day: Time.current.day, month: Time.current.month, year: Time.current.year) if parsed
      # If the time is in the past, assume tomorrow
      parsed = parsed + 1.day if parsed && parsed < Time.current
      (parsed || 1.hour.from_now).iso8601
    end

    #: (String types, ?String? cursor) -> Hash[String, untyped]
    def catalog_list(types, cursor = nil)
      params = { types: types }
      params[:cursor] = cursor if cursor

      response = @connection.get("/v2/catalog/list", params) do |req|
        req.headers["Authorization"] = "Bearer #{@access_token}"
      end

      response.body
    end
  end
end
