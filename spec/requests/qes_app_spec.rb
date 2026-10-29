# frozen_string_literal: true

require 'rails_helper'

# Web fallback `/qes/sign` a `/qes/app` (SPEC § 6.4): QR i tlačítko míří na custom
# scheme, protože Android App Links jsou zrušeny (#18.1) a aplikaci vybírá systémový
# chooser. Bez testu se tichá regrese (návrat https odkazu) pozná až na telefonu.
RSpec.describe 'QES app fallback page', type: :request do
  before { QesHelpers.configure! }
  after { Qes::Config.reset! }

  let(:token) { 'fallback-token' }

  before do
    create(:qes_session, state: 'awaiting_app', token_digest: Qes::Token.digest(token))
  end

  it 'offers the custom scheme and no https app link' do
    get '/qes/sign', params: { token: }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("dokulachtan://sign?token=#{token}")
    expect(response.body).not_to include("/qes/sign?token=#{token}")
  end
end
