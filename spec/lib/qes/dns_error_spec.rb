# frozen_string_literal: true

require 'rails_helper'

# Poznámka auditu: výpadek DNS musí skončit řízenou FetchError, ne
# Resolv::ResolvError, který by v controlleru skončil 500.
RSpec.describe 'QES LTV DNS failure' do
  before { QesHelpers.configure! }

  it 'wraps a DNS failure into FetchError' do
    allow(Resolv).to receive(:getaddresses).and_raise(Resolv::ResolvError, 'DNS down')

    expect { Qes::Ltv.fetch_crl('https://nonexistent.invalid/root.crl') }
      .to raise_error(Qes::Ltv::FetchError, /could not be resolved/)
  end
end
