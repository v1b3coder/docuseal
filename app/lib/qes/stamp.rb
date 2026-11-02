# frozen_string_literal: true

module Qes
  # Viditelná pečeť podepisujícího (SPEC § 7.1): appearance stream widgetu
  # podpisového pole, takže ji podpis kryje a zůstává INTACT (DESIGN § 12 #8).
  # Widget (a tedy i pečeť) je součástí TBS PDF před podpisem, takže ho vidí
  # i analýza revizí (pyHanko): nový viditelný podpis je form filling,
  # ne změna obsahu stránky.
  module Stamp
    MIN_WIDTH = 150
    # Čtyři řádky (titulek, jméno, e-mail, datum) se do 44 pt nevešly bez
    # ořezu; 58 pt drží 9pt font a stejný padding ze všech stran.
    MIN_HEIGHT = 58

    module_function

    # Umístění pole `qes` v globálním indexu stránek: [page, Rect] v PDF
    # souřadnicích (`[llx, lly, urx, ury]`).
    # `nil` = pole do dokumentu nepatří (podmíněná příloha) nebo nemá plochu.
    def placement(pdf, field, offsets: {})
      area = field&.dig('areas', 0)
      return if area.present? && offsets.present? && !offsets.key?(area['attachment_uuid'])

      page_index =
        if area.present?
          area['page'].to_i + offsets.fetch(area['attachment_uuid'], 0)
        else
          pdf.pages.size - 1
        end
      page = pdf.pages[[page_index, pdf.pages.size - 1].min]
      return if page.nil?

      width = page.box.width
      height = page.box.height
      x = area.present? ? area['x'].to_f * width : 36.0
      top = area.present? ? area['y'].to_f * height : height - 36.0 - MIN_HEIGHT
      w = area.present? ? area['w'].to_f * width : MIN_WIDTH
      h = area.present? ? area['h'].to_f * height : MIN_HEIGHT

      return unless w.positive? && h.positive?

      y = height - top - h

      [page, [x, y, x + w, y + h]]
    end

    # Vykreslí pečeť do appearance streamu widgetu (form XObject s `/BBox`).
    # Souřadnice jsou relativní k widgetu, ořez drží `BBox` i explicitní clip.
    def draw(widget, identity, locale:)
      lines = stamp_lines(identity, locale:)
      return if lines.empty?

      rect = widget[:Rect]
      w = rect.width
      h = rect.height
      font = widget.document.fonts.add(Submissions::GenerateResultAttachments::FONT_NAME)
      padding = [h * 0.10, 2.5].max
      font_size = font_size_for(h, lines.size, padding)
      line_height = font_size * 1.3
      # Blok se sází na střed podle skutečného inkoustu řádků (font ascent
      # nestačí), aby padding vyšel stejný nahoře i dole.
      fragments = lines.map do |line|
        HexaPDF::Layout::TextFragment.create(line, font:, font_size:)
      end
      top = fragments.first.exact_y_max
      bottom = -fragments.last.exact_y_min
      block_height = top + bottom + (line_height * (lines.size - 1))
      block_top = (h + block_height) / 2
      canvas = widget.create_appearance.canvas

      canvas.save_graphics_state do
        # Ořez platí i pro text a tah okraje, včetně velmi malých polí.
        canvas.rectangle(0, 0, w, h).clip_path.end_path
        canvas.line_width(0.7)
        canvas.stroke_color(0x29, 0x13, 0x34)
        canvas.fill_color(0xF6, 0xF1, 0xF9)
        if w > 2 && h > 2
          radius = [2, (w - 2) / 2, (h - 2) / 2].min
          canvas.rectangle(1, 1, w - 2, h - 2, radius:).fill_stroke
        end

        canvas.fill_color(0x29, 0x13, 0x34)
        canvas.font(font, size: font_size)

        lines.each_with_index do |line, index|
          baseline = block_top - top - (line_height * index)
          next if baseline < 0

          canvas.text(fit_text(font, line, font_size, w - (2 * padding)), at: [padding, baseline])
        end
      end
    end

    def stamp_lines(identity, locale:)
      I18n.with_locale(locale) do
        [
          I18n.t('qes.stamp.title'),
          identity['name'].to_s,
          identity['email'].to_s,
          I18n.l(Time.current.to_date, format: :long, locale: locale)
        ].map(&:strip).compact_blank
      end
    end

    # Pečeť má až 4 řádky (title, jméno, e-mail, datum); pevný font z výšky pole
    # by 4. řádek do malého pole nevešel a tiše se zahodil. Font se proto
    # zmenší tak, aby se všechny řádky vešly (min 4 pt) a zůstal stejný
    # padding nahoře i dole.
    def font_size_for(height, line_count, padding)
      fitting = (height - (2 * padding)) / (1.25 + (1.3 * (line_count - 1)))

      [fitting, height * 0.22].min.clamp(4, 9).to_f
    end

    def fit_text(font, text, font_size, max_width)
      return text if text_width(font, text, font_size) <= max_width

      (1..text.length).reverse_each do |length|
        candidate = "#{text[0, length]}…"

        return candidate if text_width(font, candidate, font_size) <= max_width
      end

      ''
    end

    def text_width(font, text, font_size)
      HexaPDF::Layout::TextFragment.create(text, font:, font_size:).width
    end
  end
end
