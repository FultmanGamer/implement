-- Parcelo secure server

local MODEM_SIDE = "back"
local HOST_PROTOCOL = "parcelo_host"
local HOSTNAME = "parcelo_server"
local API_PROTOCOL = "parcelo_api"
local DATA_FILE = "parcelo_db.txt"
local STAFF_PIN = "4284"

local HOLD_MS = 60 * 60 * 1000 -- 1 real hour
local MAX_ITEM_NAME = 64
local MAX_PLAYER_NAME = 32
local MAX_ADDRESS = 128
local MAX_NOTE = 160
local MAX_LOCKER = 32

local ALLOWED_STATUSES = {
  ["Order Received"] = true,
  ["Packaging"] = true,
  ["Sorted at Warehouse"] = true,
  ["Ready for Dispatch"] = true,
  ["In Transit"] = true,
  ["Arrived at Hub"] = true,
  ["Out for Delivery"] = true,
  ["Awaiting Pickup"] = true,
  ["Delivered"] = true,
  ["Final Pickup Day"] = true,
  ["Return to Sender"] = true,
  ["Returned"] = true
}

math.randomseed(os.epoch("utc"))

local db = {
  nextOrderId = 1001,
  nextTrackingId = 5001,
  orders = {}
}

local function nowMs()
  return os.epoch("utc")
end

local function trim(s)
  if s == nil then return "" end
  return tostring(s):match("^%s*(.-)%s*$")
end

local function clampText(s, maxLen)
  s = trim(s)
  if #s > maxLen then
    s = s:sub(1, maxLen)
  end
  return s
end

local function normalizeName(s)
  return trim(s):lower()
end

local function deepCopy(tbl)
  return textutils.unserialise(textutils.serialise(tbl))
end

local function safeSave()
  local f = fs.open(DATA_FILE, "w")
  if not f then
    return false
  end
  f.write(textutils.serialise(db))
  f.close()
  return true
end

local function loadDb()
  if fs.exists(DATA_FILE) then
    local f = fs.open(DATA_FILE, "r")
    if not f then return end
    local raw = f.readAll()
    f.close()

    local loaded = textutils.unserialise(raw)
    if type(loaded) == "table" and type(loaded.orders) == "table" then
      db = loaded
    end
  else
    safeSave()
  end
end

local function makeOrderId()
  local id = string.format("ORD-%04d", db.nextOrderId)
  db.nextOrderId = db.nextOrderId + 1
  return id
end

local function makeTrackingId()
  local id = string.format("PCL-%04d", db.nextTrackingId)
  db.nextTrackingId = db.nextTrackingId + 1
  return id
end

local function addHistory(order, status, by, note)
  order.history = order.history or {}
  table.insert(order.history, 1, {
    time = nowMs(),
    status = status,
    by = by or "system",
    note = note or ""
  })
  while #order.history > 20 do
    table.remove(order.history)
  end
end

local function getOrderById(orderId)
  return db.orders[trim(orderId)]
end

local function getOrderByTracking(trackingId)
  trackingId = trim(trackingId)
  for _, order in pairs(db.orders) do
    if order.trackingId == trackingId then
      return order
    end
  end
  return nil
end

local function getOrdersForPlayer(playerName)
  local out = {}
  local wanted = normalizeName(playerName)

  for _, order in pairs(db.orders) do
    if normalizeName(order.player) == wanted then
      table.insert(out, deepCopy(order))
    end
  end

  table.sort(out, function(a, b)
    return (a.createdAt or 0) > (b.createdAt or 0)
  end)

  return out
end

local function getAllOrders()
  local out = {}
  for _, order in pairs(db.orders) do
    table.insert(out, deepCopy(order))
  end

  table.sort(out, function(a, b)
    return (a.createdAt or 0) > (b.createdAt or 0)
  end)

  return out
end

local function requireStaffPin(msg)
  return trim(msg.staffPin) == STAFF_PIN
end

local function setStatus(order, status, by, note, locker, lockerNote, deliveryNote)
  if status and status ~= "" and ALLOWED_STATUSES[status] then
    order.status = status
  end

  order.updatedAt = nowMs()
  order.updatedBy = by or "system"

  if locker ~= nil then
    locker = clampText(locker, MAX_LOCKER)
    if locker == "" then
      order.locker = nil
    else
      order.locker = locker
    end
  end

  if note ~= nil then
    order.note = clampText(note, MAX_NOTE)
  end

  if lockerNote ~= nil then
    order.lockerNote = clampText(lockerNote, MAX_NOTE)
  end

  if deliveryNote ~= nil then
    order.deliveryNote = clampText(deliveryNote, MAX_NOTE)
  end

  if order.status == "Awaiting Pickup" then
    order.pickupExpiresAt = nowMs() + HOLD_MS
  elseif order.status == "Delivered" or order.status == "Returned" then
    order.pickupExpiresAt = nil
  end

  addHistory(order, order.status, by, note)
end

local function createOrder(player, itemName, amount, deliveryType, address)
  local orderId = makeOrderId()

  local order = {
    orderId = orderId,
    trackingId = nil,
    player = clampText(player, MAX_PLAYER_NAME),
    itemName = clampText(itemName, MAX_ITEM_NAME),
    amount = math.max(1, math.min(9999, tonumber(amount) or 1)),
    deliveryType = clampText(deliveryType, 16),
    address = clampText(address, MAX_ADDRESS),
    status = "Order Received",
    locker = nil,
    note = "",
    lockerNote = "",
    deliveryNote = "",
    pickupExpiresAt = nil,
    createdAt = nowMs(),
    updatedAt = nowMs(),
    updatedBy = clampText(player, MAX_PLAYER_NAME),
    history = {}
  }

  if order.deliveryType == "" then
    order.deliveryType = "locker"
  end

  addHistory(order, "Order Received", order.player, "Order created")
  db.orders[orderId] = order
  safeSave()

  return deepCopy(order)
end

local function sendResponse(targetId, payload)
  rednet.send(targetId, payload, API_PROTOCOL)
end

local function ok(targetId, extra)
  extra = extra or {}
  extra.ok = true
  sendResponse(targetId, extra)
end

local function fail(targetId, message)
  sendResponse(targetId, {
    ok = false,
    message = message or "Unknown error"
  })
end

local function handlePlaceOrder(sender, msg)
  local player = clampText(msg.player, MAX_PLAYER_NAME)
  local itemName = clampText(msg.itemName, MAX_ITEM_NAME)

  if player == "" then
    fail(sender, "Player name is required")
    return
  end

  if itemName == "" then
    fail(sender, "Item name is required")
    return
  end

  local order = createOrder(
    player,
    itemName,
    msg.amount,
    msg.deliveryType,
    msg.address
  )

  ok(sender, {
    message = "Order placed",
    order = order
  })
end

local function handleGetMyOrders(sender, msg)
  local player = clampText(msg.player, MAX_PLAYER_NAME)
  if player == "" then
    fail(sender, "Player name is required")
    return
  end

  ok(sender, {
    orders = getOrdersForPlayer(player)
  })
end

local function handleGetAllOrders(sender, msg)
  if not requireStaffPin(msg) then
    fail(sender, "Unauthorized")
    return
  end

  ok(sender, {
    orders = getAllOrders()
  })
end

local function handleGetOrder(sender, msg)
  local order = getOrderById(msg.orderId)
  if not order then
    fail(sender, "Order not found")
    return
  end

  ok(sender, {
    order = deepCopy(order)
  })
end

local function handleGetByTracking(sender, msg)
  local trackingId = trim(msg.trackingId)
  if trackingId == "" then
    fail(sender, "Tracking code is required")
    return
  end

  local order = getOrderByTracking(trackingId)
  if not order then
    fail(sender, "Tracking code not found")
    return
  end

  ok(sender, {
    order = deepCopy(order)
  })
end

local function handleAssignTracking(sender, msg)
  if not requireStaffPin(msg) then
    fail(sender, "Unauthorized")
    return
  end

  local order = getOrderById(msg.orderId)
  if not order then
    fail(sender, "Order not found")
    return
  end

  if not order.trackingId then
    order.trackingId = makeTrackingId()
  end

  local status = trim(msg.status)
  if status == "" or not ALLOWED_STATUSES[status] then
    status = "Packaging"
  end

  setStatus(
    order,
    status,
    clampText(msg.staff, MAX_PLAYER_NAME),
    msg.note,
    msg.locker,
    msg.lockerNote,
    msg.deliveryNote
  )

  safeSave()

  ok(sender, {
    message = "Tracking assigned",
    order = deepCopy(order)
  })
end

local function handleUpdateStatus(sender, msg)
  if not requireStaffPin(msg) then
    fail(sender, "Unauthorized")
    return
  end

  local order = getOrderById(msg.orderId)
  if not order then
    fail(sender, "Order not found")
    return
  end

  local status = trim(msg.status)
  if status == "" or not ALLOWED_STATUSES[status] then
    fail(sender, "Invalid status")
    return
  end

  setStatus(
    order,
    status,
    clampText(msg.staff, MAX_PLAYER_NAME),
    msg.note,
    msg.locker,
    msg.lockerNote,
    msg.deliveryNote
  )

  safeSave()

  ok(sender, {
    message = "Status updated",
    order = deepCopy(order)
  })
end

local function handleDeleteOrder(sender, msg)
  if not requireStaffPin(msg) then
    fail(sender, "Unauthorized")
    return
  end

  local orderId = trim(msg.orderId)
  if orderId == "" then
    fail(sender, "Order ID is required")
    return
  end

  local order = getOrderById(orderId)
  if not order then
    fail(sender, "Order not found")
    return
  end

  db.orders[orderId] = nil
  safeSave()

  ok(sender, {
    message = "Order deleted",
    orderId = orderId
  })
end

local function handlePing(sender)
  ok(sender, { message = "Parcelo server online" })
end

local function handleRequest(sender, msg)
  if type(msg) ~= "table" then
    fail(sender, "Invalid request")
    return
  end

  local action = trim(msg.action)

  if action == "ping" then
    handlePing(sender)
  elseif action == "place_order" then
    handlePlaceOrder(sender, msg)
  elseif action == "get_my_orders" then
    handleGetMyOrders(sender, msg)
  elseif action == "get_all_orders" then
    handleGetAllOrders(sender, msg)
  elseif action == "get_order" then
    handleGetOrder(sender, msg)
  elseif action == "get_by_tracking" then
    handleGetByTracking(sender, msg)
  elseif action == "assign_tracking" then
    handleAssignTracking(sender, msg)
  elseif action == "update_status" then
    handleUpdateStatus(sender, msg)
  elseif action == "delete_order" then
    handleDeleteOrder(sender, msg)
  else
    fail(sender, "Unknown action")
  end
end

loadDb()

if not rednet.isOpen(MODEM_SIDE) then
  rednet.open(MODEM_SIDE)
end

pcall(function()
  rednet.unhost(HOST_PROTOCOL)
end)
rednet.host(HOST_PROTOCOL, HOSTNAME)

term.clear()
term.setCursorPos(1, 1)
print("Parcelo server online")
print("Hostname: " .. HOSTNAME)
print("Orders loaded: " .. tostring(#getAllOrders()))
print("")
print("Waiting for requests...")

while true do
  local senderId, msg = rednet.receive(API_PROTOCOL)
  local okRun, err = pcall(function()
    handleRequest(senderId, msg)
  end)

  if not okRun then
    print("Server error: " .. tostring(err))
  end
end
