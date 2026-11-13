package saba_core
import http3 "../../http/v3"
import "core:time"

// Opt into Server.timeouts for native per-stream phases. CONNECT acceptance
// and closing are explicit; accepted tunnels have no request lifetime cap.
Http3_Phase_Config :: struct {enabled:bool,connect_accept,connect_close:time.Duration}

@(private)
http3_phases_valid :: proc(config:Http3_Phase_Config)->bool {
 if !config.enabled {return true}
 return config.connect_accept>0 && config.connect_accept<=MAX_SERVER_TIMEOUT &&
  config.connect_close>0 && config.connect_close<=MAX_SERVER_TIMEOUT
}

@(private)
http3_phase_policy :: proc(config:Http3_Phase_Config,timeouts:Resolved_Timeouts)->http3.Request_Phase_Policy {
 if !config.enabled {return {}}
 return {enabled=true,header=timeouts.header,body=timeouts.body,
  large_body=timeouts.large_body,large_body_threshold=REQUEST_BODY_LIMIT,
  response=timeouts.response,connect_accept=config.connect_accept,
  connect_close=config.connect_close}
}
