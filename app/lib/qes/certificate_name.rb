# frozen_string_literal: true

module Qes
  # Lidsky citelne hodnoty z X.509 Name (docs/16 § 4.2): `to_s` vraci
  # "/C=CZ/…" a `to_a` hodnoty jako BINARY (ASCII-8BIT), i kdyz certifikat
  # nese UTF-8. Do JSONu a UI patri UTF-8 hodnoty bez typu atributu.
  module CertificateName
    # Poradi atributu v lidsky citelnem nazvu vydavatele: od
    # nejspecifictejsiho (nazev CA) po nejobecnejsi (zeme).
    ISSUER_ORDER = %w[CN OU O C].freeze

    module_function

    # Hodnota atributu jako UTF-8; neplatne bajty nahradi U+FFFD.
    def utf8(value)
      value&.dup&.force_encoding(Encoding::UTF_8)&.scrub
    end

    # Hodnota atributu z `to_a` jako UTF-8; `nil`, kdyz atribut v DN neni.
    def value(attributes, short_name)
      utf8(attributes.assoc(short_name)&.at(1))
    end

    # Hodnoty DN v zadanem poradi atributu, ostatni za nimi; bez typu
    # atributu a bez duplicit, oddelene „ · “ (hodnota muze obsahovat carku).
    def display(name, order = [])
      attributes = name.to_a
      values = order.filter_map { |short_name| value(attributes, short_name) }
      values += attributes.map { |attribute| utf8(attribute[1]) }

      values.compact_blank.uniq.join(' · ')
    end

    # Technicky nazev DN s typy atributu a UTF-8 hodnotami.
    def format(name)
      name.to_a.map { |attribute| "#{attribute[0]}=#{utf8(attribute[1])}" }.join(' · ')
    end
  end
end
