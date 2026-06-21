# frozen_string_literal: true

require Rails.root.join('lib', 'reference_name_collation').to_s

# Restores case-insensitive matching on reference-table `name` columns.
#
# The TiDB import recreated these columns with case-sensitive `*_bin`
# collations, which broke the app's pervasive `find_by_name` lookups (the code
# uses one case, the metadata stores another). See ReferenceNameCollation.
class MakeReferenceNameColumnsCaseInsensitive < ActiveRecord::Migration[8.1]
  def up
    ReferenceNameCollation.enforce!(connection: connection)
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Reverting display-name columns to case-sensitive (*_bin) collations would ' \
          're-break find_by_name and LIKE lookups across the app.'
  end
end
