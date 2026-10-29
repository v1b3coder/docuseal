# frozen_string_literal: true

require 'rails_helper'

# S2: revokace se musí kontrolovat nad řetězem, který skutečně postavil
# OpenSSL store (včetně intermediate certů z trust bundle), ne jen nad certy,
# které poslal klient.
RSpec.describe 'QES chain revocation' do
  before { QesHelpers.configure! }

  def certificate(subject, issuer: nil, issuer_key: nil, key:, serial:, ca:)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = serial
    cert.subject = OpenSSL::X509::Name.parse(subject)
    cert.issuer = issuer ? issuer.subject : cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.current - 1.hour
    cert.not_after = Time.current + 1.day
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = cert
    factory.issuer_certificate = issuer || cert
    cert.add_extension(factory.create_extension('basicConstraints', ca ? 'CA:TRUE' : 'CA:FALSE', true))
    cert.sign(issuer_key || key, OpenSSL::Digest.new('SHA256'))
    cert
  end

  def crl(issuer, issuer_key, revoked_serial)
    result = OpenSSL::X509::CRL.new
    result.version = 1
    result.issuer = issuer.subject
    result.last_update = Time.current - 60
    result.next_update = Time.current + 1.hour
    entry = OpenSSL::X509::Revoked.new
    entry.serial = revoked_serial
    entry.time = Time.current - 60
    result.add_revoked(entry)
    result.sign(issuer_key, OpenSSL::Digest.new('SHA256'))
    result
  end

  let(:root_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:root) { certificate('/CN=Chain Root', key: root_key, serial: 1, ca: true) }
  let(:intermediate_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:intermediate) do
    certificate('/CN=Chain Intermediate', issuer: root, issuer_key: root_key,
                  key: intermediate_key, serial: 2, ca: true)
  end
  let(:leaf_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:leaf) do
    certificate('/CN=Chain Leaf', issuer: intermediate, issuer_key: intermediate_key,
                  key: leaf_key, serial: 3, ca: false)
  end
  let(:intermediate_crl) { crl(root, root_key, intermediate.serial) }

  it 'builds the chain from the trust store and checks the intermediate revocation' do
    allow(Qes).to receive(:trust_roots).and_return([root, intermediate])

    ok, chain = Qes::Validator.verified_chain(leaf, [], [root, intermediate])
    expect(ok).to be true
    expect(chain.map(&:subject).map(&:to_s)).to include(intermediate.subject.to_s)

    expect do
      Qes::Ltv.check_revoked!(leaf, chain: chain.drop(1), crls: [intermediate_crl])
    end.to raise_error(Qes::ClientError) { |error| expect(error.code).to eq(:revoked) }
  end

  it 'passes the verified chain to revocation checks during completion' do
    allow(Qes).to receive(:trust_roots).and_return([root, intermediate])
    allow(Qes::Ltv).to receive(:fetch_crls).and_return([intermediate_crl])
    allow(Qes::Ltv).to receive(:check_revoked!)

    session = build(:qes_session, certificate_chain: [leaf].map { |cert| Base64.strict_encode64(cert.to_der) })
    Qes::Providers::MobileApp.new(session).send(:ltv_values)

    expect(Qes::Ltv).to have_received(:check_revoked!)
      .with(leaf, chain: array_including(intermediate), crls: [intermediate_crl])
  end

  it 'returns the verified chain for DSS, not only the client chain' do
    allow(Qes).to receive(:trust_roots).and_return([root, intermediate])
    allow(Qes::Ltv).to receive(:fetch_crls).and_return([intermediate_crl])
    allow(Qes::Ltv).to receive(:check_revoked!)

    session = build(:qes_session, certificate_chain: [leaf].map { |cert| Base64.strict_encode64(cert.to_der) })
    values = Qes::Providers::MobileApp.new(session).send(:ltv_values)

    expect(values[:certs]).to include(leaf.to_der, intermediate.to_der)
  end
end
