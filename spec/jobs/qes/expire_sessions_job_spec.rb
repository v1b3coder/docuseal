# frozen_string_literal: true

require 'rails_helper'

# Poznámka auditu: plánování ExpireSessionsJob musí být atomické, ne
# LockEvent okno, které dva procesy při startu projdou současně.
RSpec.describe Qes::ExpireSessionsJob do
  it 'schedules only when the cache lock is acquired' do
    cache = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(cache)
    allow(cache).to receive(:write).and_return(true, false)
    allow(described_class).to receive(:perform_in)

    described_class.new.reschedule!
    described_class.new.reschedule!

    expect(cache).to have_received(:write).twice
    expect(described_class).to have_received(:perform_in).once
  end
end
