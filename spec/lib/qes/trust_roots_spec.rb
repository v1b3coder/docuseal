# frozen_string_literal: true

require 'rails_helper'

# Statický český bundle pro ověřování (docs/10-qes.md): signing trust store
# zůstává PostSignum, verification trust store pokrývá české QTSP.
RSpec.describe 'QES trust roots' do
  around do |example|
    Qes::Config.reset!
    example.run
  ensure
    Qes::Config.reset!
  end

  let(:czech_bundle) { Rails.root.join('config/qes/czech.pem') }
  let(:certs) { OpenSSL::X509::Certificate.load_file(czech_bundle.to_s) }

  it 'loads every Czech qualified CA from the verification bundle' do
    common_names = certs.map { |cert| cert.subject.to_a.assoc('CN')&.dig(1) }

    expect(certs.size).to eq(29)
    expect(common_names).to include(
      'PostSignum Root QCA 4',
      'I.CA Root CA/RSA',
      'ACAeID3 - Root Certificate',
      'NCA Root CA/RSA 10/2023',
      'KB Root 3 CA'
    )
  end

  it 'contains only CA certificates and no duplicates' do
    fingerprints = certs.map { |cert| Digest::SHA256.hexdigest(cert.to_der) }

    expect(fingerprints.uniq.size).to eq(fingerprints.size)
    expect(certs).to all(satisfy { |cert| ca_certificate?(cert) })
  end

  it 'keeps signing roots narrow and verification roots Czech-wide' do
    Qes::Config[:trust_roots] = Rails.root.join('config/qes/postsignum.pem').to_s
    Qes::Config[:verification_trust_roots] = czech_bundle.to_s

    expect(Qes.trust_roots.size).to eq(6)
    expect(Qes.verification_trust_roots.size).to eq(29)
    expect(Qes.verification_trust_roots.map { |cert| cert.subject.to_a.assoc('CN')&.dig(1) })
      .to include('I.CA Root CA/RSA')
  end

  def ca_certificate?(cert)
    extension = cert.extensions.find { |ext| ext.oid == 'basicConstraints' }
    extension.present? && extension.value.include?('CA:TRUE')
  end
end
