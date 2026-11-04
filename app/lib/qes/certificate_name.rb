# frozen_string_literal: true

module Qes
  # Lidsky čitelné hodnoty z X.509 Name (docs/16 § 4.2): `to_s` vrací
  # "/C=CZ/…" a `to_a` hodnoty jako BINARY (ASCII-8BIT), i když certifikát
  # nese UTF-8. Do JSONu a UI patří UTF-8 hodnoty bez typu atributu.
  module CertificateName
    # Pořadí atributů v lidsky čitelném názvu vydavatele: od
    # nejspecifičtějšího (název CA) po nejobecnější (země).
    ISSUER_ORDER = %w[CN OU O C].freeze

    module_function

    # Hodnota atributu jako UTF-8; neplatné bajty nahradí U+FFFD.
    def utf8(value)
      value&.dup&.force_encoding(Encoding::UTF_8)&.scrub
    end

    # Hodnota atributu z `to_a` jako UTF-8; `nil`, když atribut v DN není.
    def value(attributes, short_name)
      utf8(attributes.assoc(short_name)&.at(1))
    end

    # První existující hodnota z daných atributů (např. `GN`, pak `givenName`).
    def first_value(attributes, *short_names)
      short_names.filter_map { |short_name| value(attributes, short_name) }.first
    end

    # Hodnoty DN v zadaném pořadí atributů, ostatní za nimi; bez typu
    # atributu a bez duplicit, oddělené „ · “ (hodnota může obsahovat čárku).
    def display(name, order = [])
      attributes = name.to_a
      values = order.filter_map { |short_name| value(attributes, short_name) }
      values += attributes.map { |attribute| utf8(attribute[1]) }

      values.compact_blank.uniq.join(' · ')
    end

    # Technický název DN s typy atributů a UTF-8 hodnotami.
    def format(name)
      name.to_a.map { |attribute| "#{attribute[0]}=#{utf8(attribute[1])}" }.join(' · ')
    end
  end
end
