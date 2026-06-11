class CachedReport
  include ArtTempTablesUtils

  def initialize(start_date:, end_date:, **kwargs)
    @start_date = start_date.to_date
    @end_date = end_date.to_date
    @org = kwargs[:definition]
    @rebuild = kwargs[:rebuild]&.casecmp?('true')
    @occupation = kwargs[:occupation]
    @report_type = @org&.downcase&.match(/pepfar/i) ? 'pepfar' : 'moh'
    find_or_initialize_cohort
  end

  def initialize_and_save_report
    ArtService::Reports::CohortBuilder
      .new(outcomes_definition: @report_type)
      .init_temporary_tables(@start_date, @end_date, @occupation, force_rebuild: @rebuild.present?)

    save_report
  end

  def save_report
    truncate_similar_reports

    Report.create(name: report_name,
                  start_date: @start_date,
                  end_date: @end_date,
                  type: ReportType.find_by_name('Cohort'),
                  creator: User.current.id,
                  renderer_type: 'PDF')
  end

  def truncate_similar_reports
    Report.where(
      type: ReportType.find_by_name('Cohort'),
      name: report_name,
      start_date: @start_date,
      end_date: @end_date
    ).destroy_all
  end

  def find_or_initialize_cohort
    initialize_and_save_report if @rebuild

    initialize_and_save_report unless report_saved? && all_temp_tables_are_ok?
  end

  def all_temp_tables_are_ok?
    # Use location-scoped table names to correctly check the actual tables in use
    cols = batch_column_counts(
      temp_cohort_members, temp_earliest_start_date, temp_other_patient_types,
      temp_register_start_date, temp_order_details, temp_art_start_date,
      temp_patient_tb_status, temp_latest_tb_status, tmp_max_adherence,
      temp_pregnant_obs, temp_patient_side_effects
    )
    cols[temp_cohort_members]         == 12 &&
      cols[temp_earliest_start_date]  == 11 &&
      cols[temp_other_patient_types]  == 1  &&
      cols[temp_register_start_date]  == 2  &&
      cols[temp_order_details]        == 2  &&
      cols[temp_art_start_date]       == 2  &&
      cols[temp_patient_tb_status]    == 2  &&
      cols[temp_latest_tb_status]     == 2  &&
      cols[tmp_max_adherence]         == 2  &&
      cols[temp_pregnant_obs]         == 3  &&
      cols[temp_patient_side_effects] == 2
  end

  def report_saved?
    last_saved_report = Report.where(
      type: ReportType.find_by_name('Cohort')
    ).last

    return false unless last_saved_report.present?

    last_saved_report.start_date.to_date == @start_date.to_date && last_saved_report.end_date.to_date == @end_date.to_date
  end

  private

  def report_name
    "Cohort~#{@start_date}~#{@end_date}"
  end
end
