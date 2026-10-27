# frozen_string_literal: true

require 'rails_helper'

# N5: upstream VerifyPdfSignature nezná důvěryhodný DocTS, takže po pořadí
# podpis + pečeť + DocTS hlásí "unsigned changes". QES cesta to umí.
RSpec.describe 'DocTS verification' do
  before do
    QesHelpers.configure!
    Qes::Config[:tsa_url] = 'http://tsa.test'
    allow(Qes).to receive(:tsa_trust_roots).and_return([QesHelpers.tsa_root_certificate])
    stub_tsa!
  end

  let(:submitter) { QesHelpers.build_qes_submitter }
  let(:pkcs) { QesHelpers.pkcs12 }
  let(:pdf) do
    sealed = QesHelpers.signed_pdf(seal: true, submitter:)
    stamped, state = Qes::DocTimestamp.apply(sealed, tsa_url: 'http://tsa.test')
    expect(state).to eq('applied')
    stamped
  end

  before do
    allow(Accounts).to receive(:load_trusted_certs).and_return([pkcs.certificate])
  end

  it 'does not report unsigned changes for a trusted DocTS in the web verifier' do
    sign_in(submitter.submission.template.author)
    tempfile = Tempfile.new(['signed', '.pdf'])
    tempfile.binmode
    tempfile.write(pdf)
    tempfile.rewind
    file = fixture_file_upload(tempfile.path, 'application/pdf')

    post '/verify_pdf_signature', params: { files: [file] }

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(I18n.t('contains_unsigned_changes_after_the_last_signature'))
  end

  it 'does not report unsigned changes for a trusted DocTS in the API verifier' do
    headers = { 'X-Auth-Token' => submitter.submission.template.author.access_token.token }

    post '/api/tools/verify', params: { file: Base64.strict_encode64(pdf) }, headers:, as: :json

    expect(response).to have_http_status(:ok)
    messages = response.parsed_body['signatures'].flat_map { |sig| sig['verification_result'] }
    expect(messages.map { |message| message['content'] })
      .not_to include(I18n.t('contains_unsigned_changes_after_the_last_signature'))
  end
end
