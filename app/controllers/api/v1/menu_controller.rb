module Api
  module V1
    class MenuController < ApplicationController
      def index
        items = MenuItem.where(available: true)
        render json: items
      end
    end
  end
end
