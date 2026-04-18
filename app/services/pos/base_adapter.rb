# typed: true
# frozen_string_literal: true

module Pos
  class BaseAdapter
    #: -> void
    def sync_menu
      raise NotImplementedError, "#{self.class}#sync_menu is not implemented"
    end

    #: (Order order) -> void
    def push_order(order)
      raise NotImplementedError, "#{self.class}#push_order is not implemented"
    end

    #: (String external_order_id) -> String
    def get_order_status(external_order_id)
      raise NotImplementedError, "#{self.class}#get_order_status is not implemented"
    end
  end
end
