<%
  cluster_ips = link('openbao').instances.map { |i| i.address }
  scheme = 'https'
-%>

#disable_mlock = 1

ui = <%= p('openbao.ui') %>
api_addr     = "<%= scheme %>://<%= spec.ip %>:<%= p('openbao.port') %>"
cluster_addr = "https://<%= spec.ip %>:8201"

default_lease_ttl = "<%= p('openbao.default_lease_ttl') %>"
max_lease_ttl     = "<%= p('openbao.max_lease_ttl') %>"

listener "tcp" {
  address         = "0.0.0.0:<%= p('openbao.port') %>"
  tls_cert_file   = "/var/vcap/jobs/openbao/tls/vault/cert.pem"
  tls_key_file    = "/var/vcap/jobs/openbao/tls/vault/key.pem"
  tls_min_version = "tls12"
}

storage "raft" {
  path    = "/var/vcap/store/openbao/raft"
  node_id = "<%= spec.id %>"

<% cluster_ips.each do |ip| -%>
<% next if ip == spec.ip -%>
  retry_join {
    leader_api_addr         = "<%= scheme %>://<%= ip %>:<%= p('openbao.port') %>"
    leader_ca_cert_file     = "/var/vcap/jobs/openbao/tls/peer/ca.pem"
<% unless p('openbao.peer.tls.use_self_signed_certs') -%>
    leader_client_cert_file = "/var/vcap/jobs/openbao/tls/peer/cert.pem"
    leader_client_key_file  = "/var/vcap/jobs/openbao/tls/peer/key.pem"
<% end -%>
  }
<% end -%>
}
