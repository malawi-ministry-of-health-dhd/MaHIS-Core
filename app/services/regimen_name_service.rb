# frozen_string_literal: true

class RegimenNameService
  def find_all
    MohRegimenName.order(:name)
  end
end
