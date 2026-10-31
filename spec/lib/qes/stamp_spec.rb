# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Qes::Stamp do
  before { QesHelpers.configure! }

  let(:submitter) { QesHelpers.build_qes_submitter }
  let(:identity) { QesHelpers.stamp_identity }

  def bitmap(pdf)
    io = StringIO.new
    pdf.write(io, validate: false)
    Pdfium::Document.open_io(StringIO.new(io.string)) do |doc|
      doc.get_page(0).render_to_bitmap(scale: 1).first
    end
  end

  [[30, 16], [1, 1], [150, 44]].each do |width, height|
    it "clips every painted pixel to a #{width} by #{height} field" do
      pdf = HexaPDF::Document.new
      pdf.pages.add([0, 0, 300, 300])
      field = { 'areas' => [{ 'x' => 0.2, 'y' => 0.2, 'w' => width / 300.0,
                             'h' => height / 300.0, 'page' => 0 }] }
      before = bitmap(pdf)

      described_class.draw(pdf, identity, field, locale: submitter.account.locale)
      after = bitmap(pdf)

      outside_changes = []
      300.times do |y|
        300.times do |x|
          next if x >= 60 && x < 60 + width && y >= 60 && y < 60 + height

          offset = (y * 300 + x) * 4
          outside_changes << [x, y] if before.byteslice(offset, 4) != after.byteslice(offset, 4)
        end
      end

      expect(outside_changes).to be_empty
      expect(after).not_to eq(before) if width > 1
    end
  end

  it 'puts the certificate e-mail under the name' do
    identity = { 'name' => 'Jan Novák', 'email' => 'jan@firma.cz' }

    I18n.with_locale(submitter.account.locale) do
      lines = described_class.stamp_lines(identity, locale: submitter.account.locale)

      expect(lines).to eq([I18n.t('qes.stamp.title'), 'Jan Novák', 'jan@firma.cz',
                           I18n.l(Time.current.to_date, format: :long, locale: submitter.account.locale)])
    end
  end

  it 'omits the e-mail line when the certificate has none' do
    I18n.with_locale(submitter.account.locale) do
      lines = described_class.stamp_lines({ 'name' => 'Jan Novák' }, locale: submitter.account.locale)

      expect(lines.size).to eq(3)
      expect(lines).not_to include(nil, '')
    end
  end

  it 'keeps the fixed font for three lines and shrinks it for four' do
    expect(described_class.font_size_for(44, 3, 4.4)).to eq(9)
    expect(described_class.font_size_for(44, 4, 4.4)).to be < 9
    expect(described_class.font_size_for(50, 4, 5)).to be > 8
  end
end
