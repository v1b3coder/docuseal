# frozen_string_literal: true

module Qes
  # Parsuje X.509 certifikát podepisujícího a určuje úroveň podpisu z QCStatements
  # (SPEC § 8): `QcCompliance` → AdES, `QcCompliance` + `QcSSCD` → QES.
  class CertificateInfo
    QC_STATEMENTS_OID = '1.3.6.1.5.5.7.1.3'
    QC_COMPLIANCE_OID = '0.4.0.1862.1.1'
    QC_SSCD_OID = '0.4.0.1862.1.4'

    QC_STATEMENT_NAMES = {
      QC_COMPLIANCE_OID => 'QcCompliance',
      QC_SSCD_OID => 'QcSSCD'
    }.freeze

    DIGITAL_SIGNATURE_BIT = 0
    SAN_OID = '2.5.29.17'
    SAN_RFC822_NAME = 1

    attr_reader :certificate

    def self.parse(der)
      new(OpenSSL::X509::Certificate.new(der))
    rescue OpenSSL::X509::CertificateError, ArgumentError, TypeError
      raise ClientError.new(:invalid_certificate, 'Certificate could not be parsed')
    end

    def initialize(certificate)
      @certificate = certificate
    end

    def qc_statements
      extension = find_extension('1.3.6.1.5.5.7.1.3', 'qcStatements')
      return [] if extension.blank?

      statements = OpenSSL::ASN1.decode(extension.value_der)
      Array(statements.value).filter_map do |statement|
        next unless statement.is_a?(OpenSSL::ASN1::Sequence)

        oid = statement.value.first
        QC_STATEMENT_NAMES[oid.value] if oid.respond_to?(:value)
      end
    rescue OpenSSL::ASN1::ASN1Error
      []
    end

    def qc_compliance?
      qc_statements.include?('QcCompliance')
    end

    def qc_sscd?
      qc_statements.include?('QcSSCD')
    end

    def level
      return 'none' unless qc_compliance?

      qc_sscd? ? 'qes' : 'ades'
    end

    def key_usage
      extension = find_extension('2.5.29.15', 'keyUsage')
      return nil if extension.blank?

      OpenSSL::ASN1.decode(extension.value_der).value.unpack1('B*')
    rescue OpenSSL::ASN1::ASN1Error
      nil
    end

    def digital_signature?
      usage = key_usage
      usage&.[](0) == '1'
    end

    def content_commitment?
      key_usage&.[](1) == '1'
    end

    def signing_leaf?
      return false unless digital_signature? || content_commitment?

      constraints = find_extension('2.5.29.19', 'basicConstraints')
      return true unless constraints

      sequence = OpenSSL::ASN1.decode(constraints.value_der)
      return false unless sequence.is_a?(OpenSSL::ASN1::Sequence)

      sequence.value.none? { |item| item.is_a?(OpenSSL::ASN1::Boolean) && item.value }
    rescue OpenSSL::ASN1::ASN1Error
      false
    end

    def find_extension(oid, short_name)
      certificate.extensions.find { |ext| ext.oid == oid || ext.oid == short_name }
    end

    def key_type
      case certificate.public_key
      when OpenSSL::PKey::RSA then 'rsa'
      when OpenSSL::PKey::EC then 'ecdsa'
      end
    end

    def key_size
      case certificate.public_key
      when OpenSSL::PKey::RSA then certificate.public_key.n.num_bits
      when OpenSSL::PKey::EC then certificate.public_key.group.degree
      end
    end

    def expired?(at = Time.current)
      at < certificate.not_before || at > certificate.not_after
    end

    def serial_hex
      "0x#{certificate.serial.to_s(16).upcase}"
    end

    # SAN e-maily podepisujícího v pořadí v certifikátu. PostSignum jich umí
    # až 3, I.CA e-mail nemusí mít vůbec; do auditu jde první uvedený.
    def email_addresses
      extension = find_extension(SAN_OID, 'subjectAltName')
      return [] if extension.blank?

      OpenSSL::ASN1.decode(extension.value_der).value.filter_map do |name|
        Qes::CertificateName.utf8(name.value) if name.tag_class == :CONTEXT_SPECIFIC && name.tag == SAN_RFC822_NAME
      end
    rescue OpenSSL::ASN1::ASN1Error
      []
    end

    def email
      email_addresses.first.presence || subject_email
    end

    # Všechny e-maily podepisujícího: SAN rfc822Name a `emailAddress`
    # v předmětu, bez duplicit (certifikát jich může mít víc).
    def emails
      (email_addresses + [subject_email]).compact_blank.uniq
    end

    # E-mail v předmětu certifikátu (`emailAddress`), když v SAN chybí.
    def subject_email
      Qes::CertificateName.value(certificate.subject.to_a, 'emailAddress')
    end

    # Lidsky čitelný název vydavatele (autorita, která certifikát vydala):
    # CN, OU, O, C od nejspecifičtějšího; `to_s` dává "/C=CZ/…", což do UI
    # nepatří. Hodnoty s čárkou („Česká pošta, s.p.“) oddělujeme „ · “.
    def issuer_name
      Qes::CertificateName.display(certificate.issuer, Qes::CertificateName::ISSUER_ORDER)
    end

    # Technický název předmětu s typy atributů a UTF-8 hodnotami pro
    # technické detaily; `to_s` escapuje non-ASCII bajty jako „\xC4\x8C“.
    def subject_text
      Qes::CertificateName.format(certificate.subject)
    end

    def issuer_text
      Qes::CertificateName.format(certificate.issuer)
    end

    # Jméno do pečeti: CN, jinak givenName + surname. Celý předmět se
    # nepoužívá, aby se v pečeti neobjevily atributy certifikátu.
    def display_name
      attributes = certificate.subject.to_a
      common_name = Qes::CertificateName.value(attributes, 'CN')
      return common_name if common_name.present?

      given_name = Qes::CertificateName.value(attributes, 'GN') ||
                    Qes::CertificateName.value(attributes, 'givenName')
      surname = Qes::CertificateName.value(attributes, 'SN') ||
                Qes::CertificateName.value(attributes, 'surname')

      [given_name, surname].compact_blank.join(' ').presence
    end

    # Identita, kterou nese viditelná pečeť v TBS. Ukládá se do metadat TBS
    # a `complete!` po podpisu ověří, že sedí s certifikátem podpisu.
    def stamp_identity
      { 'name' => display_name, 'email' => email }.compact
    end

    def to_h
      {
        subject: certificate.subject.to_s,
        name: display_name,
        issuer: certificate.issuer.to_s,
        serial: serial_hex,
        not_before: certificate.not_before.utc.iso8601,
        not_after: certificate.not_after.utc.iso8601,
        level: level,
        qc_statements: qc_statements,
        key_type: key_type,
        key_size: key_size,
        key_usage: key_usage,
        email: email
      }
    end

    # Zkontroluje certifikát proti požadované úrovni a umístění klíče (SPEC § 5.2).
    # Vrací hash pro `certificate_info`; při chybě vyhodí `Qes::ClientError`.
    def validate!(level_required:, key_location:, at: Time.current)
      unless signing_leaf?
        raise ClientError.new(:invalid_certificate, 'A non-CA signing certificate with signing key usage is required')
      end
      raise ClientError.new(:certificate_expired, 'Certificate is not valid at this time') if expired?(at)
      raise ClientError.new(:unsupported_key, "Unsupported key type #{key_type.inspect}") unless %w[rsa ecdsa].include?(key_type)
      raise ClientError.new(:unsupported_key, 'Key too small') if key_type == 'rsa' && key_size < 2048

      if key_location == 'phone_keystore' && qc_sscd?
        raise ClientError.new(:level_mismatch, 'QcSSCD certificate cannot be used from phone keystore')
      end

      if key_location == 'card' && !qc_sscd?
        raise ClientError.new(:level_mismatch, 'Card certificate must be QcSSCD')
      end

      if level_required == 'qes' && !qc_sscd?
        raise ClientError.new(:qes_required_qscd, 'QES requires a QcSSCD certificate')
      end

      raise ClientError.new(:not_qualified, 'Certificate is not qualified') unless qc_compliance?

      to_h
    end
  end
end
