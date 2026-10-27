# frozen_string_literal: true

require 'rails_helper'

# N7: dokončený token nesmí platit navždy a payload nemá vracet hodnoty
# formuláře, které appka k obnově nepotřebuje.
RSpec.describe 'QES completed session TTL', type: :request do
  before { QesHelpers.configure! }

  def completed_session(token:, completed_at:)
    submitter = QesHelpers.build_qes_submitter
    field = submitter.submission.template_fields.find { |item| item['type'] == 'qes' }
    session = create(:qes_session, submitter:, submission: submitter.submission,
                                    account: submitter.account, field_uuid: field['uuid'],
                                    state: 'completed', completed_at:, level: 'ades')
    session.update!(token_digest: Qes::Token.digest(token))
    [session, submitter]
  end

  it 'keeps a completed session available for 24 hours' do
    completed_session(token: 'recent-completed', completed_at: 1.hour.ago)

    get '/qes/sessions/recent-completed'

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['state']).to eq('completed')
    expect(response.parsed_body).not_to have_key('values')
  end

  it 'expires a completed session after 24 hours' do
    completed_session(token: 'old-completed', completed_at: 25.hours.ago)

    get '/qes/sessions/old-completed'

    expect(response).to have_http_status(:gone)
    expect(response.parsed_body['error']).to eq('expired_token')
  end
end
