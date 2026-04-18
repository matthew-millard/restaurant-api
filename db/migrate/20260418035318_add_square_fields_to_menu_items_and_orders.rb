class AddSquareFieldsToMenuItemsAndOrders < ActiveRecord::Migration[8.0]
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
