class UserVillage < ApplicationRecord
    self.table_name = :user_villages
    self.primary_key = :user_village_id


    belongs_to :user, foreign_key: :user_id
    belongs_to :village, foreign_key: :village_id 

end