-- Parcelo customer terminal
-- Put this on the normal player/customer computer

local MODEM_SIDE = "back"
local HOST_PROTOCOL = "parcelo_host"
local HOSTNAME = "parcelo_server"
local API_PROTOCOL = "parcelo_api"
local CONFIG_FILE = "customer_config.txt"

local currentPlayer = nil

local function trim(s)
  if s == nil then return "" end
  return tostring(s):match("^%s*(.-)%s*$")
end

local function clear()
  term.clear()
  term.setCursorPos(1, 1)
end

local function pause()
  print("")
  print("Press any key...")
  os.pullEvent("key")
end

local function ask(prompt, allowEmpty)
  write(prompt .. ": ")
  local value = read()
  value = trim(value)
  if not allowEmpty then
    while value == "" do
      write(prompt .. ": ")
      value = trim(read())
    end
  end
  return value
end

local function formatRemaining(ms)
  if not ms or ms <= 0 then
    return "Expired"
  end

  local totalSeconds = math.floor(ms / 1000)
  local minutes = math.floor(totalSeconds / 60)
  local seconds = totalSeconds % 60
  return string.format("%dm %02ds", minutes, seconds)
end

local function loadConfig()
  if fs.exists(CONFIG_FILE) then
    local f = fs.open(CONFIG_FILE, "r")
    local raw = f.readAll()
    f.close()
    local data = textutils.unserialise(raw)
    if type(data) == "table" then
      currentPlayer = data.player
    end
  end
end

local function saveConfig()
  local f = fs.open(CONFIG_FILE, "w")
  f.write(textutils.serialise({
    player = currentPlayer
  }))
  f.close()
end

local function findServer()
  return rednet.lookup(HOST_PROTOCOL, HOSTNAME)
end

local function request(payload)
  local serverId = findServer()
  if not serverId then
    return nil, "Server not found. Is server.lua running?"
  end

  rednet.send(serverId, payload, API_PROTOCOL)
  local senderId, response = rednet.receive(API_PROTOCOL, 5)

  if not senderId then
    return nil, "Server timeout"
  end

  if senderId ~= serverId then
    return nil, "Wrong server response"
  end

  return response, nil
end

local function showHeader()
  clear()
  print("== Parcelo ==")
  print("Player: " .. (currentPlayer or "Not set"))
  print("")
end

local function setPlayerName()
  showHeader()
  local name = ask("Enter your player name", false)
  currentPlayer = name
  saveConfig()
  print("")
  print("Saved player name: " .. currentPlayer)
  pause()
end

local function showOrderDetails(order)
  clear()
  print("== Order Details ==")
  print("Order ID: " .. order.orderId)
  print("Tracking: " .. (order.trackingId or "Not assigned yet"))
  print("Player: " .. (order.player or "-"))
  print("Item: " .. (order.itemName or "-"))
  print("Amount: " .. tostring(order.amount or 0))
  print("Delivery: " .. (order.deliveryType or "-"))
  print("Address: " .. ((order.address and order.address ~= "") and order.address or "-"))
  print("Status: " .. (order.status or "-"))
  print("Locker: " .. (order.locker or "-"))

  if order.pickupExpiresAt then
    local remaining = order.pickupExpiresAt - os.epoch("utc")
    print("Pickup Time Left: " .. formatRemaining(remaining))
  end

  print("")
  print("-- History --")
  if order.history and #order.history > 0 then
    for i = 1, math.min(#order.history, 8) do
      local h = order.history[i]
      print((h.status or "?") .. " | by " .. (h.by or "?"))
      if h.note and h.note ~= "" then
        print("  " .. h.note)
      end
    end
  else
    print("No history")
  end

  pause()
end

local function placeOrder()
  if not currentPlayer then
    setPlayerName()
    if not currentPlayer then
      return
    end
  end

  showHeader()
  print("Place a new order")
  print("")

  local itemName = ask("Item name", false)
  local amount = tonumber(ask("Amount", false)) or 1
  local deliveryType = ask("Delivery type (home/locker)", false)
  local address = ask("Address/notes", true)

  local response, err = request({
    action = "place_order",
    player = currentPlayer,
    itemName = itemName,
    amount = amount,
    deliveryType = deliveryType,
    address = address
  })

  showHeader()
  if not response then
    print("Error: " .. err)
  elseif not response.ok then
    print("Error: " .. (response.message or "Unknown error"))
  else
    print("Order placed!")
    print("Order ID: " .. response.order.orderId)
    print("Status: " .. response.order.status)
  end

  pause()
end

local function myOrders()
  if not currentPlayer then
    setPlayerName()
    if not currentPlayer then
      return
    end
  end

  showHeader()

  local response, err = request({
    action = "get_my_orders",
    player = currentPlayer
  })

  if not response then
    print("Error: " .. err)
    pause()
    return
  end

  if not response.ok then
    print("Error: " .. (response.message or "Unknown error"))
    pause()
    return
  end

  local orders = response.orders or {}

  if #orders == 0 then
    print("You have no orders yet.")
    pause()
    return
  end

  print("Your orders:")
  print("")

  for i = 1, math.min(#orders, 8) do
    local o = orders[i]
    print(o.orderId .. " | " .. o.itemName .. " x" .. tostring(o.amount))
    print("Status: " .. (o.status or "-"))
    print("Tracking: " .. (o.trackingId or "Not assigned yet"))
    print("------------------------------")
  end

  print("")
  local orderId = ask("Type an Order ID to view details (blank to cancel)", true)
  if orderId ~= "" then
    local detailRes, detailErr = request({
      action = "get_order",
      orderId = orderId
    })

    if detailRes and detailRes.ok and detailRes.order then
      showOrderDetails(detailRes.order)
    else
      clear()
      print("Could not open order.")
      if detailErr then
        print(detailErr)
      elseif detailRes and detailRes.message then
        print(detailRes.message)
      end
      pause()
    end
  end
end

local function trackByCode()
  showHeader()
  local trackingId = ask("Enter tracking code", false)

  local response, err = request({
    action = "get_by_tracking",
    trackingId = trackingId
  })

  if not response then
    print("Error: " .. err)
    pause()
    return
  end

  if not response.ok then
    print("Error: " .. (response.message or "Unknown error"))
    pause()
    return
  end

  showOrderDetails(response.order)
end

local function pingServer()
  showHeader()
  local response, err = request({
    action = "ping"
  })

  if not response then
    print("Error: " .. err)
  else
    print(response.message or "Server responded")
  end
  pause()
end

loadConfig()

if not rednet.isOpen(MODEM_SIDE) then
  rednet.open(MODEM_SIDE)
end

while true do
  showHeader()
  print("1. Set / Change Player Name")
  print("2. Place Order")
  print("3. My Orders")
  print("4. Track by Tracking Code")
  print("5. Ping Server")
  print("6. Exit")
  print("")

  local choice = ask("Choose", false)

  if choice == "1" then
    setPlayerName()
  elseif choice == "2" then
    placeOrder()
  elseif choice == "3" then
    myOrders()
  elseif choice == "4" then
    trackByCode()
  elseif choice == "5" then
    pingServer()
  elseif choice == "6" then
    clear()
    print("Goodbye.")
    break
  end
end
