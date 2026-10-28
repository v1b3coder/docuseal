# frozen_string_literal: true

require 'rails_helper'

# Regrese R4 z docs/22-final-audit-fork.md: neplatná QES šablona musí vrátit
# 422 s textem, ne 500 a tiché neuložení v builderu.
RSpec.describe 'QES template validation errors', type: :request do
  let(:submission) { QesHelpers.build_qes_submission(count: 2) }
  let(:template) { submission.template }
  let(:author) { template.author }

  before do
    QesHelpers.configure!
    sign_in(author)
  end

  def fields_without_last_signer_qes
    template.fields.reject do |field|
      field['type'] == 'qes' && field['submitter_uuid'] == template.submitters.last['uuid']
    end
  end

  it 'returns 422 with a translated error when a signer loses the qes field' do
    put template_path(template), params: {
      template: { fields: fields_without_last_signer_qes, submitters: template.submitters }
    }, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to include(I18n.t('qes.error.qes_all_signers_required'))
    expect(template.reload.fields.count { |field| field['type'] == 'qes' }).to eq(2)
  end

  it 'returns 422 from the templates API instead of 500' do
    put "/api/templates/#{template.id}",
        headers: { 'x-auth-token' => author.access_token.token },
        params: { fields: fields_without_last_signer_qes, submitters: template.submitters }.to_json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to include(I18n.t('qes.error.qes_all_signers_required'))
  end

  it 'renders the preferences modal with the error instead of 500' do
    post template_preferences_path(template), params: { template: { preferences: { submitters_order: '' } } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t('qes.error.qes_signing_order_required'))
    expect(template.reload.preferences['submitters_order']).to eq('preserved')
  end
end
