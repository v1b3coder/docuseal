# frozen_string_literal: true

module Qes
  # Viditelná pečeť podepisujícího (SPEC § 7.1): appearance stream widgetu
  # podpisového pole, takže ji podpis kryje a zůstává INTACT (DESIGN § 12 #8).
  # Widget (a tedy i pečeť) je součástí TBS PDF před podpisem, takže ho vidí
  # i analýza revizí (pyHanko): nový viditelný podpis je form filling,
  # ne změna obsahu stránky.
  #
  # Vzhled odpovídá kartě v náhledu (`submit_form/_qes_summary`): zelený check,
  # titulek, badge úrovně, jméno a e-mail z certifikátu. Text „Signature is
  # valid“ tu být nemůže: pečeť vzniká před podpisem, kdy platnost podpisu
  # ještě neexistuje.
  module Stamp
    MIN_WIDTH = 150
    # Čtyři řádky (titulek, jméno, e-mail, datum) se do 44 pt nevešly bez
    # ořezu; 58 pt drží 9pt font a stejný padding ze všech stran.
    MIN_HEIGHT = 58

    BACKGROUND = [0xF9, 0xFA, 0xFB].freeze
    BORDER = [0xD1, 0xD5, 0xDB].freeze
    TEXT = [0x11, 0x18, 0x27].freeze
    MUTED = [0x6B, 0x72, 0x80].freeze
    GREEN = [0x22, 0xC5, 0x5E].freeze
    BADGE = [0xE5, 0xE7, 0xEB].freeze
    BADGE_TEXT = [0x37, 0x41, 0x51].freeze
    BADGE_WIDTH = 19
    FONT_SIZE = 9.0

    module_function

    # Umístění pole `qes` v globálním indexu stránek: [page, Rect] v PDF
    # souřadnicích (`[llx, lly, urx, ury]`).
    # `nil` = pole do dokumentu nepatří (podmíněná příloha) nebo nemá plochu.
    def placement(pdf, field, identity: nil, locale: nil, level: nil, offsets: {})
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
      top = area.present? ? area['y'].to_f * height : nil
      w = area.present? ? area['w'].to_f * width : MIN_WIDTH
      h = area.present? ? area['h'].to_f * height : MIN_HEIGHT

      if identity.present? && locale.present?
        # Plocha od zadavatele určuje jen levý horní roh; velikost pečeti
        # se počítá z textu, aby se vešla celá a čitelně.
        w, h = required_size(pdf, identity, locale:, level:)
      end

      # Levý horní roh zůstává; velikost je z textu. Když se pečeť na
      # stránku nevejde, zmenší se (a `draw` zmenší font / zkrátí text).
      if area.present?
        w = [w, width - x].min
        h = [h, height - top].min
      else
        w = [w, width - (2 * 36.0)].min
        h = [h, height - (2 * 36.0)].min
        top = height - 36.0 - h
      end

      return unless w.positive? && h.positive?

      y = height - top - h

      [page, [x, y, x + w, y + h]]
    end

    # Minimální velikost pečeti pro text při 9 pt: šířka z nejdelšího řádku
    # (ikona + text + badge), výška ze všech řádků. Menší plocha od zadavatele
    # se zvětší doprava/dolů, aby se text vešel celý a čitelně.
    def required_size(pdf, identity, locale:, level: nil)
      rows = stamp_rows(identity, locale:)
      return [MIN_WIDTH, MIN_HEIGHT] if rows.empty?

      font = pdf.fonts.add(Submissions::GenerateResultAttachments::FONT_NAME)
      bold = pdf.fonts.add(Submissions::GenerateResultAttachments::FONT_NAME, variant: :bold)
      padding = [MIN_HEIGHT * 0.10, 2.5].max
      widths = rows.map do |row|
        case row[:kind]
        when :title
          FONT_SIZE + 2 + text_width(bold, row[:text], FONT_SIZE) +
            (level.present? ? BADGE_WIDTH + 4 : 0)
        when :name, :email
          FONT_SIZE + 2 + text_width(font, row[:text], FONT_SIZE)
        when :date
          text_width(font, row[:text], FONT_SIZE * 0.85)
        end
      end
      block_height = (1.25 * FONT_SIZE) + (1.3 * FONT_SIZE * (rows.size - 1))

      [[MIN_WIDTH, (2 * padding) + widths.max].max,
       [MIN_HEIGHT, (2 * padding) + block_height].max]
    end

    # Vykreslí pečeť do appearance streamu widgetu (form XObject s `/BBox`).
    # Souřadnice jsou relativní k widgetu, ořez drží `BBox` i explicitní clip.
    def draw(widget, identity, locale:, level: nil)
      rows = stamp_rows(identity, locale:)
      return if rows.empty?

      rect = widget[:Rect]
      w = rect.width
      h = rect.height
      font_name = Submissions::GenerateResultAttachments::FONT_NAME
      padding = [h * 0.10, 2.5].max
      font_size = font_size_for(h, rows.size, padding)
      line_height = font_size * 1.3
      # Blok se sází na střed, aby padding vyšel stejný nahoře i dole
      # i když cert nemá e-mail a řádků je méně.
      block_height = (1.25 * font_size) + (line_height * (rows.size - 1))
      baseline = ((h + block_height) / 2) - font_size
      canvas = widget.create_appearance.canvas

      canvas.save_graphics_state do
        # Ořez platí i pro text a tah okraje, včetně velmi malých polí.
        canvas.rectangle(0, 0, w, h).clip_path.end_path
        canvas.line_width(0.7)
        canvas.stroke_color(*BORDER)
        canvas.fill_color(*BACKGROUND)
        if w > 2 && h > 2
          radius = [2, (w - 2) / 2, (h - 2) / 2].min
          # Pozadí je z 80 % neprůhledné, aby bylo vidět dokument pod pečetí;
          # text a ikony zůstávají plné.
          canvas.opacity(fill_alpha: 0.8)
          canvas.rectangle(1, 1, w - 2, h - 2, radius:).fill_stroke
          canvas.opacity(fill_alpha: 1)
        end

        rows.each_with_index do |row, index|
          draw_row(canvas, row, w:, baseline: baseline - (line_height * index),
                    font_name:, font_size:, padding:, level:)
        end
      end
    end

    # Řádky pečeti v pořadí, v jakém se kreslí; prázdné (e-mail, jméno)
    # se vynechají, aby pečeť nezůstala prázdná.
    def stamp_rows(identity, locale:)
      I18n.with_locale(locale) do
        [
          { kind: :title, text: I18n.t('qes.stamp.title') },
          { kind: :name, text: identity['name'].to_s },
          { kind: :email, text: identity['email'].to_s },
          { kind: :date, text: I18n.l(Time.current.to_date, format: :long, locale: locale) }
        ].reject { |row| row[:text].blank? }
      end
    end

    def stamp_lines(identity, locale:)
      stamp_rows(identity, locale:).map { |row| row[:text] }
    end

    def draw_row(canvas, row, w:, baseline:, font_name:, font_size:, padding:, level:)
      icon = font_size
      text_x = padding + icon + 2
      center_y = baseline + (font_size * 0.32)

      case row[:kind]
      when :title
        draw_check(canvas, padding + (icon / 2), center_y, icon * 0.42)
        canvas.fill_color(*TEXT).font(font_name, size: font_size, variant: :bold)
        max_width = w - text_x - padding - (level.present? ? BADGE_WIDTH + 4 : 0)
        canvas.text(fit_text(canvas.font, row[:text], font_size, max_width), at: [text_x, baseline])
        draw_level_badge(canvas, w:, baseline:, font_size:, padding:, font_name:, level:)
      when :name
        draw_person(canvas, padding + (icon / 2), center_y, icon * 0.42)
        canvas.fill_color(*TEXT).font(font_name, size: font_size)
        canvas.text(fit_text(canvas.font, row[:text], font_size, w - text_x - padding), at: [text_x, baseline])
      when :email
        draw_certificate(canvas, padding + (icon / 2), center_y, icon * 0.42)
        canvas.fill_color(*MUTED).font(font_name, size: font_size)
        canvas.text(fit_text(canvas.font, row[:text], font_size, w - text_x - padding), at: [text_x, baseline])
      when :date
        canvas.fill_color(*MUTED).font(font_name, size: font_size * 0.85)
        canvas.text(row[:text], at: [padding, baseline])
      end
    end

    # Zelený kruh s bílým checkem (stejný motiv jako `circle_check` v náhledu).
    def draw_check(canvas, cx, cy, radius)
      canvas.fill_color(*GREEN).circle(cx, cy, radius).fill
      canvas.stroke_color(0xFFFFFF).line_width(radius * 0.32).line_cap_style(:round)
      canvas.polyline(cx - (radius * 0.45), cy + (radius * 0.02),
                      cx - (radius * 0.1), cy - (radius * 0.35),
                      cx + (radius * 0.5), cy + (radius * 0.4)).stroke
    end

    # Ikonka postavy: hlava a ramena, jen tah v šedé.
    def draw_person(canvas, cx, cy, radius)
      canvas.stroke_color(0x6B, 0x72, 0x80).line_width(0.7)
      canvas.circle(cx, cy + (radius * 0.42), radius * 0.34).stroke
      canvas.polyline(cx - (radius * 0.72), cy - (radius * 0.72),
                      cx - (radius * 0.34), cy - (radius * 0.2),
                      cx + (radius * 0.34), cy - (radius * 0.2),
                      cx + (radius * 0.72), cy - (radius * 0.72)).stroke
    end

    # Ikonka certifikátu: obdélník s dvěma řádky.
    def draw_certificate(canvas, cx, cy, radius)
      width = radius * 1.3
      height = radius * 1.6
      x = cx - (width / 2)
      y = cy - (height / 2)

      canvas.stroke_color(0x6B, 0x72, 0x80).line_width(0.7)
      canvas.rectangle(x, y, width, height, radius: 0.8).stroke
      canvas.line(x + 1, y + height - 2, x + width - 1, y + height - 2).stroke
      canvas.line(x + 1, y + height - 3.8, x + width - 1, y + height - 3.8).stroke
    end

    # Badge úrovně (AdES/QES) vpravo v titulkovém řádku.
    def draw_level_badge(canvas, w:, baseline:, font_size:, padding:, font_name:, level:)
      return if level.blank?

      label = level.to_s.upcase
      badge_height = font_size + 1.5
      x = w - padding - BADGE_WIDTH
      y = baseline - 1.5

      canvas.fill_color(*BADGE).rectangle(x, y, BADGE_WIDTH, badge_height, radius: 2).fill
      canvas.fill_color(*BADGE_TEXT).font(font_name, size: 6.5)
      text_x = x + ((BADGE_WIDTH - text_width(canvas.font, label, 6.5)) / 2)
      canvas.text(label, at: [text_x, y + 2.2])
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
