require 'rest-client'
require 'json'







# ================================
# Functions
# ================================

def get_api_json(endpoint, *params)
	url = endpoint + "?" + params.join("&")
	response = RestClient.get(url)
	if response.code != 200 then
		puts "Issue with Universalis.app API (HTTP #{response.code})"
		puts "Endpoint : #{endpoint}"
		exit
	end
	return JSON.parse(response)
end

def in_margin?(a, b, percent)
	return a >= b * (100 - percent) / 100.0 &&
		a <= b * (100 + percent) / 100.0
end

def get_item_ids(lines)
	a = []
	lines.each do | line |
		if line != nil && line.chomp.length > 0 && line[0] != "\#" then
			line.split(",").each do | i |
				a << i.to_i if i != nil
			end
		end
	end
	return a
end

def get_hours_diff(timestamp)
	return ((Time.now.to_i - timestamp)/3600.0).round.to_s
end





# ================================
# Get item names
# ================================

item_ids_hq = get_item_ids(IO.readlines("./data/item_ids_hq_only.txt"))
item_ids_mixed = get_item_ids(IO.readlines("./data/item_ids.txt"))
item_ids = item_ids_hq + item_ids_mixed

items_names_json = get_api_json("https://xivapi.com/item", "limit=1000", "ids="+item_ids.join(","))
item_names = {}
items_names_json["Results"].each do | item |
	item_names[item["ID"]] = item["Name"]
end





# ================================
# Get auctions
# ================================

out = {}

auctions_hq = get_api_json(
	"https://universalis.app/api/chaos/#{item_ids_hq.join(',')}",
	"hq=true"
)
auctions_mixed = get_api_json(
	"https://universalis.app/api/chaos/#{item_ids_mixed.join(',')}",
	"hq=false"
)

# If 0-1 results, wrap in "items" hash to match the expected format
if item_ids_hq.size <= 1 then auctions_hq = {"items" => [auctions_hq]} end
if item_ids_mixed.size <= 1 then auctions_mixed = {"items" => [auctions_mixed]} end

[auctions_hq, auctions_mixed].each do | auctions |
	auctions["items"].each do | item |
		
		next if item["listings"] == nil or item["listings"].empty? or item["listings"][0] == nil

		item_id = item["itemID"].to_s
		hq_needed = item_ids_hq.include?(item["itemID"])

		# Count how many auctions are in a x% margin on the same server than the lowest auction
		listings_in_margin = -1
		listing_lowest_server = ""
		listing_lowest_price = 999999999
		# listing_lowest_server = item["listings"][0]["worldName"]
		# listing_lowest_price = item["listings"][0]["pricePerUnit"]

		item["listings"].each do | listing |
			next if listing["hq"] == false && hq_needed == true # Skip if it's not HQ and we want HQ only
			if listing_lowest_server == "" then # first item encountered / loop
				listing_lowest_server = listing["worldName"]
				listing_lowest_price = listing["pricePerUnit"]
			end
			next if listing["worldName"] != listing_lowest_server
			break if !in_margin?(listing["pricePerUnit"], listing_lowest_price, 2) # max margin reached, no need to go further
			listings_in_margin = listings_in_margin + 1
		end

		out[item_id] = {}
		out[item_id]["name"] = item_names[item_id.to_i]
		out[item_id]["hq_needed"] = hq_needed
		out[item_id]["best_auction_price"] = listing_lowest_price
		out[item_id]["best_auction_server"] = listing_lowest_server
		out[item_id]["best_auction_seller"] = item["listings"][0]["retainerName"]
		out[item_id]["best_auction_update_timestamp"] = item["listings"][0]["lastReviewTime"]
		out[item_id]["auctions_in_margin"] = listings_in_margin == -1 ? 0 : listings_in_margin

	end
end

File.write("./data_archive/auctions_hq.json", JSON.pretty_generate(auctions_hq))
File.write("./data_archive/auctions_mixed.json", JSON.pretty_generate(auctions_mixed))





# ================================
# Get history
# ================================

history = get_api_json(
	"https://universalis.app/api/history/71/#{item_ids.join(',')}",
	"entries=10"
)

history["items"].each do | item |
	item_id = item["itemID"].to_s
	hq_needed = item_ids_hq.include?(item["itemID"])

	next if item["entries"].size == 0 # no item listed on this server
	# next if out[item_id] == nil # just to be sure

	entries_counter = 0
	entries_total_price = 0
	entries_last_timestamp = 0
	entries_last_price = 0

	item["entries"].each do | entry |
		next if entry["hq"] == false && hq_needed == true
		entries_counter += 1
		entries_total_price = entries_total_price + entry["pricePerUnit"]
		if entry["timestamp"] > entries_last_timestamp then
			entries_last_price = entry["pricePerUnit"]
			entries_last_timestamp = entry["timestamp"]
		end
	end

	next if entries_counter == 0 && hq_needed == true # All items are NQ

	out[item_id]["history_last_update"] = (item["lastUploadTime"] / 1000.0).round
	out[item_id]["history_sale_velocity"] = item["hqSaleVelocity"].round(2)
	out[item_id]["last_sale_price"] = entries_last_price
	out[item_id]["last_sale_timestamp"] = entries_last_timestamp
	out[item_id]["last_sales_price_avg"] = (entries_total_price/entries_counter).round
end

File.write("./data_archive/history.json", JSON.pretty_generate(history))



# ================================
# Export
# ================================

File.write("./data_archive/raw_data.json", JSON.pretty_generate(out))

csv = []

csv << [
	"id" + " "*12, # Padding for Excel auto-width
	"name" + " "*45, # Padding for Excel auto-width
	"auction_price",
	"auction_server",
	"m_last_sale",
	"m_price_avg",
	"raw_profit",
	"profit%",
	# "auction_seller",
	# "auction_time",
	"last_update",
	"auctions_in_margin",
	"m_last_sale_time",
	#"history_sale_velocity",
	].join(";")

out = out.sort.to_h
out.each do | key, value |
	
	next if value["last_sale_price"] == nil || value["best_auction_price"] == nil
	profit_value = value["last_sale_price"] - value["best_auction_price"]
	profit_percent = [((value["last_sale_price"] / value["best_auction_price"].to_f)*100-100), 0].max.round

	# filter output CSV based on potential profit
	next if profit_value < 10000 or profit_percent < 20

	line = []

	line << key # id
	line << value["name"]
	line << value["best_auction_price"]
	line << value["best_auction_server"]
	line << value["last_sale_price"]
	line << value["last_sales_price_avg"]
	line << profit_value
	line << profit_percent if profit_percent
	# line << value["best_auction_seller"]
	# get_hours_diff(value["best_auction_update_timestamp"]),
	line << get_hours_diff(value["history_last_update"])
	line << value["auctions_in_margin"]
	line << get_hours_diff(value["last_sale_timestamp"])
	# line << value["history_sale_velocity"]
	
	csv << line.join(";")
end

IO.write("./data/data.csv", csv.join("\n"))
puts "=> File written to : ./data/data.csv"