package server

import core "core"

Server_Control :: core.Server_Control
Server_State :: core.Server_State
Connection_Capacity :: core.Connection_Capacity
Timeout_Config :: core.Timeout_Config
Keep_Alive_Config :: core.Keep_Alive_Config
Observability_Config :: core.Observability_Config
Request_Metrics :: core.Request_Metrics
Request_Event :: core.Request_Event
Request_Outcome :: core.Request_Outcome
Request :: core.Request
Response :: core.Response
Header :: core.Header
Path_Parameter :: core.Path_Parameter
HTTP_Status :: core.HTTP_Status
Upgrade :: core.Upgrade
Upgrade_IO :: core.Upgrade_IO
Connection_Task :: core.Connection_Task
Server_Runtime :: core.Server_Runtime
DEFAULT_MAX_CONNECTIONS :: core.DEFAULT_MAX_CONNECTIONS
DEFAULT_INITIAL_CONNECTIONS :: core.DEFAULT_INITIAL_CONNECTIONS
DEFAULT_WORKERS :: core.DEFAULT_WORKERS
REQUEST_HEADER_LIMIT :: core.REQUEST_HEADER_LIMIT
REQUEST_HEADER_COUNT_LIMIT :: core.REQUEST_HEADER_COUNT_LIMIT
REQUEST_BODY_LIMIT :: core.REQUEST_BODY_LIMIT
REQUEST_HEADER_TIMEOUT :: core.REQUEST_HEADER_TIMEOUT
REQUEST_BODY_TIMEOUT :: core.REQUEST_BODY_TIMEOUT
RESPONSE_SEND_TIMEOUT :: core.RESPONSE_SEND_TIMEOUT
RESPONSE_HEADER_LIMIT :: core.RESPONSE_HEADER_LIMIT
MAX_SERVER_TIMEOUT :: core.MAX_SERVER_TIMEOUT
MAX_EVENT_ROUTE_BYTES :: core.MAX_EVENT_ROUTE_BYTES
DEFAULT_KEEP_ALIVE_REQUESTS :: core.DEFAULT_KEEP_ALIVE_REQUESTS
MAX_KEEP_ALIVE_REQUESTS :: core.MAX_KEEP_ALIVE_REQUESTS
DEFAULT_DRAIN_TIMEOUT :: core.DEFAULT_DRAIN_TIMEOUT
MAX_DRAIN_TIMEOUT :: core.MAX_DRAIN_TIMEOUT
MAX_PATH_PARAMETERS :: core.MAX_PATH_PARAMETERS
CRLF :: core.CRLF
HTTP_HEADERS_END :: core.HTTP_HEADERS_END
HTTP_VERSION :: core.HTTP_VERSION
stop_server :: core.stop_server
server_endpoint :: core.server_endpoint
server_capacity :: core.server_capacity
server_metrics :: core.server_metrics
server_state :: core.server_state
server_ready :: core.server_ready
drain_server :: core.drain_server
timeouts_valid :: core.timeouts_valid
keep_alive_valid :: core.keep_alive_valid
deadline_expired :: core.deadline_expired
wait_ready :: core.wait_ready
parse_request :: core.parse_request
read_json :: core.read_json
header_value :: core.header_value
make_response :: core.make_response
response_headers :: core.response_headers
not_found :: core.not_found
match_route :: core.match_route
path_value :: core.path_value
status_text :: core.status_text

Request_Context :: core.Request_Context
Request_Status :: core.Request_Status
retain_request_context :: core.retain_request_context
release_request_context :: core.release_request_context
request_deadline :: core.request_deadline
request_context_status :: core.request_context_status
request_cancelled :: core.request_cancelled
discard_response :: core.discard_response

Response_Stream :: core.Response_Stream
Stream_IO :: core.Stream_IO
Stream_Step :: core.Stream_Step
stream_submit :: core.stream_submit
stream_wait :: core.stream_wait
streaming_response :: core.streaming_response

Deferred_Response :: core.Deferred_Response
Deferred_IO :: core.Deferred_IO
Deferred_Step :: core.Deferred_Step

Resource_Config :: core.Resource_Config
server_resources :: core.server_resources
retain_server_resources :: core.retain_server_resources
request_resources :: core.request_resources

Stream_Backing :: core.Stream_Backing

stream_submit_backing :: core.stream_submit_backing
DEFAULT_OPERATION_RESOURCES :: core.DEFAULT_OPERATION_RESOURCES
DEFAULT_CONNECTION_RESOURCES :: core.DEFAULT_CONNECTION_RESOURCES
DEFAULT_SERVER_RESOURCES :: core.DEFAULT_SERVER_RESOURCES

request_connection_resources :: core.request_connection_resources
