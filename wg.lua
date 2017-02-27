--
-- Wireshark dissector for the WireGuard tunnel protocol
-- Copyright (C) 2017 Peter Wu <peter@lekensteyn.nl>
--
-- This work is licensed under the terms of GPLv2 (or any later version).
--

local proto_wg = Proto.new("wg", "WireGuard")
local type_names = {
    [1] = "Handshake Initiation",
    [2] = "Handshake Response",
    [3] = "Cookie Reply",
    [4] = "Transport Data",
}
local F = {
    type        = ProtoField.uint8("wg.type", "Type", base.DEC, type_names),
    reserved    = ProtoField.none("wg.reserved", "Reserved"),
    sender      = ProtoField.uint32("wg.sender", "Sender", base.HEX),
    ephemeral   = ProtoField.bytes("wg.ephemeral", "Ephemeral"),
    static_data = ProtoField.bytes("wg.static_data", "Static"),
    -- TODO split timestamp
    timestamp_data = ProtoField.bytes("wg.timestamp_data", "Timestamp"),
    mac1        = ProtoField.bytes("wg.mac1", "mac1"),
    mac2        = ProtoField.bytes("wg.mac2", "mac2"),
    receiver    = ProtoField.uint32("wg.receiver", "Receiver", base.HEX),
    nonce       = ProtoField.bytes("wg.nonce", "Nonce"),
    cookie      = ProtoField.bytes("wg.cookie", "Cookie"),
    counter     = ProtoField.uint64("wg.counter", "Counter"),
}
local function add_aead_field(F, name, label)
    F[name] = ProtoField.none("wg." .. name, label .. " (encrypted)")
    -- The "empty" field does not have data, do not bother adding fields for it.
    if name ~= "empty" then
        F[name .. "_ciphertext"] = ProtoField.bytes("wg." .. name .. ".ciphertext", "Ciphertext")
    end
    F[name .. "_atag"] = ProtoField.bytes("wg." .. name .. ".auth_tag", "Auth Tag")
end
add_aead_field(F, "static", "Static")
add_aead_field(F, "timestamp", "Timestamp")
add_aead_field(F, "empty", "Empty")
add_aead_field(F, "packet", "Packet")
proto_wg.fields = F

-- See function load_keys below for the file format.
proto_wg.prefs.keylog_file = Pref.string("Keylog file", "",
    "Path to keylog file as generated by key-extract.py")
proto_wg.prefs.dissect_packet = Pref.bool("Dissect transport data", true,
    "Disable to prevent the IP dissector from dissecting decrypted transport data")

local efs = {}
efs.error               = ProtoExpert.new("wg.expert.error", "Dissection Error",
    expert.group.MALFORMED, expert.severity.ERROR)
efs.bad_packet_length   = ProtoExpert.new("wg.expert.bad_packet_length", "Packet length is too small!",
    expert.group.MALFORMED, expert.severity.ERROR)
efs.decryption_error    = ProtoExpert.new("wg.expert.decryption_error", "Decryption error",
    expert.group.DECRYPTION, expert.severity.NOTE)
proto_wg.experts = efs

local ip_dissector = Dissector.get("ip")

-- Length of AEAD authentication tag
local AUTH_TAG_LENGTH = 16

-- Convenience function for consuming part of the buffer and remembering the
-- offset for the next time.
function next_tvb(tvb)
    local offset = 0
    return setmetatable({
        -- Returns the current offset.
        offset = function()
            return offset
        end,
        -- Returns the TVB with the requested length without advancing offset
        peek = function(self, len)
            local t = tvb(offset, len)
            self.tvb = t
            return t
        end,
    }, {
        -- Returns the TVB with the requested length
        __call = function(self, len)
            local t = tvb(offset, len)
            offset = offset + len
            self.tvb = t
            return t
        end,
    })
end

-- Gets the bytes within a TvbRange
local function tvb_bytes(tvbrange)
    return tvbrange:raw(tvbrange:offset(), tvbrange:len())
end

--
-- Decryption helpers (glue)
--
local function base64_decode(text)
    return ByteArray.new(text, true):base64_decode():raw()
end
local gcrypt
do
    local ok, res = pcall(require, "luagcrypt")
    if ok then
        if res.CIPHER_MODE_POLY1305 then
            gcrypt = res
        else
            report_failure("wg.lua: Libgcrypt 1.7 or newer is required for decryption")
        end
    else
        report_failure("wg.lua: cannot load Luagcrypt, decryption is unavailable.\n" .. res)
    end
end

--
-- Decryption helpers (independent of Wireshark)
--
KEY_STATIC      = "STAT"
KEY_TIMESTAMP   = "TIME"
KEY_EMPTY       = "EMPT"
KEY_TRAFFIC     = "DATA"

-- Update "keylog" with keys read from "filename".
-- On error, the error message is returned.
local function load_keys(keylog, filename)
    local f, err = io.open(filename)
    if not f then
        -- Opening the keylog file failed, return the error
        return "Cannot load keylog file: " .. err
    end

    -- Populate subtables.
    for k, v in ipairs({KEY_STATIC, KEY_TIMESTAMP, KEY_EMPTY, KEY_TRAFFIC}) do
        if not keylog[v] then keylog[v] = {} end
    end

    -- Read lines of the format:
    -- "<type> <sender-id> <base64-key> <base64-aad>" for handshake secrets or
    -- "<receiver-id> <base64-key>" for traffic secrets where:
    --
    -- <type> is one of the key types ("STAT", "TIME", "EMPTY"),
    -- <sender-id> and <receiver-id> are 32-bit IDs (e.g. 0x12345678),
    -- <base64-key> is the base64-encoded symmetric key (32 bytes),
    -- <base64-aad> is the base64-encoded additional data (32 bytes).
    -- Unrecognized lines (empty lines and lines starting with "#") are ignored.
    while true do
        local line = f:read()
        if not line then break end  -- break on EOF

        -- First try to find traffic secrets, else try handshake secrets.
        local what = KEY_TRAFFIC, aad
        local peer_id, key = string.match(line, "^(0x%x+) ([%w/+=]+)$")
        if not key then
            what, peer_id, key, aad =
                string.match(line, "^(%u+) (0x%x+) ([%w/+=]+) ([%w/+=]+)$")
        end
        if what and keylog[what] then
            peer_id = tonumber(peer_id)
            key = base64_decode(key)
            if aad then aad = base64_decode(aad) end
            keylog[what][peer_id] = {key, aad}
        end
    end
    f:close()
end

-- Try to load a key for the given sender, returning the key and additional
-- authenticated data (possibly nil if there are none) or two nils followed by
-- an error message (if an IO error occured).
local function load_key(keylog, filename, key_type, peer_id)
    local keylog_sub = keylog[key_type]
    if not keylog_sub then
        keylog_sub = {}
        keylog[key_type] = keylog_sub
    end
    if not keylog_sub[peer_id] then
        -- Key ID is not yet known, try to load from file.
        local err = load_keys(keylog, filename)
        if err then
            return nil, nil, err
        end
    end
    local result = keylog_sub[peer_id]
    if result then return table.unpack(result) end
end

local function decrypt_aead_gcrypt(key, counter, encrypted, aad)
    local cipher = gcrypt.Cipher(gcrypt.CIPHER_CHACHA20, gcrypt.CIPHER_MODE_POLY1305)
    cipher:setkey(key)
    local nonce
    if counter == 0 then
        nonce = string.rep("\0", 12)
    else
        -- UInt64 type was passed in
        nonce = Struct.pack("<I4E", 0, counter)
    end
    cipher:setiv(nonce)
    if aad then cipher:authenticate(aad) end
    local plain = cipher:decrypt(encrypted)
    return plain, cipher:gettag()
end
local function decrypt_aead(key, counter, encrypted, tag, aad)
    local ok, plain, calctag = pcall(decrypt_aead_gcrypt, key, counter, encrypted, aad)
    if ok then
        -- Return result and signal error if authentication failed.
        local auth_err = calctag ~= tag and "Authentication tag mismatch"
        return plain, auth_err
    else
        -- Return error
        return nil, "Decryption failed: " .. plain
    end
end
--
-- End decryption helpers.
--

-- Remember previously read keys
local keylog_cache = {}

-- Dissect and try to decrypt, returning the tree and decrypted TVB
local function dissect_aead(t, tree, datalen, fieldname, counter, key_type, peer_id)
    -- Builds a tree:
    -- * Foo (Encrypted)
    --   * Ciphertext
    --   * Auth Tag
    local subtree = tree:add(F[fieldname], t:peek(datalen + AUTH_TAG_LENGTH))
    local encr_tvb, atag_tvb, decr_tvb
    if datalen > 0 then
        subtree:add(F[fieldname .. "_ciphertext"], t(datalen))
        encr_tvb = t.tvb
    end
    subtree:add(F[fieldname .. "_atag"], t(AUTH_TAG_LENGTH))
    atag_tvb = t.tvb

    -- Try to decrypt and authenticate if possible.
    if gcrypt then
        local key, err, keylog_file
        keylog_file = proto_wg.prefs.keylog_file
        while keylog_file and keylog_file ~= "" do
            -- Try to load key
            key, aad, err = load_key(keylog_cache, keylog_file, key_type, peer_id)
            if not key then
                err = err or "Cannot find key in keylog file"
                break
            end

            -- Decrypt and authenticate the buffer
            local encr_data = encr_tvb and tvb_bytes(encr_tvb) or ""
            local decrypted
            decrypted, err = decrypt_aead(key, counter, encr_data, tvb_bytes(atag_tvb), aad)
            -- Skip further processing if authentication tag failed
            if not decrypted or err then break end

            -- Decryption success, add the decrypted contents and return tvb
            if decrypted ~= "" then
                decr_tvb = ByteArray.new(decrypted, true)
                    :tvb("Decrypted " .. fieldname)
            end
            break
        end
        -- If any decryption error occurred, show it.
        if err then
            subtree:add_proto_expert_info(efs.decryption_error, err)
        end
    end
    return subtree, decr_tvb
end

function dissect_initiator(tvb, pinfo, tree)
    local t = next_tvb(tvb)
    local subtree, subtvb
    tree:add(F.type,        t(1))
    tree:add(F.reserved,    t(3))
    tree:add_le(F.sender,   t(4))
    local sender_id = t.tvb:le_uint()
    pinfo.cols.info:append(string.format(", sender=0x%08X", sender_id))
    tree:add(F.ephemeral,   t(32))
    subtree, subtvb = dissect_aead(t, tree, 32, "static", 0, KEY_STATIC, sender_id)
    if subtvb then
        tree:add(F.static_data, subtvb())
    end
    subtree, subtvb = dissect_aead(t, tree, 12, "timestamp", 0, KEY_TIMESTAMP, sender_id)
    if subtvb then
        tree:add(F.timestamp_data, subtvb())
    end
    tree:add(F.mac1,        t(16))
    tree:add(F.mac2,        t(16))
    return t:offset()
end

function dissect_responder(tvb, pinfo, tree)
    local t = next_tvb(tvb)
    local subtree, subtvb
    tree:add(F.type,        t(1))
    tree:add(F.reserved,    t(3))
    tree:add_le(F.sender,   t(4))
    local sender_id = t.tvb:le_uint()
    pinfo.cols.info:append(string.format(", sender=0x%08X", sender_id))
    tree:add_le(F.receiver, t(4))
    pinfo.cols.info:append(string.format(", receiver=0x%08X", t.tvb:le_uint()))
    tree:add(F.ephemeral,   t(32))
    dissect_aead(t, tree, 0, "empty", 0, KEY_EMPTY, sender_id)
    tree:add(F.mac1,        t(16))
    tree:add(F.mac2,        t(16))
    return t:offset()
end

function dissect_cookie(tvb, pinfo, tree)
    local t = next_tvb(tvb)
    tree:add(F.type,        t(1))
    tree:add(F.reserved,    t(3))
    tree:add_le(F.receiver, t(4))
    pinfo.cols.info:append(string.format(", receiver=0x%08X", t.tvb:le_uint()))
    tree:add(F.nonce,       t(24))
    -- TODO handle cookie (need to update key-probe.sh/key-extract.sh too)
    dissect_aead(t, tree, 16, "cookie")
    return t:offset()
end

function dissect_data(tvb, pinfo, tree)
    local t = next_tvb(tvb)
    local subtree, subtvb
    tree:add(F.type,        t(1))
    tree:add(F.reserved,    t(3))
    tree:add_le(F.receiver, t(4))
    local receiver_id = t.tvb:le_uint()
    pinfo.cols.info:append(string.format(", receiver=0x%08X", receiver_id))
    tree:add_le(F.counter,  t(8))
    local counter = t.tvb:le_uint64()
    pinfo.cols.info:append(string.format(", counter=%s", counter))
    local packet_length = tvb:len() - t:offset()
    if packet_length < AUTH_TAG_LENGTH then
        -- Should not happen, it is a malformed packet.
        tree:add_tvb_expert_info(efs.bad_packet_length. t(packet_length))
        return t:offset()
    end
    local datalen = packet_length - AUTH_TAG_LENGTH
    if datalen > 0 then
        pinfo.cols.info:append(string.format(", datalen=%s", datalen))
    else
        pinfo.cols.info:append(", Keep-Alive")
    end
    subtree, subtvb = dissect_aead(t, tree, datalen, "packet", counter, KEY_TRAFFIC, receiver_id)
    return t:offset(), subtvb
end

local types = {
    [1] = dissect_initiator,
    [2] = dissect_responder,
    [3] = dissect_cookie,
    [4] = dissect_data,
}

function proto_wg.dissector(tvb, pinfo, tree)
    if tvb:len() < 4 then return 0 end
    local type_val = tvb(0,1):uint()
    -- "Reserved" must be zero at the moment
    if tvb(1,3):uint() ~= 0 then return 0 end

    local subdissector = types[type_val]
    if not subdissector then return 0 end

    pinfo.cols.protocol = "WireGuard"
    pinfo.cols.info = type_names[type_val]
    local subtree = tree:add(proto_wg, tvb())
    local success, ret, next_tvb = pcall(subdissector, tvb, pinfo, subtree)
    if success then
        if next_tvb and not proto_wg.prefs.dissect_packet then
            subtree:add("(IP packet not shown, preference \"Dissect transport data\" is disabled)")
        elseif next_tvb then
            local err
            success, err = pcall(ip_dissector, next_tvb, pinfo, tree)
            if not success then
                subtree:add_proto_expert_info(efs.error, err)
            end
        end
        return ret
    else
        -- An error has occurred... Do not propagate it since Wireshark would
        -- then try a different heuristics dissectors.
        subtree:add_proto_expert_info(efs.error, ret)
        return tvb:len()
    end
end

proto_wg:register_heuristic("udp", proto_wg.dissector)
