# typed: true
# frozen_string_literal: true

class OrderMailer < ApplicationMailer
  #: (Order order) -> Mail::Message
  def confirmation(order)
    @order = order
    @order_items = order.order_items.includes(:menu_item)
    mail(to: order.customer_email, subject: "Order Confirmation ##{order.id[0..7]}")
  end
end
