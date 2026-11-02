# frozen_string_literal: true

module Qes
  # TBS PDF: základ (šablona, nebo finální PDF předchozího signera) + podpisové
  # pole s rezervou `/Contents` (SPEC § 7.1). Pole má viditelný widget na místě
  # pole `qes`; jeho appearance stream kreslí `Qes::Stamp` (SPEC § 16 #8).
  #
  # Řetězení (SPEC § 4.6): další QES signer MUSÍ podepsat finální PDF
  # předchozího signera jako novou inkrementální revizi; dokument se NESMÍ
  # přestavovat (import stránek by zahodil předchozí podpisy).
  module TbsDocument
    # Handler pro TBS PDF: rezervuje `/Contents` a nechá signaturu prázdnou.
    class TbsHandler < HexaPDF::DigitalSignature::Signing::DefaultHandler
    end

    module_function

    def build(submitter, field = nil, identity:, signature_size: nil, manifest: nil)
      manifest ||= document_manifest(submitter)
      base = chained_base(submitter)
      offsets = page_offsets(submitter.submission, manifest:)
      stamp = { field:, identity:, locale: submitter.account.locale, offsets:, submitter: }

      if base
        validate_page_count!(base, manifest)
        # Hodnoty aktuálního signera + jeho pečeť se dokreslí do podepsaného
        # základu v nové revizi; podpisové pole se přidá inkrementálně.
        # `generate_pdfs` vrací index dokumentů (všechny hodnoty = `base`), takže
        # se používají přímo — ne kvůli side effectu mutace.
        pdfs = Submissions::GenerateResultAttachments.generate_pdfs(
          submitter, base: base, page_offsets: offsets
        )
        base = pdfs.values.first || base

        sign(base, signature_size, stamp:)
      else
        pdf = merged_document(submitter)
        validate_page_count!(pdf, manifest)

        sign(pdf, signature_size, stamp:)
      end
    end

    # Rezerva `/Contents` je `signature_size` (SPEC § 7.1); bez ní minimum
    # z konfigurace (TBS z fixtures a testů).
    # `stamp` popisuje pole `qes` (`field`), identitu pečeti a `page_offsets`.
    def sign(pdf, signature_size = nil, stamp: nil)
      signature_field = stamp && signature_field(pdf, **stamp)
      io = StringIO.new
      pdf.config['signature.signing_handler'][:qes_tbs] = TbsHandler

      pdf.sign(io, handler: :qes_tbs,
                    signature: signature_field,
                    signature_size: (signature_size || Qes::Config[:signature_min_size]).to_i,
                    signature_type: :pades,
                    external_signing: ->(_io, _byte_range) { ''.b },
                    write_options: { validate: false })
      io.string
    end

    # Podpisové pole s viditelným widgetem na místě pole `qes`; appearance
    # stream je součástí TBS, takže ho podpis kryje. Bez plochy pole
    # vrací `nil` a `Signatures#add` vytvoří neviditelné pole.
    def signature_field(pdf, field:, identity:, locale:, offsets: {}, submitter: nil)
      level = field&.dig('preferences', 'level')
      page, rect = Qes::Stamp.placement(pdf, field, identity:, locale:, level:, offsets:)
      return if page.nil?

      update_area!(submitter, field, page, rect) if submitter

      form = pdf.acro_form(create: true)
      signature_field = form.create_signature_field(next_field_name(form))
      Qes::Stamp.draw(signature_field.create_widget(page, Rect: rect), identity, locale:, level:)
      signature_field
    end

    # Pole `qes` v submissionu se zvětší na efektivní plochu pečeti, aby náhled
    # (`submission.template_fields`) seděl s PDF. Levý horní roh zůstává.
    def update_area!(submitter, field, page, rect)
      submission = submitter.submission
      return unless submission&.persisted?

      fields = submission.template_fields || submission.template&.fields
      return if fields.blank? || field.blank?

      area = field.dig('areas', 0)
      attachment_uuid = area&.dig('attachment_uuid') ||
                        submission.schema_documents.first&.uuid ||
                        submission.template&.schema&.first&.dig('attachment_uuid')
      return if attachment_uuid.blank?

      page_width = page.box.width
      page_height = page.box.height
      x1, y1, x2, y2 = rect
      updated_area = (area || { 'page' => 0, 'attachment_uuid' => attachment_uuid }).merge(
        'x' => x1 / page_width,
        'y' => (page_height - y2) / page_height,
        'w' => (x2 - x1) / page_width,
        'h' => (y2 - y1) / page_height
      )
      updated_fields = fields.map do |item|
        next item unless item['uuid'] == field['uuid']

        item.merge('areas' => [updated_area, *Array(item['areas']).drop(1)])
      end
      return if updated_fields == fields

      submission.update_columns(template_fields: updated_fields)
    end

    # Stejné číslování polí jako `HexaPDF::DigitalSignature::Signatures#generate_field_name`.
    def next_field_name(form)
      indexes = form.each_field.map { |item| item.full_field_name.to_s[/\ASignature(\d+)/, 1].to_i }

      "Signature#{indexes.max.to_i + 1}"
    end

    # Finální PDF posledního dokončeného podpisu téhož podepisujícího, jinak
    # finální PDF posledního dokončeného non-viewer podepisujícího, jinak `nil`
    # (první signer staví ze šablony). Vlastní session má přednost: stejná
    # osoba může podepsat víc polí (SPEC § 4.6), druhý podpis se musí řetězit
    # na její první finální PDF, ne na PDF předchozího podepisujícího.
    def chained_session(submitter)
      own = QesSession.completed.where(submitter_id: submitter.id).order(:id).last
      return own if own

      previous = submitter.submission.submitters.reject(&:viewer?)
                          .select(&:completed_at?).max_by(&:completed_at)
      previous && QesSession.completed.where(submitter_id: previous.id).order(:id).last
    end

    def chained_base(submitter)
      pdf_from(chained_session(submitter))
    end

    def pdf_from(session)
      return nil unless session&.final_document&.attached?

      HexaPDF::Document.new(io: StringIO.new(session.final_document.download))
    end

    # Globální index první stránky přílohy v základu (SPEC § 4.6): podpis pokrývá
    # spojený dokument, ale `areas[].page` je per-příloha. Metadata
    # `pdf.number_of_pages` jsou bez stahování souborů.
    # Digest finálního PDF předchozí revize; bereme přesné bajty, ne
    # re-serializovaný HexaPDF dokument (ten může mít jiné /ID).
    def chained_base_bytes(submitter)
      session = chained_session(submitter)
      return unless session&.final_document&.attached?

      session.final_document.download
    end

    def base_digest(submitter)
      bytes = chained_base_bytes(submitter)
      bytes && Digest::SHA256.hexdigest(bytes)
    end

    def document_manifest(submitter)
      submission = submitter.submission
      values = submission.submitters.reduce({}) { |acc, signer| acc.merge(signer.values) }
      current = manifest_for(submission, values: values.merge(submitter.values))
      previous = chained_session(submitter)
      return current unless previous

      stored = previous.tbs_document&.blob&.metadata&.fetch('qes_document_manifest', nil)
      unless stored == current
        raise ClientError.new(:document_set_changed, 'Document set differs from the first signed revision')
      end

      stored
    end

    def validate_page_count!(pdf, manifest)
      return if pdf.pages.size == manifest.sum { |item| item['page_count'] }

      raise ClientError.new(:document_set_changed, 'PDF page count differs from the document manifest')
    end

    def manifest_for(submission, values: nil)
      Submissions.filtered_conditions_schema(submission, values:).map do |item|
        attachment = submission.schema_documents.find { |document| document.uuid == item['attachment_uuid'] }
        { 'attachment_uuid' => item['attachment_uuid'], 'page_count' => page_count(attachment) }
      end
    end

    def page_offsets(submission, manifest: manifest_for(submission))
      offset = 0
      manifest.each_with_object({}) do |item, offsets|
        offsets[item['attachment_uuid']] = offset
        offset += item['page_count']
      end
    end

    def page_count(attachment)
      count = attachment&.metadata&.dig('pdf', 'number_of_pages').to_i
      return count if count.positive?

      [attachment&.preview_images&.size.to_i, 1].max
    end

    # Sloučí stránky dokumentů šablony (vyplněná pole, bez `qes` hodnoty a bez pečeti).
    def merged_document(submitter)
      Submissions::GenerateCombinedAttachment.build_combined_pdf(submitter, with_audit: false)
    end

    # Vrátí data pokrytá `/ByteRange` podpisu (to, co se podepisuje).
    def signed_data(io, byte_range)
      raise ClientError.new(:invalid_pdf, 'Missing signature byte range') if byte_range.nil?

      byte_range.each_slice(2).map do |offset, length|
        io.seek(offset)
        io.read([length, io.size - offset].min)
      end.join
    end

    def byte_range(pdf_bytes)
      doc = HexaPDF::Document.new(io: StringIO.new(pdf_bytes))
      signature = doc.signatures.to_a.find { |sig| doc.revisions.current.object(sig) == sig }

      range = signature&.[](:ByteRange)&.value&.map(&:to_i)
      raise ClientError.new(:invalid_pdf, 'Missing signature byte range') if range.nil?

      range
    end

    # The app contract always uses SHA-256, independently of the CMS algorithm.
    def document_digest(pdf_bytes)
      range = byte_range(pdf_bytes)
      return nil if range.blank?

      Digest::SHA256.hexdigest(signed_data(StringIO.new(pdf_bytes), range))
    end
  end
end
