# typed: true
# frozen_string_literal: true

class Order < ApplicationRecord
  has_many :order_items, dependent: :destroy

  validates :customer_name, presence: true
  validates :customer_email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :status, presence: true, inclusion: { in: %w[pending preparing ready completed cancelled] }
  validates :total_cents, presence: true, numericality: { greater_than_or_equal_to: 0 }
end
