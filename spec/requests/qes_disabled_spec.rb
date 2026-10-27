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
end
