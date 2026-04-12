class CreateOrders < ActiveRecord::Migration[8.0]
  def change
    create_table :orders, id: :uuid do |t|
      t.string :customer_name
      t.string :customer_email
      t.string :status, default: "pending"
      t.string :pickup_time
      t.integer :total_cents

      t.timestamps
    end
  end
end
