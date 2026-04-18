# typed: true
# frozen_string_literal: true

module Api
  module V1
    class OrdersController < ApplicationController
      #: -> void
      def show
        order = Order.find(params[:id])
        render json: order_response(order)
      end

      #: -> void
      def create
        order = Order.new(
          customer_name: order_params[:customer_name],
          customer_email: order_params[:customer_email],
          pickup_time: order_params[:pickup_time]
        )

        total_cents = 0

        items = order_params[:items]
        return render json: { errors: [ "Items are required" ] }, status: :unprocessable_entity if items.nil?

        items.each do |item_data|
          menu_item = MenuItem.find(item_data[:menu_item_id])
          price = menu_item.price
          next unless price

          unit_price_cents = (price * 100).to_i
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
          Pos::SquareAdapter.new.push_order(order)
          render json: order_response(order), status: :created
        else
          render json: { errors: order.errors.full_messages }, status: :unprocessable_entity
        end
      end

      #: -> void
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

      #: -> ActionController::Parameters
      def order_params
        params.require(:order).permit(:customer_name, :customer_email, :pickup_time, items: [ :menu_item_id, :quantity, :modifications ])
      end

      #: (Order) -> Hash[Symbol, untyped]
      def order_response(order)
        {
          id: order.id,
          status: order.status,
          customer_name: order.customer_name,
          customer_email: order.customer_email,
          pickup_time: order.pickup_time,
          total: format_dollars(order.total_cents),
          items: order.order_items.includes(:menu_item).filter_map { |oi|
            mi = oi.menu_item
            next unless mi

            unit_price = oi.unit_price_cents || 0
            qty = oi.quantity || 0

            {
              name: mi.name,
              quantity: qty,
              modifications: oi.modifications,
              price: format_dollars(unit_price * qty)
            }
          }
        }
      end

      #: (Integer?) -> String
      def format_dollars(cents)
        cents = cents || 0
        "$#{'%.2f' % (cents / 100.0)}"
      end
    end
  end
end
