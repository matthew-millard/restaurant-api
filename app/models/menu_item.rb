# typed: true
# frozen_string_literal: true

class MenuItem < ApplicationRecord
  has_many :order_items

  validates :name, presence: true
  validates :price, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :category, presence: true
end
