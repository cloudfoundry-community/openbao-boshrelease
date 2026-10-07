#!/usr/bin/env ruby
# frozen_string_literal: true

# Rendering coverage for jobs/openbao/templates/config/openbao.hcl.
#
# The Raft retry_join stanza connects to peers over TLS. Peers present the
# kit-generated peer certificate, whose SAN is "openbao_raft_peer" -- never the
# per-instance BOSH-DNS name or IP used as leader_api_addr. Without a
# leader_tls_servername that matches that SAN, verification fails
# ("x509: certificate is valid for ..., not <addr>") and the cluster never
# forms. This renders the ERB with representative link/property data and asserts
# every retry_join block pins leader_tls_servername to the configured SAN.
#
# No BOSH toolchain required: link(), p(), and spec are mocked to mirror what
# the director injects at render time.

require 'erb'
require 'json'

TEMPLATE = File.expand_path(
  '../../jobs/openbao/templates/config/openbao.hcl', __dir__
)

# --- minimal BOSH template render context -----------------------------------

Instance = Struct.new(:address)

class LinkStub
  def initialize(addresses)
    @instances = addresses.map { |a| Instance.new(a) }
  end
  attr_reader :instances
end

class SpecStub
  attr_reader :ip, :id, :address
  def initialize(ip:, id:, address: ip)
    @ip = ip
    @id = id
    @address = address
  end
end

class RenderContext
  def initialize(properties:, links:, spec:)
    @properties = properties
    @links = links
    @spec = spec
  end

  def spec
    @spec
  end

  def link(name)
    @links.fetch(name)
  end

  # Mirrors BOSH's p(): p('key') requires the property; p('key', default)
  # falls back. Nested keys are dotted.
  def p(name, *default)
    if @properties.key?(name)
      @properties[name]
    elsif !default.empty?
      default.first
    else
      raise "no such property: #{name}"
    end
  end

  def render(path)
    ERB.new(File.read(path), trim_mode: '-').result(binding)
  end
end

# bosh create-env renders with a context that has no link() helper at all;
# calling it raises NoMethodError. Mirror that by undefining link.
class NoLinkContext < RenderContext
  undef_method :link
end

# --- fixture: a 3-node cluster with DNS-style peer addresses -----------------

def render_with(properties)
  ctx = RenderContext.new(
    properties: properties,
    links: {
      'openbao' => LinkStub.new(
        [
          'q1.openbao.net.deployment.bosh',
          'q2.openbao.net.deployment.bosh',
          'q3.openbao.net.deployment.bosh'
        ]
      )
    },
    spec: SpecStub.new(ip: 'q1.openbao.net.deployment.bosh', id: 'node-1')
  )
  ctx.render(TEMPLATE)
end

def render_create_env(properties)
  ctx = NoLinkContext.new(
    properties: properties,
    links: {},
    spec: SpecStub.new(ip: '10.0.0.4', id: '69cf047a-d6a6-445d-6151-855a9d66cfc1')
  )
  ctx.render(TEMPLATE)
end

BASE_PROPS = {
  'openbao.ui' => true,
  'openbao.port' => 443,
  'openbao.default_lease_ttl' => '768h',
  'openbao.max_lease_ttl' => '768h',
  'openbao.disable_standby_reads' => true,
  'openbao.peer.tls.use_self_signed_certs' => false,
  'openbao.peer.tls.servername' => 'openbao_raft_peer',
  'openbao.seal.type' => 'shamir'
}.freeze

# --- assertions --------------------------------------------------------------

failures = []
$checks_run = 0
def check(failures, desc)
  $checks_run += 1
  ok = yield
  puts(ok ? "ok - #{desc}" : "not ok - #{desc}")
  failures << desc unless ok
end

out = render_with(BASE_PROPS)

# The fixture has 3 instances; the local node (spec.ip) is skipped, so two
# retry_join blocks render, each needing exactly one servername line.
retry_join_count = out.scan(/retry_join\s*\{/).length
servername_count = out.scan(/leader_tls_servername\s*=/).length

check(failures, 'renders one retry_join per remote peer (2 of 3)') do
  retry_join_count == 2
end

check(failures, 'every retry_join block sets leader_tls_servername') do
  servername_count == retry_join_count && servername_count == 2
end

check(failures, 'leader_tls_servername matches the configured peer SAN') do
  out.include?('leader_tls_servername   = "openbao_raft_peer"')
end

# The property must be honoured so existing blocs can pin their deployed SAN
# (e.g. the legacy "openbao.bosh") without rotating the peer certificate.
legacy = render_with(BASE_PROPS.merge('openbao.peer.tls.servername' => 'openbao.bosh'))
check(failures, 'servername is driven by the property (legacy override)') do
  legacy.include?('leader_tls_servername   = "openbao.bosh"') &&
    !legacy.include?('"openbao_raft_peer"')
end

# --- create-env rendering (no link support) ----------------------------------
#
# bosh create-env has no link resolver: link() does not exist in its render
# context. A colocated single-node openbao (BOSH director kit) is deployed
# exactly that way and has no peers to join, so the template must degrade to
# an empty peer list instead of failing the whole create-env.

create_env_out =
  begin
    render_create_env(BASE_PROPS)
  rescue StandardError, NameError => e
    e
  end

check(failures, 'renders under create-env (no link() in context)') do
  create_env_out.is_a?(String)
end

check(failures, 'create-env render has no retry_join stanzas') do
  create_env_out.is_a?(String) && !create_env_out.include?('retry_join')
end

# --- raft node_id stability ---------------------------------------------------
#
# node_id defaults to the BOSH instance id, but a create-env VM recreate
# assigns a NEW instance id: the persisted raft voter list still names only
# the old id, so the node unseals yet can never win an election again. The
# openbao.raft.node_id property lets such deployments pin a stable id.

check(failures, 'node_id defaults to the BOSH instance id') do
  out.include?('node_id = "node-1"')
end

pinned = render_with(BASE_PROPS.merge('openbao.raft.node_id' => 'mgmt-director-openbao'))
check(failures, 'node_id is pinned by openbao.raft.node_id when set') do
  pinned.include?('node_id = "mgmt-director-openbao"') &&
    !pinned.include?('node_id = "node-1"')
end

# --- standby reads --------------------------------------------------------------
#
# Read-enabled standbys answer reads from a Raft copy that lags the active
# node, so a read-merge-write client (safe, Genesis) drops keys. The release
# forwards standby reads unless the operator opts back in.

check(failures, 'disable_standby_reads renders true when the property is true') do
  out.match?(/^disable_standby_reads = true$/)
end

reads_on = render_with(BASE_PROPS.merge('openbao.disable_standby_reads' => false))
check(failures, 'disable_standby_reads is driven by the property') do
  reads_on.match?(/^disable_standby_reads = false$/)
end

# --- static seal -------------------------------------------------------------
#
# The release defaults to a static seal and fails closed without a key. Keys
# below are obviously fake: the byte 0x0a repeated 32 times.

HEX_KEY = ('0a' * 32).freeze
B64_KEY = (["\x0a".b * 32].pack('m0')).freeze
OTHER_HEX_KEY = ('0b' * 32).freeze
DERIVED_ID = 'sha256-b9b07dd4e7718454' # first 16 hex of sha256 of the 32 key bytes

def static_props(extra = {})
  BASE_PROPS.merge('openbao.seal.type' => 'static').merge(extra)
end

# Returns the rendered string, or the raised error.
def try_render(props, create_env: false)
  create_env ? render_create_env(props) : render_with(props)
rescue StandardError => e
  e
end

def fails_with?(result, pattern)
  result.is_a?(StandardError) && result.message.match?(pattern)
end

check(failures, 'static seal with no key fails and names openbao.seal.type: shamir') do
  fails_with?(try_render(static_props), /openbao\.seal\.type: shamir/)
end

check(failures, 'shamir renders no seal block') do
  !out.include?('seal "')
end

check(failures, 'unknown seal type fails') do
  fails_with?(try_render(BASE_PROPS.merge('openbao.seal.type' => 'transit')), /must be static or shamir/)
end

hex_out = try_render(static_props('openbao.seal.static.current_key' => HEX_KEY))
check(failures, 'static with a hex key renders a seal "static" block at the job-dir file') do
  hex_out.is_a?(String) && hex_out.include?('seal "static" {') &&
    hex_out.include?('current_key    = "file:///var/vcap/jobs/openbao/seal/current.key"')
end

check(failures, 'derived id matches the fixed test vector') do
  hex_out.is_a?(String) && hex_out.include?(%(current_key_id = "#{DERIVED_ID}"))
end

check(failures, 'key material never appears in the config') do
  hex_out.is_a?(String) && !hex_out.include?(HEX_KEY)
end

b64_out = try_render(static_props('openbao.seal.static.current_key' => B64_KEY))
check(failures, 'base64 and hex keys for the same bytes derive the same id') do
  b64_out.is_a?(String) && b64_out.include?(%(current_key_id = "#{DERIVED_ID}"))
end

{
  'raw 32-byte key' => 'k' * 32,
  'wrong-length key' => '0a' * 31,
  'non-hex 64-character key' => 'zz' * 32
}.each do |label, key|
  check(failures, "#{label} fails the render") do
    fails_with?(try_render(static_props('openbao.seal.static.current_key' => key)), /64 hex characters or 44 base64/)
  end
end

{ 'trailing newline' => "#{HEX_KEY}\n", 'leading space' => " #{HEX_KEY}" }.each do |label, bad|
  check(failures, "current_key with a #{label} fails the render") do
    fails_with?(try_render(static_props('openbao.seal.static.current_key' => bad)), /64 hex characters or 44 base64/)
  end
  check(failures, "previous_key with a #{label} fails the render") do
    fails_with?(try_render(static_props('openbao.seal.static.current_key' => HEX_KEY,
                                        'openbao.seal.static.previous_key' => bad,
                                        'openbao.seal.static.previous_key_id' => 'fake-prev')),
                /64 hex characters or 44 base64/)
  end
end

%w[current_key_id previous_key_id].each do |prop|
  ["a\"b", "a\nb"].each do |bad|
    check(failures, "#{prop} #{bad.inspect} fails the render") do
      fails_with?(try_render(static_props('openbao.seal.static.current_key' => HEX_KEY,
                                          'openbao.seal.static.previous_key' => OTHER_HEX_KEY,
                                          'openbao.seal.static.current_key_id' => 'fake-cur',
                                          'openbao.seal.static.previous_key_id' => 'fake-prev',
                                          "openbao.seal.static.#{prop}" => bad)),
                  /openbao\.seal\.static\.#{prop}/)
    end
  end
end

%w[current_key previous_key].each do |prop|
  check(failures, "non-string #{prop} fails the render") do
    fails_with?(try_render(static_props('openbao.seal.static.current_key' => HEX_KEY,
                                        'openbao.seal.static.previous_key_id' => 'fake-prev',
                                        "openbao.seal.static.#{prop}" => 1234)),
                /must be a string.*quote/)
  end
end

explicit = try_render(static_props('openbao.seal.static.current_key' => HEX_KEY,
                                   'openbao.seal.static.current_key_id' => 'fake-id-1'))
check(failures, 'explicit id overrides the derived id') do
  explicit.is_a?(String) && explicit.include?('current_key_id = "fake-id-1"') &&
    !explicit.include?('sha256-')
end

rotation = try_render(static_props('openbao.seal.static.current_key' => HEX_KEY,
                                   'openbao.seal.static.previous_key' => OTHER_HEX_KEY,
                                   'openbao.seal.static.previous_key_id' => 'fake-prev'))
check(failures, 'previous key and id render the previous stanza lines') do
  rotation.is_a?(String) && rotation.include?('previous_key_id = "fake-prev"') &&
    rotation.include?('previous_key    = "file:///var/vcap/jobs/openbao/seal/previous.key"')
end

check(failures, 'previous key without previous id fails') do
  fails_with?(try_render(static_props('openbao.seal.static.current_key' => HEX_KEY,
                                      'openbao.seal.static.previous_key' => OTHER_HEX_KEY)), /together/)
end

check(failures, 'same material under different ids fails') do
  fails_with?(try_render(static_props('openbao.seal.static.current_key' => HEX_KEY,
                                      'openbao.seal.static.current_key_id' => 'id-a',
                                      'openbao.seal.static.previous_key' => B64_KEY,
                                      'openbao.seal.static.previous_key_id' => 'id-b')),
              /same key under different ids/)
end

check(failures, 'different material under the same id fails') do
  fails_with?(try_render(static_props('openbao.seal.static.current_key' => HEX_KEY,
                                      'openbao.seal.static.current_key_id' => 'id-a',
                                      'openbao.seal.static.previous_key' => OTHER_HEX_KEY,
                                      'openbao.seal.static.previous_key_id' => 'id-a')),
              /different keys under the same id/)
end

disabled = try_render(static_props('openbao.seal.static.current_key' => HEX_KEY,
                                   'openbao.seal.static.disabled' => true))
check(failures, 'disabled renders disabled = "true"') do
  disabled.is_a?(String) && disabled.include?('disabled = "true"')
end

check(failures, 'disabled with type shamir fails') do
  fails_with?(try_render(BASE_PROPS.merge('openbao.seal.static.disabled' => true)), /openbao\.seal\.type is shamir/)
end

check(failures, 'a static key with type shamir fails') do
  fails_with?(try_render(BASE_PROPS.merge('openbao.seal.static.current_key' => HEX_KEY)), /openbao\.seal\.type is shamir/)
end

ce_static = try_render(static_props('openbao.seal.static.current_key' => HEX_KEY), create_env: true)
check(failures, 'create-env (no link) still renders the static stanza and no retry_join') do
  ce_static.is_a?(String) && ce_static.include?('seal "static" {') && !ce_static.include?('retry_join')
end

# The key templates are plain ERB that render the key text and nothing else.
def render_key_template(name, properties)
  path = File.expand_path("../../jobs/openbao/templates/seal/#{name}.key", __dir__)
  RenderContext.new(properties: properties, links: {}, spec: SpecStub.new(ip: '10.0.0.4', id: 'x')).render(path)
end

check(failures, 'current.key renders exactly the key text') do
  render_key_template('current', 'openbao.seal.static.current_key' => HEX_KEY) == HEX_KEY
end

check(failures, 'valid current.key renders exactly 64 bytes with no newline') do
  k = render_key_template('current', 'openbao.seal.static.current_key' => HEX_KEY)
  k.bytesize == 64 && !k.include?("\n")
end

check(failures, 'previous.key renders exactly the key text') do
  render_key_template('previous', 'openbao.seal.static.previous_key' => OTHER_HEX_KEY) == OTHER_HEX_KEY
end

check(failures, 'key templates render empty when no key is set') do
  render_key_template('current', {}).empty? && render_key_template('previous', {}).empty?
end

bpm = File.read(File.expand_path('../../jobs/openbao/templates/config/bpm.yml', __dir__))
check(failures, 'bpm.yml sets no BAO_STATIC_SEAL variables') do
  !bpm.include?('BAO_STATIC_SEAL')
end

if failures.empty?
  puts "\nAll #{$checks_run} checks passed."
  exit 0
else
  warn "\nFAILED (#{failures.length}): #{failures.join('; ')}"
  exit 1
end
