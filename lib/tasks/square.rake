# typed: false
# frozen_string_literal: true

namespace :square do
  desc "Sync menu items from Square catalog"
  task sync_menu: :environment do
    puts "Syncing menu from Square..."
    Pos::SquareAdapter.new.sync_menu
    puts "Done. #{MenuItem.where(available: true).count} items available."
  end
end
