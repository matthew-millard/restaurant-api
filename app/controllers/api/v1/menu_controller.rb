# typed: true
# frozen_string_literal: true

module Api
  module V1
    class MenuController < ApplicationController
      #: -> void
      def index
        items = MenuItem.where(available: true)
        render json: items
      end
    end
  end
end
