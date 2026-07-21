<%
  # bosh create-env renders without link support (NoMethodError on `link`);
  # a colocated single-node openbao has no raft peers to join, so degrade to
  # an empty peer list there. Director-managed deployments still resolve the
  # link and get retry_join stanzas.
  cluster_ips =
    begin
      link('openbao').instances.map { |i| i.address }
    rescue NameError
      []
    end
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
    leader_tls_servername   = "<%= p('openbao.peer.tls.servername') %>"
<% unless p('openbao.peer.tls.use_self_signed_certs') -%>
    leader_client_cert_file = "/var/vcap/jobs/openbao/tls/peer/cert.pem"
    leader_client_key_file  = "/var/vcap/jobs/openbao/tls/peer/key.pem"
<% end -%>
  }
<% end -%>
}
