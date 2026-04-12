menu_items = [
  # Burgers
  { name: "Classic Cheeseburger", description: "Beef patty with cheddar, lettuce, tomato, and pickles", price: 12.99, category: "burgers" },
  { name: "BBQ Bacon Burger", description: "Beef patty with bacon, cheddar, onion rings, and BBQ sauce", price: 14.99, category: "burgers" },
  { name: "Mushroom Swiss Burger", description: "Beef patty with sauteed mushrooms and Swiss cheese", price: 13.99, category: "burgers" },
  { name: "Veggie Burger", description: "Black bean patty with avocado, lettuce, and chipotle mayo", price: 11.99, category: "burgers" },

  # Sides
  { name: "French Fries", description: "Crispy golden fries with sea salt", price: 4.99, category: "sides" },
  { name: "Onion Rings", description: "Beer-battered onion rings with ranch dipping sauce", price: 5.99, category: "sides" },
  { name: "Sweet Potato Fries", description: "Crispy sweet potato fries with chipotle aioli", price: 5.49, category: "sides" },
  { name: "Side Salad", description: "Mixed greens with cherry tomatoes and balsamic vinaigrette", price: 4.49, category: "sides" },

  # Drinks
  { name: "Lemonade", description: "Fresh-squeezed lemonade", price: 3.49, category: "drinks" },
  { name: "Iced Tea", description: "House-brewed unsweetened iced tea", price: 2.99, category: "drinks" },
  { name: "Craft Root Beer", description: "Small-batch root beer on tap", price: 3.99, category: "drinks" },
  { name: "Sparkling Water", description: "Chilled sparkling mineral water", price: 2.49, category: "drinks" }
]

menu_items.each do |item|
  MenuItem.find_or_create_by!(name: item[:name]) do |mi|
    mi.description = item[:description]
    mi.price = item[:price]
    mi.category = item[:category]
  end
end

puts "Seeded #{MenuItem.count} menu items"
