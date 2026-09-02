# frozen_string_literal: true

# user_villages carried nothing but its PRIMARY key, so every lookup of "which
# villages does this user cover" was a full table scan. That query now runs on
# every login (the assigned-area tree in the login payload), so the table needs
# the index it never had. Retired is in the key because every caller filters on
# it -- the active set is the only one anybody reads.
class AddUserIdIndexToUserVillages < ActiveRecord::Migration[8.1]
  def change
    return if index_exists?(:user_villages, %i[user_id retired])

    add_index :user_villages, %i[user_id retired], name: 'index_user_villages_on_user_id_and_retired'
  end
end
