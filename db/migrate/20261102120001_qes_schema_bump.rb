# frozen_string_literal: true

# No-op migrace: po rebase/merge schematu posune verzi o jedna vys, aby se
# na existujicim deploymentu provedla migrace a schema_migrations se srovnalo
# se schematem. Nemění žádnou tabulku.
class QesSchemaBump < ActiveRecord::Migration[8.1]
  def change; end
end
