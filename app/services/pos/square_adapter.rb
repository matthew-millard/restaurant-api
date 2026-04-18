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
      raise NotImplementedError, "#{self.class}#push_order is not implemented"
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
