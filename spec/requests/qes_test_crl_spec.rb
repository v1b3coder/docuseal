# frozen_string_literal: true

require 'rails_helper'

# Test CRL pro staging (SPEC § 7.4): test certifikáty mají CRL DP na staging
# host, aby fail-closed LTV fungovalo i bez přístupu na 127.0.0.1.
RSpec.describe 'QES test CRL', type: :request do
  before do
    QesHelpers.configure!
    allow(User).to receive(:exists?).and_return(false)
  end

  after { Qes::Config.reset! }

  it 'serves the test CRL when configured' do
    Qes::Config[:test_crl_path] = Rails.root.join('config/qes/test-root.crl').to_s

    get '/qes-test/root.crl'

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('application/pkix-crl')
    expect(OpenSSL::X509::CRL.new(response.body).issuer.to_s).to include('Dokulachtan Test Root CA')
  end

  it 'returns 404 when the test CRL is not configured (production)' do
    get '/qes-test/root.crl'

    expect(response).to have_http_status(:not_found)
  end
end
