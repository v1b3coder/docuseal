# frozen_string_literal: true

require 'rails_helper'

# `.well-known/apple-app-site-association` (SPEC § 6.6, M13): na čerstvé instalaci nesmí
# `maybe_redirect_to_setup` vrátit 302 na /setup, jinak Universal Links selžou.
# Android `assetlinks.json` tu záměrně není (#18.1) — App Links zrušeny.
RSpec.describe 'QES well-known files', type: :request do
  before do
    QesHelpers.configure!
    allow(User).to receive(:exists?).and_return(false)
  end

  it 'serves apple-app-site-association as JSON' do
    get '/.well-known/apple-app-site-association'

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('application/json')
    expect(response.parsed_body.dig('applinks', 'details')).to be_present
  end
end
