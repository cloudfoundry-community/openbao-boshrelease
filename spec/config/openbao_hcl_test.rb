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
  attr_reader :ip, :id
  def initialize(ip:, id:)
    @ip = ip
    @id = id
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
  'openbao.peer.tls.use_self_signed_certs' => false,
  'openbao.peer.tls.servername' => 'openbao_raft_peer'
}.freeze

# --- assertions --------------------------------------------------------------

failures = []
def check(failures, desc)
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

if failures.empty?
  puts "\nAll 6 checks passed."
  exit 0
else
  warn "\nFAILED (#{failures.length}): #{failures.join('; ')}"
  exit 1
end
