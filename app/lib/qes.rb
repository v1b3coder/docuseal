# frozen_string_literal: true

# QES/AdES podpisový obřad (dokulachtan fork).
#
# Server nikdy nevidí privátní klíč podepisujícího: dostane jen certifikát,
# podepsané atributy CMS a raw signaturu, kterou vloží do PDF (PAdES).
# Design: DESIGN.md, detailní specifikace: SPEC.md.
module Qes
  class Error < StandardError; end

  # Neplatný přechod stavového automatu (SPEC § 4.3).
  class InvalidTransition < Error; end

  # Chyba, kterou lze bezpečně vrátit klientovi jako 422 s `code`.
  class ClientError < Error
    attr_reader :code

    def initialize(code, message = nil)
      @code = code
      super(message || code.to_s)
    end
  end

  # Konfigurace QES (SPEC § 11). Hodnoty se čtou z ENV, testy je mohou přepsat.
  module Config
    # QES_TSA_URL: RFC 3161 endpoint for signature and document timestamps.
    # QES_TSA_TRUST_ROOTS: comma-separated PEM file paths for trusted TSA roots.
    # Required whenever QES_TSA_URL is set, even with QES_TSA_REQUIRED=false.
    # Without TSA roots, timestamps provide no trusted historical validation time.
    #
    # Defaults are for the Czech deployment: PostSignum and I.CA CRL hosts,
    # PostSignum signing roots, Czech qualified CA roots for verification,
    # DigiCert TSA. ENV is an override; staging/test override trust roots,
    # require_ltv, test CRL and the allowlist. I.CA hosts are in the allowlist
    # because its CRL DPs are http-only (https on qcrldp1.ica.cz does not answer);
    # signing with an I.CA certificate still needs its roots in QES_TRUST_ROOTS.
    #
    # `trust_roots` is the signing trust store (which certificates may sign in
    # this DocuSeal); `verification_trust_roots` is the broader verification
    # trust store (which external PDFs we can verify). Keeping them separate stops
    # DocuSeal from accepting every Czech QTSP certificate for signing.
    CONFIG_DIR = File.expand_path('../../config/qes', __dir__)

    DEFAULTS = {
      enabled: true,
      session_ttl: 600,
      review_ttl: 900,
      # Absolutní strop od `created_at` (#23.4); musí být větší než session_ttl + review_ttl.
      session_max_ttl: 3600,
      pdf_max_bytes: 25.megabytes,
      signature_size: 20_000,
      signature_min_size: 20_000,
      signature_reserve: 65_536,
      seal_pkcs_path: nil,
      seal_pkcs_password: nil,
      deep_link_base: 'dokulachtan://sign',
      public_base_url: nil,
      trust_roots: File.join(CONFIG_DIR, 'postsignum.pem'),
      verification_trust_roots: File.join(CONFIG_DIR, 'czech.pem'),
      tsa_url: 'http://timestamp.digicert.com',
      tsa_trust_roots: File.join(CONFIG_DIR, 'digicert-tsa.pem'),
      tsa_required: true,
      require_ltv: true,
      ltv_allowed_hosts: 'crl.postsignum.cz,crl2.postsignum.cz,crl.postsignum.eu,' \
                         'qcrldp1.ica.cz,qcrldp2.ica.cz,crldp1.ica.cz,crldp2.ica.cz',
      test_crl_path: nil,
      ios_team_id: nil,
      expiry_job_interval: 60,
      completed_session_ttl: 86_400
    }.freeze

    class << self
      def [](key)
        overrides.fetch(key) { from_env(key) }
      end

      def []=(key, value)
        overrides[key] = value
      end

      def reset!
        @overrides = {}
      end

      def overrides
        @overrides ||= {}
      end

      private

      def from_env(key)
        env_name = "QES_#{key.to_s.upcase}"
        return DEFAULTS[key] unless ENV.key?(env_name)

        cast(ENV[env_name], DEFAULTS[key])
      end

      def cast(raw, default)
        case default
        when true, false then ActiveModel::Type::Boolean.new.cast(raw)
        when Integer then raw.to_i
        else raw.presence
        end
      end
    end
  end

  def self.enabled?
    Config[:enabled]
  end

  # QES hooky se mají spouštět jen při zapnutém QES a existenci QES pole;
  # jinak zbytečně dotazují qes_sessions při každém uložení (poznámka auditu).
  def self.active_for?(submission)
    enabled? && template_fields(submission).any? { |field| field['type'] == 'qes' }
  end

  # Trust roots pro přijetí certu při podpisu (SPEC § 5.2). Zůstává úzké:
  # český deployment podepisuje PostSignum certy, ne všechny české QTSP.
  def self.trust_roots
    load_roots(Config[:trust_roots])
  end

  # Trust roots pro ověření cizích PDF (SPEC § 7.5). Výchozí je český bundle
  # kvalifikovaných CA; podpisový trust store zůstává oddělený.
  def self.verification_trust_roots
    load_roots(Config[:verification_trust_roots])
  end

  # Samostatné kořeny důvěry pro časová razítka.
  def self.tsa_trust_roots
    load_roots(Config[:tsa_trust_roots])
  end

  def self.load_roots(paths)
    paths = paths.split(',') if paths.is_a?(String)
    files = Array(paths).map { |path| path.to_s.strip }.reject(&:blank?)

    files.flat_map do |path|
      unless File.file?(path)
        warn_missing_root(path)
        next []
      end

      OpenSSL::X509::Certificate.load_file(path)
    end
  end
  private_class_method :load_roots

  # Cesta v seznamu je závazek: soubor, který se nenačetl, se nesmí ztratit.
  # Jinak překlep ve `QES_TRUST_ROOTS` vypadá stejně jako "žádné kořeny"
  # a podpis selže na `not_trusted` bez stopy po příčině (issue #8).
  def self.warn_missing_root(path)
    @warned_missing_roots ||= Set.new
    return unless @warned_missing_roots.add?(path)

    Rails.logger&.warn("[qes] trust root file not found: #{path}")
  end
  private_class_method :warn_missing_root

  # Pole šablony submissionu. U submissions vytvořených z UI bývá `template_fields`
  # prázdné (plní se až při odeslání formuláře) — stejný fallback jako upstream
  # (`submission.template_fields || submission.template.fields`).
  def self.template_fields(submission)
    submission.template_fields.presence || submission.template&.fields || []
  end

  # Pole šablony podle uuid (a volitelně submittera); používá controller i model.
  def self.template_field(submission, uuid, submitter_uuid: nil)
    template_fields(submission).find do |field|
      field['uuid'] == uuid && (submitter_uuid.nil? || field['submitter_uuid'] == submitter_uuid)
    end
  end

  # Povinné QES pole zmrazená při vzniku submissionu. `template_fields` je
  # snapshot, který se nemění přidáním pole do šablony ani změnou `required`
  # přes API; `nil` je jen u starých submissions bez snapshotu (N1).
  def self.required_qes_fields(submission)
    fields = submission.template_fields.nil? ? (submission.template&.fields || []) : submission.template_fields

    fields.select { |field| field['type'] == 'qes' && field['required'] }
  end

  def self.missing_required_sessions(submitter)
    fields = required_qes_fields(submitter.submission)
    return [] if fields.empty?

    sessions = submitter.qes_sessions.completed.to_a

    fields.select do |field|
      next unless field['submitter_uuid'] == submitter.uuid

      sessions.none? { |session| session.field_uuid == field['uuid'] && session_satisfies_level?(session, field) }
    end
  end

  def self.session_satisfies_level?(session, field)
    required = field.dig('preferences', 'level').presence || 'ades'

    %w[ades qes].include?(required) &&
      (session.level == 'qes' || (required == 'ades' && session.level == 'ades'))
  end

  def self.template_schema(submission)
    submission.template_schema.presence || submission.template&.schema || []
  end

  # Cesty, které posílají multipart i přes `/api` prefix (SPEC § 5.8, docs/15, docs/16).
  MULTIPART_PATHS = %w[/qes/documents /qes/verify /qes/verified_documents].freeze

  def self.multipart_path?(path)
    MULTIPART_PATHS.any? { |suffix| path.to_s.end_with?(suffix) }
  end

  # Bezpečné logování bez osobních údajů (SPEC § 7.9).
  def self.log(session, message = nil)
    parts = ["[qes]", "session=#{session.id}", "submission=#{session.submission_id}",
             "submitter=#{session.submitter_id}", "state=#{session.state}"]
    parts << "level=#{session.level}" if session.level.present?
    parts << "code=#{session.failure_code}" if session.failure_code.present?
    parts << message if message
    Rails.logger.info(parts.join(' '))
  end
end
