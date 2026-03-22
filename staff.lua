-- Parcelo staff terminal

local MODEM_SIDE = "back"
local HOST_PROTOCOL = "parcelo_host"
local HOSTNAME = "parcelo_server"
local API_PROTOCOL = "parcelo_api"
local STAFF_PIN = "4284"
local CONFIG_FILE = "staff_config.txt"

local staffName = nil

local STATUSES = {
  "Order Received",
  "Packaging",
  "Sorted at Warehouse",
  "Ready for Dispatch",
  "In Transit",
  "Arrived at Hub",
  "Out for Delivery",
  "Awaiting Pickup",
  "Delivered",
  "Final Pickup Day",
  "Return to Sender",
  "Returned"
}

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
  local value = trim(read())
  if not allowEmpty then
    while value == "" do
      write(prompt .. ": ")
      value = trim(read())
    end
  end
  return value
end

local function askSecret(prompt)
  write(prompt .. ": ")
  return trim(read("*"))
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
    if not f then return end
    local raw = f.readAll()
    f.close()

    local data = textutils.unserialise(raw)
    if type(data) == "table" then
      staffName = data.staffName
    end
  end
end

local function saveConfig()
  local f = fs.open(CONFIG_FILE, "w")
  if not f then return end
  f.write(textutils.serialise({
    staffName = staffName
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

  payload.staffPin = STAFF_PIN

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
  print("== Parcelo Staff ==")
  print("Staff: " .. (staffName or "Not logged in"))
  print("")
end

local function login()
  clear()
  print("== Staff Login ==")

  local enteredName = ask("Staff name", false)
  local enteredPin = askSecret("Staff PIN")

  if enteredPin ~= STAFF_PIN then
    print("")
    print("Wrong PIN.")
    pause()
    return false
  end

  staffName = enteredName
  saveConfig()

  print("")
  print("Logged in as " .. staffName)
  pause()
  return true
end

local function ensureLogin()
  if not staffName then
    return login()
  end
  return true
end

local function printIfHas(label, value)
  if value and trim(value) ~= "" then
    print(label .. ": " .. value)
  end
end

local function showOrderDetails(order)
  clear()
  print("== Staff Order View ==")
  print("Order ID: " .. order.orderId)
  print("Tracking: " .. (order.trackingId or "Not assigned yet"))
  print("Player: " .. (order.player or "-"))
  print("Item: " .. (order.itemName or "-"))
  print("Amount: " .. tostring(order.amount or 0))
  print("Delivery: " .. (order.deliveryType or "-"))

  printIfHas("Address", order.address)
  print("Status: " .. (order.status or "-"))

  if order.locker then
    print("Locker: " .. order.locker)
  end

  printIfHas("General Note", order.note)
  printIfHas("Locker Note", order.lockerNote)
  printIfHas("Delivery Note", order.deliveryNote)

  if order.pickupExpiresAt then
    local remaining = order.pickupExpiresAt - os.epoch("utc")
    print("Pickup Time Left: " .. formatRemaining(remaining))
  end

  print("")
  print("-- History --")
  if order.history and #order.history > 0 then
    for i = 1, math.min(#order.history, 10) do
      local h = order.history[i]
      print((h.status or "?") .. " | " .. (h.by or "?"))
      if h.note and trim(h.note) ~= "" then
        print("  " .. h.note)
      end
    end
  else
    print("No history")
  end

  pause()
end

local function chooseStatus()
  clear()
  print("== Choose Status ==")
  for i, status in ipairs(STATUSES) do
    print(i .. ". " .. status)
  end
  print("")
  local picked = tonumber(ask("Status number", false))
  if picked and STATUSES[picked] then
    return STATUSES[picked]
  end
  return nil
end

local function listOrders()
  if not ensureLogin() then return end

  showHeader()
  local response, err = request({
    action = "get_all_orders"
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
    print("No orders found.")
    pause()
    return
  end

  for i = 1, math.min(#orders, 10) do
    local o = orders[i]
    print(o.orderId .. " | " .. o.itemName .. " x" .. tostring(o.amount))
    print("Status: " .. (o.status or "-"))
    if o.trackingId then
      print("Tracking: " .. o.trackingId)
    end
    print("Player: " .. (o.player or "-"))
    print("------------------------------")
  end

  print("")
  local orderId = ask("Type an Order ID to inspect (blank to cancel)", true)
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

local function assignTracking()
  if not ensureLogin() then return end

  showHeader()
  local orderId = ask("Order ID", false)

  local status = chooseStatus()
  if not status then
    clear()
    print("Invalid status.")
    pause()
    return
  end

  local note = ask("General note (optional)", true)
  local locker = ask("Locker (optional)", true)
  local lockerNote = ask("Locker note (optional)", true)
  local deliveryNote = ask("Delivery note (optional)", true)

  local response, err = request({
    action = "assign_tracking",
    orderId = orderId,
    status = status,
    staff = staffName,
    note = note,
    locker = locker,
    lockerNote = lockerNote,
    deliveryNote = deliveryNote
  })

  showHeader()
  if not response then
    print("Error: " .. err)
  elseif not response.ok then
    print("Error: " .. (response.message or "Unknown error"))
  else
    print("Tracking assigned/confirmed.")
    print("Tracking: " .. (response.order.trackingId or "None"))
    print("Status: " .. (response.order.status or "-"))
  end
  pause()
end

local function updateStatus()
  if not ensureLogin() then return end

  showHeader()
  local orderId = ask("Order ID", false)

  local status = chooseStatus()
  if not status then
    clear()
    print("Invalid status.")
    pause()
    return
  end

  local locker = ask("Locker (optional, blank clears/keeps depending use)", true)
  local note = ask("General note (optional)", true)
  local lockerNote = ask("Locker note (optional)", true)
  local deliveryNote = ask("Delivery note (optional)", true)

  local response, err = request({
    action = "update_status",
    orderId = orderId,
    status = status,
    staff = staffName,
    locker = locker,
    note = note,
    lockerNote = lockerNote,
    deliveryNote = deliveryNote
  })

  showHeader()
  if not response then
    print("Error: " .. err)
  elseif not response.ok then
    print("Error: " .. (response.message or "Unknown error"))
  else
    print("Status updated.")
    print("Order: " .. response.order.orderId)
    print("Status: " .. response.order.status)
    print("Tracking: " .. (response.order.trackingId or "Not assigned yet"))
  end
  pause()
end

local function deleteOrder()
  if not ensureLogin() then return end

  showHeader()
  print("== Delete Order ==")
  print("WARNING: This permanently deletes the order.")
  print("")

  local orderId = ask("Order ID", false)
  local confirm = ask("Type DELETE to confirm", false)

  if confirm ~= "DELETE" then
    print("")
    print("Delete cancelled.")
    pause()
    return
  end

  local response, err = request({
    action = "delete_order",
    orderId = orderId,
    staff = staffName
  })

  showHeader()
  if not response then
    print("Error: " .. err)
  elseif not response.ok then
    print("Error: " .. (response.message or "Unknown error"))
  else
    print("Order deleted: " .. orderId)
  end
  pause()
end

local function searchByOrder()
  if not ensureLogin() then return end

  showHeader()
  local orderId = ask("Order ID", false)

  local response, err = request({
    action = "get_order",
    orderId = orderId
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

local function searchByTracking()
  if not ensureLogin() then return end

  showHeader()
  local trackingId = ask("Tracking code", false)

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
  print("1. Login / Change Staff Name")
  print("2. List Orders")
  print("3. Assign Tracking")
  print("4. Update Status")
  print("5. Delete Order")
  print("6. Search by Order ID")
  print("7. Search by Tracking Code")
  print("8. Ping Server")
  print("9. Exit")
  print("")

  local choice = ask("Choose", false)

  if choice == "1" then
    login()
  elseif choice == "2" then
    listOrders()
  elseif choice == "3" then
    assignTracking()
  elseif choice == "4" then
    updateStatus()
  elseif choice == "5" then
    deleteOrder()
  elseif choice == "6" then
    searchByOrder()
  elseif choice == "7" then
    searchByTracking()
  elseif choice == "8" then
    pingServer()
  elseif choice == "9" then
    clear()
    print("Goodbye.")
    break
  end
end
