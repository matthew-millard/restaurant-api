# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_04_18_035318) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "menu_items", force: :cascade do |t|
    t.string "name"
    t.string "description"
    t.decimal "price"
    t.string "category"
    t.boolean "available", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "square_catalog_id"
    t.string "square_variation_id"
    t.datetime "last_synced_at"
    t.index ["square_catalog_id"], name: "index_menu_items_on_square_catalog_id", unique: true
    t.index ["square_variation_id"], name: "index_menu_items_on_square_variation_id", unique: true
  end

  create_table "order_items", force: :cascade do |t|
    t.uuid "order_id", null: false
    t.bigint "menu_item_id", null: false
    t.integer "quantity"
    t.string "modifications"
    t.integer "unit_price_cents"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["menu_item_id"], name: "index_order_items_on_menu_item_id"
    t.index ["order_id"], name: "index_order_items_on_order_id"
  end

  create_table "orders", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "customer_name"
    t.string "customer_email"
    t.string "status", default: "pending"
    t.string "pickup_time"
    t.integer "total_cents"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "square_order_id"
    t.index ["square_order_id"], name: "index_orders_on_square_order_id", unique: true
  end

  add_foreign_key "order_items", "menu_items"
  add_foreign_key "order_items", "orders"
end
