module Api
  module V1
    class OrdersController < ApplicationController
      def show
        order = Order.find(params[:id])
        render json: order_response(order)
      end

      def create
        order = Order.new(
          customer_name: order_params[:customer_name],
          customer_email: order_params[:customer_email],
          pickup_time: order_params[:pickup_time]
        )

        total_cents = 0

        order_params[:items].each do |item_data|
          menu_item = MenuItem.find(item_data[:menu_item_id])
          unit_price_cents = (menu_item.price * 100).to_i
          quantity = item_data[:quantity].to_i

          order.order_items.build(
            menu_item: menu_item,
            quantity: quantity,
            modifications: item_data[:modifications],
            unit_price_cents: unit_price_cents
          )

          total_cents += unit_price_cents * quantity
        end

        order.total_cents = total_cents

        if order.save
          render json: order_response(order), status: :created
        else
          render json: { errors: order.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def cancel
        order = Order.find(params[:id])

        if order.status == "pending"
          order.update!(status: "cancelled")
          render json: order_response(order)
        else
          render json: { error: "Order can only be cancelled when pending. Current status: #{order.status}" }, status: :unprocessable_entity
        end
      end

      private

      def order_params
        params.require(:order).permit(:customer_name, :customer_email, :pickup_time, items: [ :menu_item_id, :quantity, :modifications ])
      end

      def order_response(order)
        {
          id: order.id,
          status: order.status,
          customer_name: order.customer_name,
          customer_email: order.customer_email,
          pickup_time: order.pickup_time,
          total: format_dollars(order.total_cents),
          items: order.order_items.includes(:menu_item).map { |oi|
            {
              name: oi.menu_item.name,
              quantity: oi.quantity,
              modifications: oi.modifications,
              price: format_dollars(oi.unit_price_cents * oi.quantity)
            }
          }
        }
      end

      def format_dollars(cents)
        "$#{'%.2f' % (cents / 100.0)}"
      end
    end
  end
end
