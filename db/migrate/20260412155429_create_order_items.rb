class CreateOrderItems < ActiveRecord::Migration[8.0]
  def change
    create_table :order_items do |t|
      t.references :order, type: :uuid, null: false, foreign_key: true
      t.references :menu_item, null: false, foreign_key: true
      t.integer :quantity
      t.string :modifications
      t.integer :unit_price_cents

      t.timestamps
    end
  end
end
