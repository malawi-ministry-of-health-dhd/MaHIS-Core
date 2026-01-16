load Rails.root.join('bin', 'remap', 'concepts_remap.rb')
load Rails.root.join('bin', 'remap', 'drugs_remap.rb')
load Rails.root.join('bin', 'remap', 'encounter_types_remap.rb')
load Rails.root.join('bin', 'remap', 'programs_remap.rb')
load Rails.root.join('bin', 'remap', 'order_types_remap.rb')
load Rails.root.join('bin', 'remap', 'patient_identifier_types_remap.rb')
load Rails.root.join('bin', 'remap', 'relationship_types_remap.rb')
load Rails.root.join('bin', 'remap', 'user_roles_remap.rb')
load Rails.root.join('bin', 'remap', 'person_attribute_types_remap.rb')
load Rails.root.join('bin', 'remap', 'meta.rb')

initialize_script
# remap_concepts
remap_drugs
remap_encounter_types
remap_programs
remap_order_types
remap_patient_identifier_types
remap_relationship_types
remap_user_roles
remap_person_attribute_types