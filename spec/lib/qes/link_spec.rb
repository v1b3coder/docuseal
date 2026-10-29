# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Qes::Link do
  before { QesHelpers.configure! }
  after { Qes::Config.reset! }

  def request
    ActionDispatch::TestRequest.create
  end

  it 'builds the universal link from the public base URL' do
    Qes::Config[:public_base_url] = 'https://example.test/'

    expect(described_class.call(request, '/qes/sign', 'tok'))
      .to eq('https://example.test/qes/sign?token=tok')
  end

  it 'falls back to the request base URL when no public base URL is set' do
    Qes::Config[:public_base_url] = nil
    req = request
    req.host = 'company.test'

    expect(described_class.call(req, '/qes/app', 'tok'))
      .to eq('http://company.test/qes/app?token=tok')
  end

  it 'adds the server origin to the custom scheme link' do
    Qes::Config[:public_base_url] = 'https://example.test/'

    expect(described_class.custom_scheme(request, 'tok'))
      .to eq('dokulachtan://sign?token=tok&server=https%3A%2F%2Fexample.test')
  end
end
