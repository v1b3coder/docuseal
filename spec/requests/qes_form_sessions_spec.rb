# frozen_string_literal: true

require 'rails_helper'

# N6: prohlížeč po dokončení čte state.values z form endpointu, ale ten je
# nevracel. Bez nich zůstanou {{name}}, datum a vzorce nevyřešené a uložení
# skončí na 422.
RSpec.describe 'QES form sessions', type: :request do
  before { QesHelpers.configure! }

  it 'returns frozen non-QES values for a completed session' do
    submitter = QesHelpers.build_qes_submitter
    field = submitter.submission.template_fields.find { |item| item['type'] == 'qes' }
    session = create(:qes_session, :with_values_snapshot, submitter:,
                                                      submission: submitter.submission,
                                                      account: submitter.account,
                                                      field_uuid: field['uuid'],
                                                      state: 'completed',
                                                      completed_at: Time.current,
                                                      level: 'ades')
    submitter.update!(completed_at: Time.current,
                      values: submitter.values.merge(field['uuid'] => "qes:#{session.id}"))
    sign_in(submitter.submission.template.author)

    get "/s/#{submitter.slug}/qes_sessions/#{session.id}", headers: { 'Accept' => 'application/json' }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['values'])
      .to eq(Qes::ValueValidator.non_qes_values(submitter.values, submitter))
  end
end
