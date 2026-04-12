class CreateMenuItems < ActiveRecord::Migration[8.0]
  def change
    create_table :menu_items do |t|
      t.string :name
      t.string :description
      t.decimal :price
      t.string :category
      t.boolean :available, default: true

      t.timestamps
    end
  end
end
