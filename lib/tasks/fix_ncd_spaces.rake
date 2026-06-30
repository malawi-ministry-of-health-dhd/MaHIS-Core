# frozen_string_literal: true

namespace :ncd_identifiers do
  desc 'List NCD identifiers with spaces and confirm before fixing them'
  task fix_spaces_interactive: :environment do
    # Fetch identifiers with spaces
    records = PatientIdentifier.where(identifier_type: 31).where("identifier LIKE ?", "% %")

    if records.empty?
      puts "No NCD identifiers with spaces found. Everything is clean!"
      next
    end

    puts "\nFound #{records.count} NCD identifiers with spaces:"
    puts "----------------------------------------"
    records.each do |record|
      old_val = record.identifier
      new_val = old_val.gsub(/\s+/, "")
      puts "ID: #{record.id} | Current: '#{old_val}' => Proposed: '#{new_val}'"
    end
    puts "----------------------------------------"

    print "\nDo you want to apply these fixes? (y/N): "
    response = $stdin.gets.strip.downcase

    if response == 'y' || response == 'yes'
      puts "\nApplying fixes..."
      ActiveRecord::Base.transaction do
        records.each do |record|
          old_val = record.identifier
          new_val = old_val.gsub(/\s+/, "")
          record.update!(identifier: new_val)
          puts "Updated Record ##{record.id}: '#{old_val}' -> '#{new_val}'"
        end
      end
      puts "Fix applied successfully!"
    else
      puts "Cancelled. No changes made."
    end
  end
end
