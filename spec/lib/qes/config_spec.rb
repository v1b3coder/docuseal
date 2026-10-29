# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Qes::Config do
  around do |example|
    keys = %w[QES_ENABLED QES_LTV_ALLOWED_HOSTS QES_TRUST_ROOTS QES_VERIFICATION_TRUST_ROOTS
              QES_TSA_URL QES_TSA_TRUST_ROOTS QES_REQUIRE_LTV]
    saved = keys.index_with { |key| ENV[key] }

    keys.each { |key| ENV.delete(key) }
    described_class.reset!
    example.run
  ensure
    keys.each { |key| saved[key].nil? ? ENV.delete(key) : ENV[key] = saved[key] }
    described_class.reset!
  end

  it 'defaults to the Czech deployment settings' do
    expect(described_class[:enabled]).to be(true)
    expect(described_class[:ltv_allowed_hosts])
      .to eq('crl.postsignum.cz,crl2.postsignum.cz,crl.postsignum.eu,qcrldp1.ica.cz,' \
             'qcrldp2.ica.cz,crldp1.ica.cz,crldp2.ica.cz')
    expect(described_class[:trust_roots]).to eq(Rails.root.join('config/qes/postsignum.pem').to_s)
    expect(File).to exist(described_class[:trust_roots])
    expect(described_class[:verification_trust_roots]).to eq(Rails.root.join('config/qes/czech.pem').to_s)
    expect(File).to exist(described_class[:verification_trust_roots])
    expect(described_class[:tsa_url]).to eq('http://timestamp.digicert.com')
    expect(described_class[:tsa_trust_roots]).to eq(Rails.root.join('config/qes/digicert-tsa.pem').to_s)
    expect(File).to exist(described_class[:tsa_trust_roots])
    expect(described_class[:require_ltv]).to be(true)
  end

  it 'lets ENV override the defaults' do
    ENV['QES_ENABLED'] = 'false'
    ENV['QES_LTV_ALLOWED_HOSTS'] = 'crl.example.test'
    ENV['QES_TRUST_ROOTS'] = '/tmp/root.pem'
    ENV['QES_VERIFICATION_TRUST_ROOTS'] = '/tmp/verify.pem'
    ENV['QES_TSA_URL'] = 'http://tsa.example.test'
    ENV['QES_TSA_TRUST_ROOTS'] = '/tmp/tsa.pem'
    ENV['QES_REQUIRE_LTV'] = 'false'

    expect(described_class[:enabled]).to be(false)
    expect(described_class[:ltv_allowed_hosts]).to eq('crl.example.test')
    expect(described_class[:trust_roots]).to eq('/tmp/root.pem')
    expect(described_class[:verification_trust_roots]).to eq('/tmp/verify.pem')
    expect(described_class[:tsa_url]).to eq('http://tsa.example.test')
    expect(described_class[:tsa_trust_roots]).to eq('/tmp/tsa.pem')
    expect(described_class[:require_ltv]).to be(false)
  end

  it 'restores defaults after reset!' do
    ENV['QES_ENABLED'] = 'false'
    expect(described_class[:enabled]).to be(false)

    ENV.delete('QES_ENABLED')
    described_class.reset!

    expect(described_class[:enabled]).to be(true)
  end
end
