# typed: true
# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: "orders@restaurant-api.local"
  layout "mailer"
end
