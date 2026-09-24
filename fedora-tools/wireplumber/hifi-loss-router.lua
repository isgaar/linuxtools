-- WirePlumber 0.5+ Native Dynamic Hi-Fi Lossless Engine Policy Hook
-- Ejecuta directamente dentro del hilo de eventos en C de WirePlumber
-- Procesa el enrutamiento para DisplayPort, HDMI, USB-C y Analógico

lutils = require ("linking-utils")
cutils = require ("common-utils")
log = Log.open_topic ("s-linking")

SimpleEventHook {
  name = "linking/hifi-loss-native-router",
  after = { "linking/find-defined-target",
            "linking/find-filter-target",
            "linking/find-media-role-target",
            "linking/find-default-target",
            "linking/find-best-target" },
  before = "linking/prepare-link",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-target" },
    },
  },
  execute = function (event)
    local source, om, si, si_props, si_flags, target =
        lutils:unwrap_select_target_event (event)

    local node_name = tostring (si_props ["node.name"])
    local direction = si_props ["item.node.direction"]

    -- Caso 1: Flujo de reproducción de cualquier aplicación (Zen, Spotify, etc.)
    -- Redirigir de manera transparente y forzosa hacia hifi_loss_sink
    if direction == "output" and node_name ~= "hifi_loss_playback" then
      for lnkbl in om:iterate { type = "SiLinkable" } do
        local target_props = lnkbl.properties
        if target_props ["node.name"] == "hifi_loss_sink" and
           target_props ["item.node.direction"] == "input" then
          event:set_data ("target", lnkbl)
          si_flags.can_passthrough = false
          log:info (si, "... [hifi-loss] App redirigida al filtro maestro: " .. node_name)
          return
        end
      end
    end

    -- Caso 2: Salida del filtro hifi-loss (hifi_loss_playback)
    -- Enlazar al mejor sink físico disponible (DP, USB-C, Analógico)
    if node_name == "hifi_loss_playback" and direction == "output" then
      local def_target = lutils.findDefaultLinkable (si)
      if def_target ~= nil then
        local def_props = def_target.properties
        if def_props ["node.name"] ~= "hifi_loss_sink" then
          event:set_data ("target", def_target)
          log:info (si, "... [hifi-loss] Salida vinculada al hardware: " .. tostring(def_props["node.name"]))
        end
      end
    end
  end
}:register ()
