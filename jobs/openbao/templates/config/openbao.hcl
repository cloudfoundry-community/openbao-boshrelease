<%
  require 'digest'

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

  # The persisted raft voter list names this node by node_id. spec.id changes
  # whenever create-env recreates the VM, so it can only be a default; pin
  # openbao.raft.node_id to survive VM recreation.
  node_id = p('openbao.raft.node_id', '')
  node_id = spec.id if node_id.empty?

  # Accept a real boolean or its string form, and fail the render on anything
  # else, so a quoted "false" in an ops file cannot silently render as true.
  standby_reads_setting = p('openbao.disable_standby_reads')
  disable_standby_reads =
    case standby_reads_setting.to_s
    when 'true'  then true
    when 'false' then false
    else
      raise ArgumentError,
        "openbao.disable_standby_reads must be true or false, got #{standby_reads_setting.inspect}"
    end

  # Seal configuration. Everything here comes from properties, so create-env
  # and director renders produce the same stanza. Failures mirror the static
  # wrapper's own checks so they surface at deploy time, not at unseal time.
  seal_type = p('openbao.seal.type', 'static').to_s
  unless %w[static shamir].include?(seal_type)
    raise ArgumentError,
      "openbao.seal.type must be static or shamir, got #{p('openbao.seal.type', 'static').inspect}"
  end

  seal_current_key     = p('openbao.seal.static.current_key', '').to_s
  seal_current_key_id  = p('openbao.seal.static.current_key_id', '').to_s
  seal_previous_key    = p('openbao.seal.static.previous_key', '').to_s
  seal_previous_key_id = p('openbao.seal.static.previous_key_id', '').to_s
  seal_disabled_raw    = p('openbao.seal.static.disabled', false)
  seal_disabled =
    case seal_disabled_raw.to_s
    when 'true'  then true
    when 'false' then false
    else
      raise ArgumentError,
        "openbao.seal.static.disabled must be true or false, got #{seal_disabled_raw.inspect}"
    end

  # Returns the decoded 32 key bytes of a 64-character hex key or a
  # 44-character standard base64 key, and raises for anything else.
  decode_seal_key = lambda do |name, key|
    if key.match?(/\A\h{64}\z/)
      [key].pack('H*')
    elsif key.length == 44 && key.match?(/\A[A-Za-z0-9+\/]{43}=\z/)
      bytes = begin
        key.unpack1('m0')
      rescue ArgumentError
        nil
      end
      if bytes.nil? || bytes.bytesize != 32
        raise ArgumentError, "#{name} is not valid base64 for a 32-byte key"
      end
      bytes
    else
      raise ArgumentError,
        "#{name} must be 64 hex characters or 44 base64 characters that decode to 32 bytes " \
        "(raw 32-byte keys are not accepted)"
    end
  end

  if seal_type == 'shamir'
    set_values = []
    set_values << 'current_key'        unless seal_current_key.empty?
    set_values << 'current_key_id'     unless seal_current_key_id.empty?
    set_values << 'previous_key'       unless seal_previous_key.empty?
    set_values << 'previous_key_id'    unless seal_previous_key_id.empty?
    set_values << 'disabled'           if seal_disabled
    unless set_values.empty?
      raise ArgumentError,
        "openbao.seal.type is shamir but openbao.seal.static.#{set_values.join(', ')} " \
        "is set; remove the static seal values, or set openbao.seal.type: static"
    end
  else
    if seal_current_key.empty?
      raise ArgumentError,
        "openbao.seal.type is static but openbao.seal.static.current_key is empty. " \
        "Set openbao.seal.static.current_key, or set openbao.seal.type: shamir to keep " \
        "manual Shamir unsealing. Adding a key to an already initialized Shamir cluster " \
        "starts a seal migration; see 'Upgrading to 0.4.0' in the README."
    end

    current_bytes = decode_seal_key.call('openbao.seal.static.current_key', seal_current_key)
    if seal_current_key_id.empty?
      seal_current_key_id = 'sha256-' + Digest::SHA256.hexdigest(current_bytes)[0, 16]
    end

    if seal_previous_key.empty? != seal_previous_key_id.empty?
      raise ArgumentError,
        "openbao.seal.static.previous_key and openbao.seal.static.previous_key_id " \
        "must be set together"
    end

    unless seal_previous_key.empty?
      previous_bytes = decode_seal_key.call('openbao.seal.static.previous_key', seal_previous_key)
      if previous_bytes == current_bytes && seal_previous_key_id != seal_current_key_id
        raise ArgumentError,
          "the previous and current static seal keys are the same key under different ids"
      end
      if previous_bytes != current_bytes && seal_previous_key_id == seal_current_key_id
        raise ArgumentError,
          "the previous and current static seal keys are different keys under the same id"
      end
    end
  end
-%>

#disable_mlock = 1

ui = <%= p('openbao.ui') %>
api_addr     = "<%= scheme %>://<%= spec.ip %>:<%= p('openbao.port') %>"
cluster_addr = "https://<%= spec.ip %>:8201"

default_lease_ttl = "<%= p('openbao.default_lease_ttl') %>"
max_lease_ttl     = "<%= p('openbao.max_lease_ttl') %>"

disable_standby_reads = <%= disable_standby_reads %>

listener "tcp" {
  address         = "0.0.0.0:<%= p('openbao.port') %>"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/var/vcap/jobs/openbao/tls/vault/cert.pem"
  tls_key_file    = "/var/vcap/jobs/openbao/tls/vault/key.pem"
  tls_min_version = "tls12"
}

storage "raft" {
  path    = "/var/vcap/store/openbao/raft"
  node_id = "<%= node_id %>"

<% cluster_ips.each do |ip| -%>
<% next if ip == spec.address -%>
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

<% if seal_type == 'static' -%>
seal "static" {
  current_key_id = "<%= seal_current_key_id %>"
  current_key    = "file:///var/vcap/jobs/openbao/seal/current.key"
<% unless seal_previous_key.empty? -%>
  previous_key_id = "<%= seal_previous_key_id %>"
  previous_key    = "file:///var/vcap/jobs/openbao/seal/previous.key"
<% end -%>
<% if seal_disabled -%>
  disabled = "true"
<% end -%>
}
<% end -%>
