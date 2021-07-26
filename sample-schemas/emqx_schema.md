## Structs
- [cluster](#cluster)
- [node](#node)
- [rpc](#rpc)
- [log](#log)
- [lager](#lager)
- [acl](#acl)
- [mqtt](#mqtt)
- [zone](#zone)
- [listener](#listener)
- [module](#module)
- [broker](#broker)
- [plugins](#plugins)
- [sysmon](#sysmon)
- [os_mon](#os_mon)
- [vm_mon](#vm_mon)
- [alarm](#alarm)
- [telemetry](#telemetry)

### cluster
name|type|default
----|----|----
name|<code>atom()</code>|emqxcl
discovery|<code>atom()</code>|manual
autoclean|<code>emqx_schema:duration()</code>|
autoheal|<code>emqx_schema:flag()</code>|false
static|<code>[static](#static)</code>|
mcast|<code>[mcast](#mcast)</code>|
proto_dist|<code>inet_tls &#124; inet6_tcp &#124; inet_tcp</code>|inet_tcp
dns|<code>[dns](#dns)</code>|
etcd|<code>[etcd](#etcd)</code>|
k8s|<code>[k8s](#k8s)</code>|
### node
name|type|default
----|----|----
name|<code>string()</code>|"emqx@127.0.0.1"
ssl_dist_optfile|<code>string()</code>|
cookie|<code>string()</code>|"emqxsecretcookie"
data_dir|<code>string()</code>|
heartbeat|<code>emqx_schema:flag()</code>|false
async_threads|<code>1..1024</code>|
process_limit|<code>integer()</code>|
max_ports|<code>1024..134217727</code>|
dist_buffer_size|<code>emqx_schema:bytesize()</code>|
global_gc_interval|<code>emqx_schema:duration_s()</code>|
fullsweep_after|<code>non_neg_integer()</code>|1000
max_ets_tables|<code>emqx_schema:duration()</code>|256000
crash_dump|<code>emqx_schema:file()</code>|
dist_net_ticktime|<code>integer()</code>|
dist_listen_min|<code>integer()</code>|
dist_listen_max|<code>integer()</code>|
backtrace_depth|<code>integer()</code>|16
### rpc
name|type|default
----|----|----
mode|<code>sync &#124; async</code>|async
async_batch_size|<code>integer()</code>|256
port_discovery|<code>manual &#124; stateless</code>|stateless
tcp_server_port|<code>integer()</code>|5369
tcp_client_num|<code>0..255</code>|0
connect_timeout|<code>emqx_schema:duration()</code>|"5s"
send_timeout|<code>emqx_schema:duration()</code>|"5s"
authentication_timeout|<code>emqx_schema:duration()</code>|"5s"
call_receive_timeout|<code>emqx_schema:duration()</code>|"15s"
socket_keepalive_idle|<code>emqx_schema:duration_s()</code>|"7200s"
socket_keepalive_interval|<code>emqx_schema:duration_s()</code>|"75s"
socket_keepalive_count|<code>integer()</code>|9
socket_sndbuf|<code>emqx_schema:bytesize()</code>|"1MB"
socket_recbuf|<code>emqx_schema:bytesize()</code>|"1MB"
socket_buffer|<code>emqx_schema:bytesize()</code>|"1MB"
### log
name|type|default
----|----|----
to|<code>both &#124; console &#124; file</code>|file
level|<code>emqx_schema:log_level()</code>|warning
time_offset|<code>string()</code>|"system"
primary_log_level|<code>emqx_schema:log_level()</code>|warning
dir|<code>string()</code>|"log"
file|<code>emqx_schema:file()</code>|"emqx.log"
chars_limit|<code>integer()</code>|-1
supervisor_reports|<code>progress &#124; error</code>|error
max_depth|<code>integer() &#124; infinity</code>|20
formatter|<code>json &#124; text</code>|text
single_line|<code>boolean()</code>|true
rotation|<code>[rotation](#rotation)</code>|
size|<code>emqx_schema:bytesize() &#124; infinity</code>|infinity
sync_mode_qlen|<code>integer()</code>|100
drop_mode_qlen|<code>integer()</code>|3000
flush_qlen|<code>integer()</code>|8000
overload_kill|<code>emqx_schema:flag()</code>|true
overload_kill_mem_size|<code>emqx_schema:bytesize()</code>|"30MB"
overload_kill_qlen|<code>integer()</code>|20000
overload_kill_restart_after|<code>emqx_schema:duration() &#124; infinity</code>|"5s"
burst_limit|<code>emqx_schema:comma_separated_list()</code>|"disabled"
error_logger|<code>atom()</code>|silent
debug|<code>[additional_log_file](#additional_log_file)</code>|
info|<code>[additional_log_file](#additional_log_file)</code>|
notice|<code>[additional_log_file](#additional_log_file)</code>|
warning|<code>[additional_log_file](#additional_log_file)</code>|
error|<code>[additional_log_file](#additional_log_file)</code>|
critical|<code>[additional_log_file](#additional_log_file)</code>|
alert|<code>[additional_log_file](#additional_log_file)</code>|
emergency|<code>[additional_log_file](#additional_log_file)</code>|
### lager
name|type|default
----|----|----
handlers|<code>string()</code>|[]
crash_log|<code>emqx_schema:flag()</code>|false
### acl
name|type|default
----|----|----
allow_anonymous|<code>boolean()</code>|false
acl_nomatch|<code>allow &#124; deny</code>|deny
acl_file|<code>string()</code>|
enable_acl_cache|<code>emqx_schema:flag()</code>|true
acl_cache_ttl|<code>emqx_schema:duration()</code>|"1m"
acl_cache_max_size|<code>1..inf</code>|32
acl_deny_action|<code>ignore &#124; disconnect</code>|ignore
flapping_detect_policy|<code>emqx_schema:comma_separated_list()</code>|"30,1m,5m"
### mqtt
name|type|default
----|----|----
max_packet_size|<code>emqx_schema:bytesize()</code>|"1MB"
max_clientid_len|<code>integer()</code>|65535
max_topic_levels|<code>integer()</code>|0
max_qos_allowed|<code>0..2</code>|2
max_topic_alias|<code>integer()</code>|65535
retain_available|<code>boolean()</code>|true
wildcard_subscription|<code>boolean()</code>|true
shared_subscription|<code>boolean()</code>|true
ignore_loop_deliver|<code>boolean()</code>|true
strict_mode|<code>boolean()</code>|false
response_information|<code>string()</code>|
### zone
name|type|default
----|----|----
$name|<code>[zone_settings](#zone_settings)</code>|
### listener
name|type|default
----|----|----
tcp|<code>[tcp_listener](#tcp_listener)</code>|
ssl|<code>[ssl_listener](#ssl_listener)</code>|
ws|<code>[ws_listener](#ws_listener)</code>|
wss|<code>[wss_listener](#wss_listener)</code>|
### module
name|type|default
----|----|----
loaded_file|<code>string()</code>|
presence|<code>[presence](#presence)</code>|
subscription|<code>[subscription](#subscription)</code>|
rewrite|<code>[rewrite](#rewrite)</code>|
### broker
name|type|default
----|----|----
sys_interval|<code>emqx_schema:duration()</code>|"1m"
sys_heartbeat|<code>emqx_schema:duration()</code>|"30s"
enable_session_registry|<code>emqx_schema:flag()</code>|true
session_locking_strategy|<code>all &#124; quorum &#124; leader &#124; local</code>|quorum
shared_subscription_strategy|<code>random &#124; round_robin</code>|round_robin
shared_dispatch_ack_enabled|<code>boolean()</code>|false
route_batch_clean|<code>emqx_schema:flag()</code>|true
perf|<code>[perf](#perf)</code>|
### plugins
name|type|default
----|----|----
etc_dir|<code>string()</code>|
loaded_file|<code>string()</code>|
expand_plugins_dir|<code>string()</code>|
### sysmon
name|type|default
----|----|----
long_gc|<code>emqx_schema:duration()</code>|0
long_schedule|<code>emqx_schema:duration()</code>|240
large_heap|<code>emqx_schema:bytesize()</code>|"8MB"
busy_dist_port|<code>boolean()</code>|true
busy_port|<code>boolean()</code>|false
### os_mon
name|type|default
----|----|----
cpu_check_interval|<code>emqx_schema:duration_s()</code>|60
cpu_high_watermark|<code>emqx_schema:percent()</code>|"80%"
cpu_low_watermark|<code>emqx_schema:percent()</code>|"60%"
mem_check_interval|<code>emqx_schema:duration_s()</code>|60
sysmem_high_watermark|<code>emqx_schema:percent()</code>|"70%"
procmem_high_watermark|<code>emqx_schema:percent()</code>|"5%"
### vm_mon
name|type|default
----|----|----
check_interval|<code>emqx_schema:duration_s()</code>|30
process_high_watermark|<code>emqx_schema:percent()</code>|"80%"
process_low_watermark|<code>emqx_schema:percent()</code>|"60%"
### alarm
name|type|default
----|----|----
actions|<code>emqx_schema:comma_separated_list()</code>|"log,publish"
size_limit|<code>integer()</code>|1000
validity_period|<code>emqx_schema:duration_s()</code>|"24h"
### telemetry
name|type|default
----|----|----
enabled|<code>boolean()</code>|false
url|<code>string()</code>|"https://telemetry-emqx-io.bigpar.vercel.app/api/telemetry"
report_interval|<code>emqx_schema:duration_s()</code>|"7d"
### k8s
name|type|default
----|----|----
apiserver|<code>string()</code>|
service_name|<code>string()</code>|
address_type|<code>hostname &#124; dns &#124; ip</code>|
app_name|<code>string()</code>|
namespace|<code>string()</code>|
suffix|<code>string()</code>|[]
### etcd_ssl
name|type|default
----|----|----
enable|<code>emqx_schema:flag()</code>|
cacertfile|<code>string()</code>|
certfile|<code>string()</code>|
keyfile|<code>string()</code>|
verify|<code>verify_peer &#124; verify_none</code>|
fail_if_no_peer_cert|<code>boolean()</code>|
secure_renegotiate|<code>emqx_schema:flag()</code>|
reuse_sessions|<code>emqx_schema:flag()</code>|
honor_cipher_order|<code>emqx_schema:flag()</code>|
handshake_timeout|<code>emqx_schema:duration()</code>|
depth|<code>integer()</code>|
password|<code>string()</code>|
dhfile|<code>string()</code>|
server_name_indication|<code>disable &#124; string()</code>|
tls_versions|<code>emqx_schema:comma_separated_list()</code>|
ciphers|<code>emqx_schema:comma_separated_list()</code>|
psk_ciphers|<code>emqx_schema:comma_separated_list()</code>|
### etcd
name|type|default
----|----|----
server|<code>emqx_schema:comma_separated_list()</code>|
prefix|<code>string()</code>|
node_ttl|<code>emqx_schema:duration()</code>|"1m"
ssl|<code>[etcd_ssl](#etcd_ssl)</code>|
### dns
name|type|default
----|----|----
app|<code>string()</code>|
name|<code>string()</code>|
### mcast
name|type|default
----|----|----
addr|<code>string()</code>|"239.192.0.1"
ports|<code>emqx_schema:comma_separated_list()</code>|"4369"
iface|<code>string()</code>|"0.0.0.0"
ttl|<code>integer()</code>|255
loop|<code>emqx_schema:flag()</code>|true
sndbuf|<code>emqx_schema:bytesize()</code>|"16KB"
recbuf|<code>emqx_schema:bytesize()</code>|"16KB"
buffer|<code>emqx_schema:bytesize()</code>|"32KB"
### static
name|type|default
----|----|----
seeds|<code>emqx_schema:comma_separated_list()</code>|
### additional_log_file
name|type|default
----|----|----
file|<code>string()</code>|
### rotation
name|type|default
----|----|----
enable|<code>emqx_schema:flag()</code>|true
size|<code>emqx_schema:bytesize()</code>|"10MB"
count|<code>integer()</code>|5
### quota
name|type|default
----|----|----
conn_messages_routing|<code>emqx_schema:comma_separated_list()</code>|
overall_messages_routing|<code>emqx_schema:comma_separated_list()</code>|
### conn_congestion
name|type|default
----|----|----
alarm|<code>emqx_schema:flag()</code>|false
min_alarm_sustain_duration|<code>emqx_schema:duration()</code>|"1m"
### rate_limit
name|type|default
----|----|----
conn_messages_in|<code>emqx_schema:comma_separated_list()</code>|
conn_bytes_in|<code>emqx_schema:comma_separated_list()</code>|
### zone_settings
name|type|default
----|----|----
idle_timeout|<code>emqx_schema:duration()</code>|"15s"
allow_anonymous|<code>boolean()</code>|
acl_nomatch|<code>allow &#124; deny</code>|
enable_acl|<code>emqx_schema:flag()</code>|false
acl_deny_action|<code>ignore &#124; disconnect</code>|ignore
enable_ban|<code>emqx_schema:flag()</code>|false
enable_stats|<code>emqx_schema:flag()</code>|false
max_packet_size|<code>emqx_schema:bytesize()</code>|
max_clientid_len|<code>integer()</code>|
max_topic_levels|<code>integer()</code>|
max_qos_allowed|<code>0..2</code>|
max_topic_alias|<code>integer()</code>|
retain_available|<code>boolean()</code>|
wildcard_subscription|<code>boolean()</code>|
shared_subscription|<code>boolean()</code>|
server_keepalive|<code>integer()</code>|
keepalive_backoff|<code>float()</code>|0.75
max_subscriptions|<code>integer()</code>|0
upgrade_qos|<code>emqx_schema:flag()</code>|false
max_inflight|<code>0..65535</code>|
retry_interval|<code>emqx_schema:duration_s()</code>|"30s"
max_awaiting_rel|<code>emqx_schema:duration()</code>|0
await_rel_timeout|<code>emqx_schema:duration_s()</code>|"300s"
ignore_loop_deliver|<code>boolean()</code>|
session_expiry_interval|<code>emqx_schema:duration_s()</code>|"2h"
max_mqueue_len|<code>integer()</code>|1000
mqueue_priorities|<code>emqx_schema:comma_separated_list()</code>|"none"
mqueue_default_priority|<code>highest &#124; lowest</code>|lowest
mqueue_store_qos0|<code>boolean()</code>|true
enable_flapping_detect|<code>emqx_schema:flag()</code>|false
rate_limit|<code>[rate_limit](#rate_limit)</code>|
conn_congestion|<code>[conn_congestion](#conn_congestion)</code>|
quota|<code>[quota](#quota)</code>|
force_gc_policy|<code>emqx_schema:bar_separated_list()</code>|
force_shutdown_policy|<code>emqx_schema:bar_separated_list()</code>|"default"
mountpoint|<code>string()</code>|
use_username_as_clientid|<code>boolean()</code>|false
strict_mode|<code>boolean()</code>|false
response_information|<code>string()</code>|
bypass_auth_plugins|<code>boolean()</code>|false
### access
name|type|default
----|----|----
$id|<code>string()</code>|
### deflate_opts
name|type|default
----|----|----
level|<code>best_speed &#124; best_compression &#124; default &#124; none</code>|
mem_level|<code>1..9</code>|
strategy|<code>rle &#124; huffman_only &#124; filtered &#124; default</code>|
server_context_takeover|<code>takeover &#124; no_takeover</code>|
client_context_takeover|<code>takeover &#124; no_takeover</code>|
server_max_window_bits|<code>integer()</code>|
client_max_window_bits|<code>integer()</code>|
### wss_listener_settings
name|type|default
----|----|----
enable|<code>emqx_schema:flag()</code>|
cacertfile|<code>string()</code>|
certfile|<code>string()</code>|
keyfile|<code>string()</code>|
mqtt_path|<code>string()</code>|"/mqtt"
fail_if_no_subprotocol|<code>boolean()</code>|true
supported_subprotocols|<code>string()</code>|"mqtt, mqtt-v3, mqtt-v3.1.1, mqtt-v5"
proxy_address_header|<code>string()</code>|"x-forwarded-for"
proxy_port_header|<code>string()</code>|"x-forwarded-port"
compress|<code>boolean()</code>|
deflate_opts|<code>[deflate_opts](#deflate_opts)</code>|
idle_timeout|<code>emqx_schema:duration()</code>|
max_frame_size|<code>integer()</code>|
mqtt_piggyback|<code>single &#124; multiple</code>|multiple
check_origin_enable|<code>boolean()</code>|false
allow_origin_absence|<code>boolean()</code>|true
check_origins|<code>emqx_schema:comma_separated_list()</code>|
peer_cert_as_username|<code>cn</code>|
peer_cert_as_clientid|<code>cn</code>|
key_password|<code>string()</code>|
endpoint|<code>emqx_schema:ip_port() &#124; integer()</code>|
acceptors|<code>integer()</code>|8
max_connections|<code>integer()</code>|1024
max_conn_rate|<code>integer()</code>|
active_n|<code>integer()</code>|100
verify|<code>verify_peer &#124; verify_none</code>|
fail_if_no_peer_cert|<code>boolean()</code>|
secure_renegotiate|<code>emqx_schema:flag()</code>|
reuse_sessions|<code>emqx_schema:flag()</code>|true
honor_cipher_order|<code>emqx_schema:flag()</code>|
handshake_timeout|<code>emqx_schema:duration()</code>|
depth|<code>integer()</code>|10
password|<code>string()</code>|
dhfile|<code>string()</code>|
server_name_indication|<code>disable &#124; string()</code>|
tls_versions|<code>emqx_schema:comma_separated_list()</code>|
ciphers|<code>emqx_schema:comma_separated_list()</code>|
psk_ciphers|<code>emqx_schema:comma_separated_list()</code>|
endpoint|<code>emqx_schema:ip_port() &#124; integer()</code>|
acceptors|<code>integer()</code>|8
max_connections|<code>integer()</code>|1024
max_conn_rate|<code>integer()</code>|
active_n|<code>integer()</code>|100
zone|<code>string()</code>|
rate_limit|<code>emqx_schema:comma_separated_list()</code>|
access|<code>[access](#access)</code>|
proxy_protocol|<code>emqx_schema:flag()</code>|
proxy_protocol_timeout|<code>emqx_schema:duration()</code>|
backlog|<code>integer()</code>|1024
send_timeout|<code>emqx_schema:duration()</code>|"15s"
send_timeout_close|<code>emqx_schema:flag()</code>|true
recbuf|<code>emqx_schema:bytesize()</code>|
sndbuf|<code>emqx_schema:bytesize()</code>|
buffer|<code>emqx_schema:bytesize()</code>|
tune_buffer|<code>emqx_schema:flag()</code>|
nodelay|<code>boolean()</code>|
reuseaddr|<code>boolean()</code>|
zone|<code>string()</code>|
rate_limit|<code>emqx_schema:comma_separated_list()</code>|
access|<code>[access](#access)</code>|
proxy_protocol|<code>emqx_schema:flag()</code>|
proxy_protocol_timeout|<code>emqx_schema:duration()</code>|
backlog|<code>integer()</code>|1024
send_timeout|<code>emqx_schema:duration()</code>|"15s"
send_timeout_close|<code>emqx_schema:flag()</code>|true
recbuf|<code>emqx_schema:bytesize()</code>|
sndbuf|<code>emqx_schema:bytesize()</code>|
buffer|<code>emqx_schema:bytesize()</code>|
tune_buffer|<code>emqx_schema:flag()</code>|
nodelay|<code>boolean()</code>|
reuseaddr|<code>boolean()</code>|
### wss_listener
name|type|default
----|----|----
$name|<code>[wss_listener_settings](#wss_listener_settings)</code>|
### ws_listener_settings
name|type|default
----|----|----
mqtt_path|<code>string()</code>|"/mqtt"
fail_if_no_subprotocol|<code>boolean()</code>|true
supported_subprotocols|<code>string()</code>|"mqtt, mqtt-v3, mqtt-v3.1.1, mqtt-v5"
proxy_address_header|<code>string()</code>|"x-forwarded-for"
proxy_port_header|<code>string()</code>|"x-forwarded-port"
compress|<code>boolean()</code>|
deflate_opts|<code>[deflate_opts](#deflate_opts)</code>|
idle_timeout|<code>emqx_schema:duration()</code>|
max_frame_size|<code>integer()</code>|
mqtt_piggyback|<code>single &#124; multiple</code>|multiple
check_origin_enable|<code>boolean()</code>|false
allow_origin_absence|<code>boolean()</code>|true
check_origins|<code>emqx_schema:comma_separated_list()</code>|
peer_cert_as_username|<code>cn</code>|
peer_cert_as_clientid|<code>cn</code>|
key_password|<code>string()</code>|
endpoint|<code>emqx_schema:ip_port() &#124; integer()</code>|
acceptors|<code>integer()</code>|8
max_connections|<code>integer()</code>|1024
max_conn_rate|<code>integer()</code>|
active_n|<code>integer()</code>|100
zone|<code>string()</code>|
rate_limit|<code>emqx_schema:comma_separated_list()</code>|
access|<code>[access](#access)</code>|
proxy_protocol|<code>emqx_schema:flag()</code>|
proxy_protocol_timeout|<code>emqx_schema:duration()</code>|
backlog|<code>integer()</code>|1024
send_timeout|<code>emqx_schema:duration()</code>|"15s"
send_timeout_close|<code>emqx_schema:flag()</code>|true
recbuf|<code>emqx_schema:bytesize()</code>|
sndbuf|<code>emqx_schema:bytesize()</code>|
buffer|<code>emqx_schema:bytesize()</code>|
tune_buffer|<code>emqx_schema:flag()</code>|
nodelay|<code>boolean()</code>|
reuseaddr|<code>boolean()</code>|
### ws_listener
name|type|default
----|----|----
$name|<code>[ws_listener_settings](#ws_listener_settings)</code>|
### ssl_listener_settings
name|type|default
----|----|----
peer_cert_as_username|<code>md5 &#124; pem &#124; crt &#124; dn &#124; cn</code>|
peer_cert_as_clientid|<code>md5 &#124; pem &#124; crt &#124; dn &#124; cn</code>|
key_password|<code>string()</code>|
enable|<code>emqx_schema:flag()</code>|
cacertfile|<code>string()</code>|
certfile|<code>string()</code>|
keyfile|<code>string()</code>|
verify|<code>verify_peer &#124; verify_none</code>|
fail_if_no_peer_cert|<code>boolean()</code>|
secure_renegotiate|<code>emqx_schema:flag()</code>|
reuse_sessions|<code>emqx_schema:flag()</code>|true
honor_cipher_order|<code>emqx_schema:flag()</code>|
handshake_timeout|<code>emqx_schema:duration()</code>|"15s"
depth|<code>integer()</code>|10
password|<code>string()</code>|
dhfile|<code>string()</code>|
server_name_indication|<code>disable &#124; string()</code>|
tls_versions|<code>emqx_schema:comma_separated_list()</code>|
ciphers|<code>emqx_schema:comma_separated_list()</code>|
psk_ciphers|<code>emqx_schema:comma_separated_list()</code>|
endpoint|<code>emqx_schema:ip_port() &#124; integer()</code>|
acceptors|<code>integer()</code>|8
max_connections|<code>integer()</code>|1024
max_conn_rate|<code>integer()</code>|
active_n|<code>integer()</code>|100
zone|<code>string()</code>|
rate_limit|<code>emqx_schema:comma_separated_list()</code>|
access|<code>[access](#access)</code>|
proxy_protocol|<code>emqx_schema:flag()</code>|
proxy_protocol_timeout|<code>emqx_schema:duration()</code>|
backlog|<code>integer()</code>|1024
send_timeout|<code>emqx_schema:duration()</code>|"15s"
send_timeout_close|<code>emqx_schema:flag()</code>|true
recbuf|<code>emqx_schema:bytesize()</code>|
sndbuf|<code>emqx_schema:bytesize()</code>|
buffer|<code>emqx_schema:bytesize()</code>|
high_watermark|<code>emqx_schema:bytesize()</code>|"1MB"
tune_buffer|<code>emqx_schema:flag()</code>|
nodelay|<code>boolean()</code>|
reuseaddr|<code>boolean()</code>|
### ssl_listener
name|type|default
----|----|----
$name|<code>[ssl_listener_settings](#ssl_listener_settings)</code>|
### tcp_listener_settings
name|type|default
----|----|----
peer_cert_as_username|<code>cn</code>|
peer_cert_as_clientid|<code>cn</code>|
key_password|<code>string()</code>|
endpoint|<code>emqx_schema:ip_port() &#124; integer()</code>|
acceptors|<code>integer()</code>|8
max_connections|<code>integer()</code>|1024
max_conn_rate|<code>integer()</code>|
active_n|<code>integer()</code>|100
zone|<code>string()</code>|
rate_limit|<code>emqx_schema:comma_separated_list()</code>|
access|<code>[access](#access)</code>|
proxy_protocol|<code>emqx_schema:flag()</code>|
proxy_protocol_timeout|<code>emqx_schema:duration()</code>|
backlog|<code>integer()</code>|1024
send_timeout|<code>emqx_schema:duration()</code>|"15s"
send_timeout_close|<code>emqx_schema:flag()</code>|true
recbuf|<code>emqx_schema:bytesize()</code>|
sndbuf|<code>emqx_schema:bytesize()</code>|
buffer|<code>emqx_schema:bytesize()</code>|
high_watermark|<code>emqx_schema:bytesize()</code>|"1MB"
tune_buffer|<code>emqx_schema:flag()</code>|
nodelay|<code>boolean()</code>|
reuseaddr|<code>boolean()</code>|
### tcp_listener
name|type|default
----|----|----
$name|<code>[tcp_listener_settings](#tcp_listener_settings)</code>|
### rule
name|type|default
----|----|----
$id|<code>string()</code>|
### rewrite
name|type|default
----|----|----
rule|<code>[rule](#rule)</code>|
pub_rule|<code>[rule](#rule)</code>|
sub_rule|<code>[rule](#rule)</code>|
### subscription_settings
name|type|default
----|----|----
topic|<code>string()</code>|
qos|<code>0..2</code>|1
nl|<code>0..1</code>|0
rap|<code>0..1</code>|0
rh|<code>0..2</code>|0
### subscription
name|type|default
----|----|----
$id|<code>[subscription_settings](#subscription_settings)</code>|
### presence
name|type|default
----|----|----
qos|<code>0..2</code>|1
### perf
name|type|default
----|----|----
route_lock_type|<code>global &#124; tab &#124; key</code>|key
trie_compaction|<code>boolean()</code>|true
