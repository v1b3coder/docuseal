# frozen_string_literal: true

module Qes
  # Endpointy pro appku (SPEC § 5): autentizace jednorázovým tokenem v cestě,
  # v DB je jen sha256. Token se nikdy neloguje.
  class SessionsController < ApplicationController
    include Qes::ControllerConcern

    skip_before_action :authenticate_user!
    skip_authorization_check
    skip_before_action :maybe_redirect_to_setup
    protect_from_forgery with: :null_session

    before_action :check_rate_limit
    before_action :load_session

    def show
      return render_qes_error_with(:expired_token, :gone) if @session.expired?
      return render json: completed_payload if @session.state == 'completed'
      return render_qes_error_with(:used_token, :gone) if @session.terminal?

      if @session.state == 'awaiting_app'
        Qes::SessionManager.transition!(@session, 'app_opened')
        Qes.log(@session)
      end

      render json: payload
    end

    def document
      return render_qes_error_with(:used_token, :gone) if @session.terminal?
      return render_qes_error_with(:expired_token, :gone) if @session.expired?
      unless @session.state.in?(%w[awaiting_app app_opened awaiting_signature])
        return render_qes_error_with(:wrong_state, :conflict)
      end

      # TBS se staví před certifikátem; appka tak může zobrazit přesně ty
      # bajty, které se budou podepisovat, a klíč se odemyká až po kontrole.
      if !@session.tbs_document.attached? && @session.state == 'awaiting_signature'
        return render_qes_error_with(:document_missing, :conflict)
      end

      provider_for(@session).prepare_document unless @session.tbs_document.attached?
      return render_qes_error_with(:document_missing, :conflict) unless @session.tbs_document.attached?

      extend_expiry!(Qes::Config[:review_ttl])

      response.set_header('Cache-Control', 'no-store')
      send_data @session.tbs_document.download, type: 'application/pdf', disposition: 'inline',
                                                filename: "qes-tbs-#{@session.id}.pdf"
    end

    def certificate
      return render_qes_error_with(:used_token, :gone) if @session.terminal?
      return render_qes_error_with(:expired_token, :gone) if @session.expired?

      certificate_der = decode_certificate(params[:certificate])
      chain = Array(params[:chain]).compact_blank.map { |der| decode_certificate(der) }
      if chain.size > MAX_CHAIN
        raise Qes::ClientError.new(:invalid_certificate, 'Certificate chain is too long')
      end
      key_location = params[:key_location].presence || 'phone_keystore'

      if @session.state == 'awaiting_signature'
        return render_qes_error_with(:wrong_state, :conflict) unless same_certificate?(certificate_der)

        extend_expiry!(Qes::Config[:session_ttl])
        return render json: certificate_payload
      end

      return render_qes_error_with(:wrong_state, :conflict) unless @session.state.in?(%w[awaiting_app app_opened])

      provider = provider_for(@session)
      info = Qes::CertificateInfo.parse(certificate_der)
      # Nejdřív platnost/úroveň certifikátu, pak řetěz: expirovaný certifikát
      # musí vrátit certificate_expired, ne not_trusted (N3).
      info.validate!(level_required: @session.level_required, key_location:)
      certificate = info.certificate
      # Revokace i DSS jdou z ověřeného řetězu, ne z certů od klienta (#19).
      chain = Qes::Validator.verify_chain!(certificate, chain, provider.trust_roots).drop(1).map(&:to_der)

      # CRL fetch (síť) mimo DB transakci; transakce pak drží jen zápis (M20).
      crls = Qes::Ltv.fetch_crls(certificate_der, chain:)

      provider.data_to_sign(certificate_der, chain:, key_location:,
                                            app_metadata: app_metadata_param,
                                            crls: crls || [])
      extend_expiry!(Qes::Config[:session_ttl])

      Qes.log(@session)

      render json: certificate_payload
    rescue Qes::ClientError => e
      QesSession.where(id: @session.id).update_all(failure_code: e.code.to_s)
      @session.reload

      render_qes_error(e)
    end

    def complete
      return render_qes_error_with(:used_token, :gone) if @session.terminal? && @session.state != 'completed'
      return render_qes_error_with(:expired_token, :gone) if @session.expired?

      signature = decode(params[:signature], :signature_invalid)

      if @session.state == 'completed'
        return render json: completed_payload if same_signature?(signature)

        # Opakované `POST /complete` s jinou signaturou nesmí projít (SPEC § 7.10).
        return render_qes_error_with(:wrong_state, :conflict)
      end

      return render_qes_error_with(:wrong_state, :conflict) unless @session.state == 'awaiting_signature'
      # Archivace/expirace během obřadu: podpis se nesmí vložit do mrtvého dokumentu
      # (nová revize by zůstala bez dokončení). Guard je před modifikací PDF.
      return if reject_inactive_submission(@session.submission)

      # Synchronně v requestu (lokální CRL/TSA) — appka dostane rovnou `completed`;
      # `complete!` je idempotentní (`with_lock` + stav), takže není potřeba job.
      Qes::Providers::MobileApp.new(@session).complete!(signature)
      @session.reload

      render json: completed_payload
    rescue Qes::ClientError => e
      if e.code == :seal_failed
        QesSession.where(id: @session.id, state: 'awaiting_signature')
                  .update_all(failure_code: e.code.to_s, failure_message: e.message)
        Qes.log(@session.reload)
      else
        fail_session(e)
      end

      render_qes_error_with(e.code, :unprocessable_content)
    end

    # Dokončení submissionu vázané na session token (S1). Appka nesmí
    # dokončovat cizí submitter plným API tokenem účtu.
    def complete_submission
      return render_qes_error_with(:used_token, :gone) if @session.terminal? && @session.state != 'completed'
      return render_qes_error_with(:expired_token, :gone) if @session.expired?
      return render_qes_error_with(:wrong_state, :conflict) unless @session.state == 'completed'
      # Podpis už je v PDF; dokončit ho smí jen u aktivní submission (#14).
      return if reject_inactive_submission(@session.submission)

      submitter = @session.submitter
      Submitters::SubmitValues.call(submitter, ActionController::Parameters.new(completed: 'true'), request) unless submitter.completed_at?

      render json: { state: @session.state, submitter_id: submitter.id,
                     completed: submitter.completed_at.present? }
    rescue Submitters::SubmitValues::ValidationError, Submitters::SubmitValues::RequiredFieldError => e
      render_qes_error_with(:completion_failed, :unprocessable_content)
    end

    def abort
      return render_qes_error_with(:used_token, :gone) if @session.terminal?
      return render_qes_error_with(:expired_token, :gone) if @session.expired?

      code = params[:code].presence || 'cancelled'
      new_state = code == 'user_cancelled' ? 'cancelled' : 'failed'

      QesSession.transaction do
        # `failure_code` je kód z appky (SPEC § 5.7), `state` stav automatu;
        # dřív se `network_error` zapsal jako `cancelled`.
        Qes::SessionManager.transition!(@session, new_state, failure_code: code,
                                                          failure_message: params[:message].presence)
      end

      Qes.log(@session)

      render json: { state: @session.state }
    end

    private

    def load_session
      token = params[:token].to_s

      @session = Qes::Token.find(token)

      if @session.nil?
        Qes::RateLimiter.record_failure!(request.remote_ip)

        return render_qes_error_with(:unknown_token, :not_found)
      end

      response.set_header('X-QES-Protocol', '1')
      response.set_header('Referrer-Policy', 'no-referrer')

      @session
    end

    def check_rate_limit
      Qes::RateLimiter.check!(request.remote_ip, token: params[:token])
    end

    def provider_for(session)
      Qes::Providers::MobileApp.new(session)
    end

    # `app` je self-reported metadata z appky (SPEC § 5.4): do auditní stránky
    # jdou jen platforma a reálná verze. Cokoli jiného se zahodí, protože text
    # končí v PDF a nesmí tam projít libovolný řetězec z klienta.
    APP_PLATFORMS = %w[android ios].freeze
    APP_VERSION = /\A[0-9A-Za-z][0-9A-Za-z._+-]{0,31}\z/

    def app_metadata_param
      app = params[:app]
      return nil unless app.respond_to?(:permit)

      permitted = app.permit(:platform, :version)
      platform = permitted[:platform].to_s.downcase
      version = permitted[:version].to_s.strip
      metadata = {}
      metadata['platform'] = platform if APP_PLATFORMS.include?(platform)
      metadata['version'] = version if version.match?(APP_VERSION)

      metadata.presence
    end

    # Absolutní strop (SPEC § 5.1a): prodloužení nesmí přelézt `created_at + QES_SESSION_MAX_TTL`,
    # jinak klient s tokenem drží session naživo libovolně dlouho (#23.4).
    def extend_expiry!(ttl)
      cap = @session.created_at + Qes::Config[:session_max_ttl].to_i.seconds

      @session.update!(expires_at: [Time.current + ttl.to_i.seconds, cap].min)
    end

    def same_certificate?(certificate_der)
      stored = @session.certificate_chain&.first
      return false if stored.blank?

      OpenSSL::X509::Certificate.new(certificate_der).to_der == Base64.decode64(stored)
    rescue OpenSSL::X509::CertificateError
      false
    end

    def same_signature?(signature)
      stored = @session.signature
      return false if stored.blank? || signature.blank?

      ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(stored),
                                                 Digest::SHA256.hexdigest(signature))
    end

    def payload
      submission = @session.submission

      {
        session_id: @session.id,
        state: @session.state,
        provider: @session.provider,
        document_name: submission.name.presence || submission.template&.name,
        signer_name: @session.submitter.name,
        hash_algorithm: @session.hash_algorithm,
        level_required: @session.level_required,
        submitter_id: @session.submitter_id,
        requires_certificate: @session.state.in?(%w[awaiting_app app_opened]),
        server_url: Qes::Link.origin(request),
        expires_at: @session.expires_at&.utc&.iso8601,
        values: Qes::ValueValidator.non_qes_values(@session.submitter.values, @session.submitter)
      }
    end

    def certificate_payload
      {
        data_to_sign: Base64.strict_encode64(@session.signed_attrs_der),
        hash_algorithm: @session.hash_algorithm,
        digest_algorithm_oid: Qes::CmsBuilder::DIGEST_ALGORITHM_OIDS.fetch(@session.hash_algorithm),
        signature_algorithm: @session.signature_algorithm,
        expires_at: @session.expires_at&.utc&.iso8601,
        certificate_info: @session.certificate_info,
        byte_range: Qes::TbsDocument.byte_range(@session.tbs_document.download),
        document_digest: @session.document_digest
      }
    end

    def completed_payload
      {
        state: @session.state,
        session_id: @session.id,
        level: @session.level,
        document_digest: @session.document_digest,
        signed_pdf_sha256: @session.signed_pdf_sha256,
        final_pdf_sha256: @session.final_pdf_sha256,
        seal_state: @session.seal_state,
        doc_timestamp_state: @session.doc_timestamp_state,
        signing_time: @session.signing_time&.utc&.iso8601,
        validation: @session.validation_report,
        revocation: @session.validation_report&.[]('revocation'),
        completed_at: @session.completed_at&.utc&.iso8601,
        submitter_id: @session.submitter_id
      }
    end

    def fail_session(error)
      QesSession.where(id: @session.id, state: Qes::SessionManager::ACTIVE_STATES)
                .update_all(failure_code: error.code.to_s, failure_message: error.message,
                            failed_at: Time.current, state: 'failed')
      @session.reload
      Qes.log(@session)
    end

  end
end
