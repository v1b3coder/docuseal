# frozen_string_literal: true

require 'rails_helper'

# Statický český bundle pro ověřování (docs/10-qes.md): signing trust store
# zůstává PostSignum, verification trust store obsahuje jen vydávající CA z TSL.
RSpec.describe 'QES trust roots' do
  around do |example|
    Qes::Config.reset!
    example.run
  ensure
    Qes::Config.reset!
  end

  let(:czech_bundle) { Rails.root.join('config/qes/czech.pem') }
  let(:certs) { OpenSSL::X509::Certificate.load_file(czech_bundle.to_s) }

  it 'loads only issuing CAs from the verification bundle' do
    common_names = certs.map { |cert| cert.subject.to_a.assoc('CN')&.dig(1) }

    expect(certs.size).to eq(15)
    expect(common_names).to include(
      'PostSignum Qualified CA 4',
      'I.CA EU Qualified CA2/RSA 06/2022',
      'ACAeID3.3 - Issuing Certificate',
      'NCA SubCA1/RSA 10/2023'
    )
    # KB CN je v OpenSSL ASCII-8BIT s escapovanými bajty, proto se hledá jen ASCII část.
    expect(certs.map { |cert| cert.subject.to_s }).to include(a_string_including('Komer'))
  end

  it 'does not use self-signed roots as trust anchors' do
    # Root jako anchor by důvěřoval celému podstromu; anchor je vydávající CA.
    expect(certs.select { |cert| cert.subject == cert.issuer }).to be_empty
  end

  it 'contains only CA certificates and no duplicates' do
    fingerprints = certs.map { |cert| Digest::SHA256.hexdigest(cert.to_der) }

    expect(fingerprints.uniq.size).to eq(fingerprints.size)
    expect(certs).to all(satisfy { |cert| ca_certificate?(cert) })
  end

  it 'keeps the signing store separate from the verification anchors' do
    Qes::Config[:trust_roots] = Rails.root.join('config/qes/postsignum.pem').to_s
    Qes::Config[:verification_trust_roots] = czech_bundle.to_s

    expect(Qes.trust_roots.size).to eq(6)
    expect(Qes.verification_trust_roots.size).to eq(15)
    expect(Qes.verification_trust_roots.map { |cert| cert.subject.to_a.assoc('CN')&.dig(1) })
      .to include('I.CA EU Qualified CA2/RSA 06/2022')
  end

  def ca_certificate?(cert)
    extension = cert.extensions.find { |ext| ext.oid == 'basicConstraints' }
    extension.present? && extension.value.include?('CA:TRUE')
  end
end
