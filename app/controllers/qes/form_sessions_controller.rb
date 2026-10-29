# frozen_string_literal: true

module Qes
  # Endpointy pro prohlížeč v podpisovém formuláři (SPEC § 6).
  class FormSessionsController < ApplicationController
    include Qes::ControllerConcern

    skip_before_action :authenticate_user!
    skip_authorization_check
    skip_before_action :maybe_redirect_to_setup

    before_action :load_submitter
    before_action :authorize_submitter

    # Appka spouští obřad s API tokenem (docs/15 § 5.1) — bez CSRF tokenu
    # a prohlížečové session (token je kapabilita, jako podpisový odkaz).
    skip_before_action :verify_authenticity_token, if: :api_token_user

    def create
      field = find_field
      return render_qes_error_with(:unknown_field, :not_found) if field.nil?
      return render_qes_error_with(:wrong_field_type, :unprocessable_content) unless field['type'] == 'qes'

      if @submitter.completed_at? || @submitter.declined_at? || inactive_submission?(@submitter.submission)
        return render_qes_error_with(:form_not_active, :gone)
      end

      # Řetězení PAdES vyžaduje striktní pořadí (SPEC § 4.6); formulář se sice
      # gateuje, ale přímý POST na endpoint musí odmítnout taky.
      unless Submitters.current_submitter_order?(@submitter)
        return render_qes_error_with(:awaiting_previous_signer, :conflict)
      end

      Qes::SigningValues.validate!(@submitter)

      completed = QesSession.completed_for(@submitter, field['uuid'])
      if completed
        return render json: { id: completed.id, state: 'completed', value: completed.value_token,
                             completed: true, expires_at: completed.expires_at&.utc&.iso8601 }
      end

      # Na jednu submission smí být připravená jen jedna podpisová revize;
      # jinak by dvě pole téhož submittera vytvořila dvě větve PDF (S3).
      # Prošlá session neblokuje: v `with_lock` se rovnou ukončí.
      in_progress = QesSession.live.where(submission_id: @submitter.submission_id,
                                         state: 'awaiting_signature').first
      if in_progress && (in_progress.submitter_id != @submitter.id || in_progress.field_uuid != field['uuid'])
        return render_signature_in_progress(in_progress)
      end

      session = nil
      token = nil

      # Serializuje tvorbu session; stav všech sessions submission se kontroluje
      # pod zámkem. Předkontrola výše je jen rychlá cesta — mezi ní a zámkem
      # může jiné pole přejít do `awaiting_signature`.
      @submitter.submission.with_lock do
        conflict = nil

        QesSession.active.where(submission_id: @submitter.submission_id).find_each do |active|
          active.with_lock do
            if stale?(active)
              expire_stale!(active)
            elsif active.state == 'awaiting_signature' && active.field_uuid == field['uuid']
              session = active
            elsif active.submitter_id == @submitter.id && active.state.in?(%w[awaiting_app app_opened])
              Qes::SessionManager.transition!(active, 'cancelled')
            else
              conflict ||= active
            end
          end
        end

        session ||= conflict
        next if session

        session = QesSession.create!(account: @submitter.account, submission: @submitter.submission,
                                     submitter: @submitter, field_uuid: field['uuid'],
                                     provider: 'mobile_app')

        Qes::SessionManager.transition!(session, 'prepared')

        token = Qes::Token.generate
        session.update!(token_digest: Qes::Token.digest(token),
                        expires_at: Qes::Config[:session_ttl].to_i.seconds.from_now)

        Qes::SessionManager.transition!(session, 'awaiting_app')
      end

      Qes.log(session)

      return render_signature_in_progress(session) if token.nil?

      link = Qes::Link.call(request, '/qes/sign', token)
      custom_scheme_link = Qes::Link.custom_scheme(request, token)

      render json: {
        id: session.id,
        state: session.state,
        token:,
        universal_link: link,
        # Android App Links zrušeny (#18.1) — QR míří na custom scheme, appku
        # vybírá systémový chooser.
        qr_svg: RQRCode::QRCode.new(custom_scheme_link, level: :m).as_svg(
          viewbox: true, svg_attributes: { width: 220, height: 220 }
        ),
        fallback_url: Qes::Link.call(request, '/qes/app', token),
        custom_scheme_link:,
        expires_at: session.expires_at.utc.iso8601,
        poll_interval_ms: 2000
      }, status: :created
    rescue ActiveRecord::RecordNotUnique
      # SQLite nemá skutečný řádkový zámek; souběh tam zachytí až unikátní
      # index. Odpověď musí být stejná jako z předkontroly.
      render_signature_in_progress(QesSession.active.where(submission_id: @submitter.submission_id).first)
    end

    def show
      session = @submitter.qes_sessions.find_by(id: params[:id])

      return render_qes_error_with(:unknown_session, :not_found) if session.nil?

      # Prošlá aktivní session se hlásí jako `expired`, aby prohlížeč
      # nečekal do timeoutu na stav, který už nikdy nepřijde. Terminální
      # stavy (`failed`, `cancelled`) si nesou vlastní chybový kód.
      state = session.state
      state = 'expired' if Qes::SessionManager.active?(state) && session.expired?

      render json: {
        id: session.id,
        state:,
        value: session.state == 'completed' ? session.value_token : nil,
        error: session.failure_code.present? ? { code: session.failure_code,
                                                message: session.failure_message } : nil,
        completed: session.state == 'completed'
      }.merge(completed_details(session))
    end

    def cancel
      session = @submitter.qes_sessions.find_by(id: params[:id])

      return render_qes_error_with(:unknown_session, :not_found) if session.nil?

      session.with_lock do
        if Qes::SessionManager.active?(session.state)
          Qes::SessionManager.transition!(session, 'cancelled')
        end
      end

      Qes.log(session)

      render json: { state: session.state }
    end

    private

    def load_submitter
      @submitter = Submitter.find_by(slug: params[:submit_form_slug])
    end

    def authorize_submitter
      return if @submitter && Submitters::AuthorizedForForm.call(@submitter, current_user || api_token_user, request)

      render_qes_error_with(:unauthorized, :not_found)
    end

    def api_token_user
      token = request.headers['X-Auth-Token'].presence

      return if token.blank?

      @api_token_user ||= User.joins(:access_token).active.find_by(access_token: { sha256: Digest::SHA256.hexdigest(token) })
    end

    def find_field
      Qes.template_field(@submitter.submission, params[:field_uuid],
                          submitter_uuid: @submitter.uuid)
    end

    def stale?(session)
      session.expires_at.present? && session.expires_at <= Time.current
    end

    # Expirace pod zámkem: prošlá session nesmí blokovat novou. Job ji může
    # stihnout ukončit souběžně, proto `InvalidTransition` není chyba.
    def expire_stale!(session)
      Qes::SessionManager.transition!(session, 'expired', failure_code: 'expired')
    rescue Qes::InvalidTransition
      nil
    end

    def render_signature_in_progress(session)
      expires_at = session&.expires_at

      render json: { error: 'signature_in_progress', id: session&.id, session_id: session&.id,
                     state: session&.state, expires_at: expires_at&.utc&.iso8601,
                     poll_interval_ms: 2000 }, status: :conflict
    end

    # Metadata dokončeného podpisu pro přehled v podpisovém formuláři:
    # stejný HTML přehled jako v `submissions/qes_summary`.
    def completed_details(session)
      return {} unless session.state == 'completed'

      {
        seal_state: session.seal_state,
        doc_timestamp_state: session.doc_timestamp_state,
        # Prohlížeč potřebuje zmrazené hodnoty ostatních polí, aby po
        # dokončení neposlal změněné {{name}}/datum/vzorce (N6).
        values: Qes::ValueValidator.non_qes_values(session.submitter.values, session.submitter),
        # `renderer` má vždy HTML formát; `render_to_string` by v JSON
        # requestu hledal `icons/_circle_check.json` a spadl by na 500.
        summary_html: ApplicationController.renderer.render(partial: 'submit_form/qes_summary',
                                                          locals: { session:, compact: true })
      }
    end
  end
end
