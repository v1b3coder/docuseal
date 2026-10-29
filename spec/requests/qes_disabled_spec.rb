# frozen_string_literal: true

require 'rails_helper'

# Poznámka auditu: QES hooky se nesmí spouštět na instalaci s QES_ENABLED=false.
RSpec.describe 'QES disabled hooks', type: :request do
  before do
    QesHelpers.configure!
    Qes::Config[:enabled] = false
  end

  it 'does not call QES value or signing hooks for a normal submitter' do
    submission = QesHelpers.build_qes_submission
    submitter = submission.submitters.first
    allow(Qes::ValueValidator).to receive(:call).and_call_original
    expect(QesSession).not_to receive(:where)
    headers = { 'X-Auth-Token' => submission.template.author.access_token.token }

    put "/api/submitters/#{submitter.id}", params: { completed: true }, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(Qes::ValueValidator).not_to have_received(:call)
  end

  it 'returns 404 for the app fallback page' do
    allow(User).to receive(:exists?).and_return(true)

    get '/qes/sign', params: { token: 'unknown' }

    expect(response).to have_http_status(:not_found)
  end

  it 'returns 404 for app links' do
    get '/.well-known/assetlinks.json'

    expect(response).to have_http_status(:not_found)
  end

  it 'returns 404 for the test CRL' do
    Qes::Config[:test_crl_path] = Rails.root.join('config/qes/test-root.crl').to_s

    get '/qes-test/root.crl'

    expect(response).to have_http_status(:not_found)
  end

  it 'keeps required from the API for a qes field' do
    submission = QesHelpers.build_qes_submission
    submitter = submission.submitters.first
    field = submission.template_fields.find { |item| item['type'] == 'qes' }
    headers = { 'X-Auth-Token' => submission.template.author.access_token.token }

    put "/api/submitters/#{submitter.id}",
        params: { fields: [{ uuid: field['uuid'], required: false }] }, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(submission.reload.template_fields.find { |item| item['uuid'] == field['uuid'] }['required']).to be(false)
  end
end
