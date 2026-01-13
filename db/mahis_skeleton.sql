-- MySQL dump 10.13  Distrib 8.0.43, for Linux (x86_64)
--
-- Host: localhost    Database: openmrs_dev
-- ------------------------------------------------------
-- Server version	8.0.43

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!50503 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `active_list`
--

DROP TABLE IF EXISTS `active_list`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `active_list` (
  `active_list_id` int NOT NULL AUTO_INCREMENT,
  `active_list_type_id` int NOT NULL,
  `person_id` int NOT NULL,
  `concept_id` int NOT NULL,
  `start_obs_id` int DEFAULT NULL,
  `stop_obs_id` int DEFAULT NULL,
  `start_date` datetime NOT NULL,
  `end_date` datetime DEFAULT NULL,
  `comments` varchar(255) DEFAULT NULL,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL,
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `uuid` varchar(38) NOT NULL,
  PRIMARY KEY (`active_list_id`),
  KEY `active_list_type_of_active_list` (`active_list_type_id`),
  KEY `concept_active_list` (`concept_id`),
  KEY `user_who_created_active_list` (`creator`),
  KEY `person_of_active_list` (`person_id`),
  KEY `start_obs_active_list` (`start_obs_id`),
  KEY `stop_obs_active_list` (`stop_obs_id`),
  KEY `user_who_voided_active_list` (`voided_by`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `active_list_allergy`
--

DROP TABLE IF EXISTS `active_list_allergy`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `active_list_allergy` (
  `active_list_id` int NOT NULL AUTO_INCREMENT,
  `allergy_type` varchar(50) DEFAULT NULL,
  `reaction_concept_id` int DEFAULT NULL,
  `severity` varchar(50) DEFAULT NULL,
  PRIMARY KEY (`active_list_id`),
  KEY `reaction_allergy` (`reaction_concept_id`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `active_list_problem`
--

DROP TABLE IF EXISTS `active_list_problem`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `active_list_problem` (
  `active_list_id` int NOT NULL AUTO_INCREMENT,
  `status` varchar(50) DEFAULT NULL,
  `sort_weight` double DEFAULT NULL,
  PRIMARY KEY (`active_list_id`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `active_list_type`
--

DROP TABLE IF EXISTS `active_list_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `active_list_type` (
  `active_list_type_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(50) NOT NULL,
  `description` varchar(255) DEFAULT NULL,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL,
  `retired` smallint NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` varchar(38) NOT NULL,
  PRIMARY KEY (`active_list_type_id`),
  KEY `user_who_created_active_list_type` (`creator`),
  KEY `user_who_retired_active_list_type` (`retired_by`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `all_patient_identifiers`
--

DROP TABLE IF EXISTS `all_patient_identifiers`;
/*!50001 DROP VIEW IF EXISTS `all_patient_identifiers`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `all_patient_identifiers` AS SELECT 
 1 AS `patient_id`,
 1 AS `openmrs_ident_type`,
 1 AS `national_id`,
 1 AS `arv_number`,
 1 AS `legacy_id`,
 1 AS `prev_art_number`,
 1 AS `tb_number`,
 1 AS `filing_number`,
 1 AS `archived_filing_number`,
 1 AS `pre_art_number`*/;
SET character_set_client = @saved_cs_client;

--
-- Temporary view structure for view `all_patients_attributes`
--

DROP TABLE IF EXISTS `all_patients_attributes`;
/*!50001 DROP VIEW IF EXISTS `all_patients_attributes`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `all_patients_attributes` AS SELECT 
 1 AS `person_id`,
 1 AS `occupation`,
 1 AS `cell_phone`,
 1 AS `home_phone`,
 1 AS `office_phone`*/;
SET character_set_client = @saved_cs_client;

--
-- Temporary view structure for view `all_person_addresses`
--

DROP TABLE IF EXISTS `all_person_addresses`;
/*!50001 DROP VIEW IF EXISTS `all_person_addresses`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `all_person_addresses` AS SELECT 
 1 AS `person_address_id`,
 1 AS `person_id`,
 1 AS `preferred`,
 1 AS `address1`,
 1 AS `address2`,
 1 AS `city_village`,
 1 AS `state_province`,
 1 AS `postal_code`,
 1 AS `country`,
 1 AS `latitude`,
 1 AS `longitude`,
 1 AS `creator`,
 1 AS `date_created`,
 1 AS `voided`,
 1 AS `voided_by`,
 1 AS `date_voided`,
 1 AS `void_reason`,
 1 AS `county_district`,
 1 AS `neighborhood_cell`,
 1 AS `region`,
 1 AS `subregion`,
 1 AS `township_division`,
 1 AS `uuid`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `alternative_drug_names`
--

DROP TABLE IF EXISTS `alternative_drug_names`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `alternative_drug_names` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `short_name` varchar(255) DEFAULT NULL,
  `drug_inventory_id` int NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `amount_brought_back_obs`
--

DROP TABLE IF EXISTS `amount_brought_back_obs`;
/*!50001 DROP VIEW IF EXISTS `amount_brought_back_obs`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `amount_brought_back_obs` AS SELECT 
 1 AS `person_id`,
 1 AS `encounter_id`,
 1 AS `order_id`,
 1 AS `obs_datetime`,
 1 AS `drug_inventory_id`,
 1 AS `equivalent_daily_dose`,
 1 AS `value_numeric`,
 1 AS `quantity`*/;
SET character_set_client = @saved_cs_client;

--
-- Temporary view structure for view `amount_dispensed_obs`
--

DROP TABLE IF EXISTS `amount_dispensed_obs`;
/*!50001 DROP VIEW IF EXISTS `amount_dispensed_obs`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `amount_dispensed_obs` AS SELECT 
 1 AS `person_id`,
 1 AS `encounter_id`,
 1 AS `order_id`,
 1 AS `obs_datetime`,
 1 AS `drug_inventory_id`,
 1 AS `equivalent_daily_dose`,
 1 AS `start_date`,
 1 AS `value_numeric`*/;
SET character_set_client = @saved_cs_client;

--
-- Temporary view structure for view `anc_visit_observations`
--

DROP TABLE IF EXISTS `anc_visit_observations`;
/*!50001 DROP VIEW IF EXISTS `anc_visit_observations`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `anc_visit_observations` AS SELECT 
 1 AS `person_id`,
 1 AS `encounter_id`,
 1 AS `value_numeric`,
 1 AS `encounter_datetime`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `ar_internal_metadata`
--

DROP TABLE IF EXISTS `ar_internal_metadata`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `ar_internal_metadata` (
  `key` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `value` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `arv_drug`
--

DROP TABLE IF EXISTS `arv_drug`;
/*!50001 DROP VIEW IF EXISTS `arv_drug`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `arv_drug` AS SELECT 
 1 AS `drug_id`*/;
SET character_set_client = @saved_cs_client;

--
-- Temporary view structure for view `arv_drugs_orders`
--

DROP TABLE IF EXISTS `arv_drugs_orders`;
/*!50001 DROP VIEW IF EXISTS `arv_drugs_orders`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `arv_drugs_orders` AS SELECT 
 1 AS `patient_id`,
 1 AS `encounter_id`,
 1 AS `concept_id`,
 1 AS `start_date`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `audits`
--

DROP TABLE IF EXISTS `audits`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `audits` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `auditable_id` int DEFAULT NULL,
  `auditable_type` varchar(255) DEFAULT NULL,
  `associated_id` int DEFAULT NULL,
  `associated_type` varchar(255) DEFAULT NULL,
  `user_id` int DEFAULT NULL,
  `user_type` varchar(255) DEFAULT NULL,
  `username` varchar(255) DEFAULT NULL,
  `action` varchar(255) DEFAULT NULL,
  `audited_changes` text,
  `version` int DEFAULT '0',
  `comment` varchar(255) DEFAULT NULL,
  `remote_address` varchar(255) DEFAULT NULL,
  `request_uuid` varchar(255) DEFAULT NULL,
  `created_at` datetime(6) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `associated_index` (`associated_type`,`associated_id`),
  KEY `auditable_index` (`auditable_type`,`auditable_id`,`version`),
  KEY `index_audits_on_created_at` (`created_at`),
  KEY `index_audits_on_request_uuid` (`request_uuid`),
  KEY `user_index` (`user_id`,`user_type`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `clinic_consultation_encounter`
--

DROP TABLE IF EXISTS `clinic_consultation_encounter`;
/*!50001 DROP VIEW IF EXISTS `clinic_consultation_encounter`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `clinic_consultation_encounter` AS SELECT 
 1 AS `encounter_id`,
 1 AS `encounter_type`,
 1 AS `patient_id`,
 1 AS `provider_id`,
 1 AS `location_id`,
 1 AS `form_id`,
 1 AS `encounter_datetime`,
 1 AS `creator`,
 1 AS `date_created`,
 1 AS `voided`,
 1 AS `voided_by`,
 1 AS `date_voided`,
 1 AS `void_reason`,
 1 AS `uuid`,
 1 AS `changed_by`,
 1 AS `date_changed`*/;
SET character_set_client = @saved_cs_client;

--
-- Temporary view structure for view `clinic_registration_encounter`
--

DROP TABLE IF EXISTS `clinic_registration_encounter`;
/*!50001 DROP VIEW IF EXISTS `clinic_registration_encounter`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `clinic_registration_encounter` AS SELECT 
 1 AS `encounter_id`,
 1 AS `encounter_type`,
 1 AS `patient_id`,
 1 AS `provider_id`,
 1 AS `location_id`,
 1 AS `form_id`,
 1 AS `encounter_datetime`,
 1 AS `creator`,
 1 AS `date_created`,
 1 AS `voided`,
 1 AS `voided_by`,
 1 AS `date_voided`,
 1 AS `void_reason`,
 1 AS `uuid`,
 1 AS `changed_by`,
 1 AS `date_changed`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `cohort`
--

DROP TABLE IF EXISTS `cohort`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `cohort` (
  `cohort_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `description` varchar(1000) DEFAULT NULL,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL,
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`cohort_id`),
  UNIQUE KEY `cohort_uuid_index` (`uuid`),
  KEY `cohort_creator` (`creator`),
  KEY `user_who_voided_cohort` (`voided_by`),
  KEY `user_who_changed_cohort` (`changed_by`),
  CONSTRAINT `cohort_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_changed_cohort` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_voided_cohort` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `cohort_drill_down`
--

DROP TABLE IF EXISTS `cohort_drill_down`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `cohort_drill_down` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `reporting_report_design_resource_id` int NOT NULL,
  `patient_id` int NOT NULL,
  PRIMARY KEY (`id`),
  KEY `drilldown_report_value` (`reporting_report_design_resource_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `cohort_member`
--

DROP TABLE IF EXISTS `cohort_member`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `cohort_member` (
  `cohort_id` int NOT NULL DEFAULT '0',
  `patient_id` int NOT NULL DEFAULT '0',
  PRIMARY KEY (`cohort_id`,`patient_id`),
  KEY `cohort` (`cohort_id`),
  KEY `patient` (`patient_id`),
  CONSTRAINT `member_patient` FOREIGN KEY (`patient_id`) REFERENCES `patient` (`patient_id`) ON UPDATE CASCADE,
  CONSTRAINT `parent_cohort` FOREIGN KEY (`cohort_id`) REFERENCES `cohort` (`cohort_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `complex_obs`
--

DROP TABLE IF EXISTS `complex_obs`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `complex_obs` (
  `obs_id` int NOT NULL DEFAULT '0',
  `mime_type_id` int NOT NULL DEFAULT '0',
  `urn` text,
  `complex_value` longtext,
  PRIMARY KEY (`obs_id`),
  KEY `mime_type_of_content` (`mime_type_id`),
  CONSTRAINT `complex_obs_ibfk_1` FOREIGN KEY (`mime_type_id`) REFERENCES `mime_type` (`mime_type_id`),
  CONSTRAINT `obs_pointing_to_complex_content` FOREIGN KEY (`obs_id`) REFERENCES `obs` (`obs_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept`
--

DROP TABLE IF EXISTS `concept`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept` (
  `concept_id` int NOT NULL AUTO_INCREMENT,
  `retired` smallint NOT NULL DEFAULT '0',
  `short_name` varchar(255) DEFAULT NULL,
  `description` text,
  `form_text` text,
  `datatype_id` int NOT NULL DEFAULT '0',
  `class_id` int NOT NULL DEFAULT '0',
  `is_set` smallint NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `default_charge` int DEFAULT NULL,
  `version` varchar(50) DEFAULT NULL,
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`concept_id`),
  UNIQUE KEY `concept_uuid_index` (`uuid`),
  KEY `concept_classes` (`class_id`),
  KEY `concept_creator` (`creator`),
  KEY `concept_datatypes` (`datatype_id`),
  KEY `user_who_changed_concept` (`changed_by`),
  KEY `user_who_retired_concept` (`retired_by`),
  CONSTRAINT `concept_classes` FOREIGN KEY (`class_id`) REFERENCES `concept_class` (`concept_class_id`),
  CONSTRAINT `concept_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `concept_datatypes` FOREIGN KEY (`datatype_id`) REFERENCES `concept_datatype` (`concept_datatype_id`),
  CONSTRAINT `user_who_changed_concept` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_concept` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=11892 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_answer`
--

DROP TABLE IF EXISTS `concept_answer`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_answer` (
  `concept_answer_id` int NOT NULL AUTO_INCREMENT,
  `concept_id` int NOT NULL DEFAULT '0',
  `answer_concept` int DEFAULT NULL,
  `answer_drug` int DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `uuid` char(38) NOT NULL,
  `sort_weight` double DEFAULT NULL,
  PRIMARY KEY (`concept_answer_id`),
  UNIQUE KEY `concept_answer_uuid_index` (`uuid`),
  KEY `answer_creator` (`creator`),
  KEY `answer` (`answer_concept`),
  KEY `answers_for_concept` (`concept_id`),
  CONSTRAINT `answer` FOREIGN KEY (`answer_concept`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `answer_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `answers_for_concept` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`)
) ENGINE=InnoDB AUTO_INCREMENT=10319 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_class`
--

DROP TABLE IF EXISTS `concept_class`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_class` (
  `concept_class_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL DEFAULT '',
  `description` varchar(255) NOT NULL DEFAULT '',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `retired` smallint NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`concept_class_id`),
  UNIQUE KEY `concept_class_uuid_index` (`uuid`),
  KEY `concept_class_creator` (`creator`),
  KEY `user_who_retired_concept_class` (`retired_by`),
  KEY `concept_class_retired_status` (`retired`),
  CONSTRAINT `concept_class_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_concept_class` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=21 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_complex`
--

DROP TABLE IF EXISTS `concept_complex`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_complex` (
  `concept_id` int NOT NULL,
  `handler` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`concept_id`),
  CONSTRAINT `concept_attributes` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_datatype`
--

DROP TABLE IF EXISTS `concept_datatype`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_datatype` (
  `concept_datatype_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL DEFAULT '',
  `hl7_abbreviation` varchar(3) DEFAULT NULL,
  `description` varchar(255) NOT NULL DEFAULT '',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `retired` smallint NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`concept_datatype_id`),
  UNIQUE KEY `concept_datatype_uuid_index` (`uuid`),
  KEY `concept_datatype_creator` (`creator`),
  KEY `user_who_retired_concept_datatype` (`retired_by`),
  KEY `concept_datatype_retired_status` (`retired`),
  CONSTRAINT `concept_datatype_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_concept_datatype` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=14 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_derived`
--

DROP TABLE IF EXISTS `concept_derived`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_derived` (
  `concept_id` int NOT NULL DEFAULT '0',
  `rule` mediumtext,
  `compile_date` datetime DEFAULT NULL,
  `compile_status` varchar(255) DEFAULT NULL,
  `class_name` varchar(1024) DEFAULT NULL,
  PRIMARY KEY (`concept_id`),
  CONSTRAINT `derived_attributes` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_description`
--

DROP TABLE IF EXISTS `concept_description`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_description` (
  `concept_description_id` int NOT NULL AUTO_INCREMENT,
  `concept_id` int NOT NULL DEFAULT '0',
  `description` text NOT NULL,
  `locale` varchar(50) NOT NULL DEFAULT '',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`concept_description_id`),
  UNIQUE KEY `concept_description_uuid_index` (`uuid`),
  KEY `concept_being_described` (`concept_id`),
  KEY `user_who_created_description` (`creator`),
  KEY `user_who_changed_description` (`changed_by`),
  CONSTRAINT `description_for_concept` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `user_who_changed_description` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_created_description` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=7363 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_map`
--

DROP TABLE IF EXISTS `concept_map`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_map` (
  `concept_map_id` int NOT NULL AUTO_INCREMENT,
  `source` int DEFAULT NULL,
  `source_code` varchar(255) DEFAULT NULL,
  `comment` varchar(255) DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `concept_id` int NOT NULL DEFAULT '0',
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`concept_map_id`),
  UNIQUE KEY `concept_map_uuid_index` (`uuid`),
  KEY `map_source` (`source`),
  KEY `map_creator` (`creator`),
  KEY `map_for_concept` (`concept_id`),
  CONSTRAINT `map_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `map_for_concept` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `map_source` FOREIGN KEY (`source`) REFERENCES `concept_source` (`concept_source_id`)
) ENGINE=InnoDB AUTO_INCREMENT=1843 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_name`
--

DROP TABLE IF EXISTS `concept_name`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_name` (
  `concept_id` int DEFAULT NULL,
  `name` varchar(255) NOT NULL DEFAULT '',
  `locale` varchar(50) NOT NULL DEFAULT '',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `concept_name_id` int NOT NULL AUTO_INCREMENT,
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  `concept_name_type` varchar(50) DEFAULT NULL,
  `locale_preferred` smallint DEFAULT '0',
  PRIMARY KEY (`concept_name_id`),
  UNIQUE KEY `concept_name_id` (`concept_name_id`),
  UNIQUE KEY `concept_name_uuid_index` (`uuid`),
  KEY `user_who_created_name` (`creator`),
  KEY `name_of_concept` (`name`),
  KEY `unique_concept_name_id` (`concept_id`),
  KEY `user_who_voided_name` (`voided_by`),
  CONSTRAINT `user_who_created_name` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_voided_this_name` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=107514 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_name_tag`
--

DROP TABLE IF EXISTS `concept_name_tag`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_name_tag` (
  `concept_name_tag_id` int NOT NULL AUTO_INCREMENT,
  `tag` varchar(50) NOT NULL,
  `description` text NOT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`concept_name_tag_id`),
  UNIQUE KEY `concept_name_tag_id` (`concept_name_tag_id`),
  UNIQUE KEY `concept_name_tag_id_2` (`concept_name_tag_id`),
  UNIQUE KEY `concept_name_tag_unique_tags` (`tag`),
  UNIQUE KEY `concept_name_tag_uuid_index` (`uuid`),
  KEY `user_who_created_name_tag` (`creator`),
  KEY `user_who_voided_name_tag` (`voided_by`)
) ENGINE=InnoDB AUTO_INCREMENT=399 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_name_tag_map`
--

DROP TABLE IF EXISTS `concept_name_tag_map`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_name_tag_map` (
  `concept_name_id` int NOT NULL,
  `concept_name_tag_id` int NOT NULL,
  KEY `map_name` (`concept_name_id`),
  KEY `map_name_tag` (`concept_name_tag_id`),
  CONSTRAINT `mapped_concept_name` FOREIGN KEY (`concept_name_id`) REFERENCES `concept_name` (`concept_name_id`),
  CONSTRAINT `mapped_concept_name_tag` FOREIGN KEY (`concept_name_tag_id`) REFERENCES `concept_name_tag` (`concept_name_tag_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_numeric`
--

DROP TABLE IF EXISTS `concept_numeric`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_numeric` (
  `concept_id` int NOT NULL DEFAULT '0',
  `hi_absolute` double DEFAULT NULL,
  `hi_critical` double DEFAULT NULL,
  `hi_normal` double DEFAULT NULL,
  `low_absolute` double DEFAULT NULL,
  `low_critical` double DEFAULT NULL,
  `low_normal` double DEFAULT NULL,
  `units` varchar(50) DEFAULT NULL,
  `precise` smallint NOT NULL DEFAULT '0',
  PRIMARY KEY (`concept_id`),
  CONSTRAINT `numeric_attributes` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_proposal`
--

DROP TABLE IF EXISTS `concept_proposal`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_proposal` (
  `concept_proposal_id` int NOT NULL AUTO_INCREMENT,
  `concept_id` int DEFAULT NULL,
  `encounter_id` int DEFAULT NULL,
  `original_text` varchar(255) NOT NULL DEFAULT '',
  `final_text` varchar(255) DEFAULT NULL,
  `obs_id` int DEFAULT NULL,
  `obs_concept_id` int DEFAULT NULL,
  `state` varchar(32) NOT NULL DEFAULT 'UNMAPPED' COMMENT 'Valid values are: UNMAPPED, SYNONYM, CONCEPT, REJECT',
  `comments` varchar(255) DEFAULT NULL COMMENT 'Comment from concept admin/mapper',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `locale` varchar(50) NOT NULL DEFAULT '',
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`concept_proposal_id`),
  UNIQUE KEY `concept_proposal_uuid_index` (`uuid`),
  KEY `encounter_for_proposal` (`encounter_id`),
  KEY `concept_for_proposal` (`concept_id`),
  KEY `user_who_created_proposal` (`creator`),
  KEY `user_who_changed_proposal` (`changed_by`),
  KEY `proposal_obs_id` (`obs_id`),
  KEY `proposal_obs_concept_id` (`obs_concept_id`),
  CONSTRAINT `concept_for_proposal` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `encounter_for_proposal` FOREIGN KEY (`encounter_id`) REFERENCES `encounter` (`encounter_id`),
  CONSTRAINT `proposal_obs_concept_id` FOREIGN KEY (`obs_concept_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `proposal_obs_id` FOREIGN KEY (`obs_id`) REFERENCES `obs` (`obs_id`),
  CONSTRAINT `user_who_changed_proposal` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_created_proposal` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_proposal_tag_map`
--

DROP TABLE IF EXISTS `concept_proposal_tag_map`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_proposal_tag_map` (
  `concept_proposal_id` int NOT NULL,
  `concept_name_tag_id` int NOT NULL,
  KEY `map_proposal` (`concept_proposal_id`),
  KEY `map_name_tag` (`concept_name_tag_id`),
  CONSTRAINT `mapped_concept_proposal` FOREIGN KEY (`concept_proposal_id`) REFERENCES `concept_proposal` (`concept_proposal_id`),
  CONSTRAINT `mapped_concept_proposal_tag` FOREIGN KEY (`concept_name_tag_id`) REFERENCES `concept_name_tag` (`concept_name_tag_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_set`
--

DROP TABLE IF EXISTS `concept_set`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_set` (
  `concept_set_id` int NOT NULL AUTO_INCREMENT,
  `concept_id` int NOT NULL DEFAULT '0',
  `concept_set` int NOT NULL DEFAULT '0',
  `sort_weight` double DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`concept_set_id`),
  UNIQUE KEY `concept_set_uuid_index` (`uuid`),
  KEY `has_a` (`concept_set`),
  KEY `user_who_created` (`creator`),
  KEY `idx_concept_set_concept` (`concept_id`),
  CONSTRAINT `has_a` FOREIGN KEY (`concept_set`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `is_a` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `user_who_created` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=5403 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_set_derived`
--

DROP TABLE IF EXISTS `concept_set_derived`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_set_derived` (
  `concept_id` int NOT NULL DEFAULT '0',
  `concept_set` int NOT NULL DEFAULT '0',
  `sort_weight` double DEFAULT NULL,
  PRIMARY KEY (`concept_id`,`concept_set`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_source`
--

DROP TABLE IF EXISTS `concept_source`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_source` (
  `concept_source_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(50) NOT NULL DEFAULT '',
  `description` text NOT NULL,
  `hl7_code` varchar(50) DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `retired` tinyint(1) NOT NULL,
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`concept_source_id`),
  UNIQUE KEY `concept_source_uuid_index` (`uuid`),
  KEY `concept_source_creator` (`creator`),
  KEY `user_who_voided_concept_source` (`retired_by`),
  KEY `unique_hl7_code` (`hl7_code`,`retired`),
  CONSTRAINT `concept_source_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_concept_source` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=9 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_state_conversion`
--

DROP TABLE IF EXISTS `concept_state_conversion`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_state_conversion` (
  `concept_state_conversion_id` int NOT NULL AUTO_INCREMENT,
  `concept_id` int DEFAULT '0',
  `program_workflow_id` int DEFAULT '0',
  `program_workflow_state_id` int DEFAULT '0',
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`concept_state_conversion_id`),
  UNIQUE KEY `concept_state_conversion_uuid_index` (`uuid`),
  UNIQUE KEY `unique_workflow_concept_in_conversion` (`program_workflow_id`,`concept_id`),
  KEY `triggering_concept` (`concept_id`),
  KEY `affected_workflow` (`program_workflow_id`),
  KEY `resulting_state` (`program_workflow_state_id`),
  CONSTRAINT `concept_triggers_conversion` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `conversion_involves_workflow` FOREIGN KEY (`program_workflow_id`) REFERENCES `program_workflow` (`program_workflow_id`),
  CONSTRAINT `conversion_to_state` FOREIGN KEY (`program_workflow_state_id`) REFERENCES `program_workflow_state` (`program_workflow_state_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_synonym`
--

DROP TABLE IF EXISTS `concept_synonym`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_synonym` (
  `concept_id` int NOT NULL DEFAULT '0',
  `synonym` varchar(255) NOT NULL DEFAULT '',
  `locale` varchar(255) DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  PRIMARY KEY (`synonym`,`concept_id`),
  KEY `synonym_for` (`concept_id`),
  KEY `synonym_creator` (`creator`),
  CONSTRAINT `synonym_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `synonym_for` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `concept_word`
--

DROP TABLE IF EXISTS `concept_word`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `concept_word` (
  `concept_word_id` int NOT NULL AUTO_INCREMENT,
  `concept_id` int NOT NULL DEFAULT '0',
  `word` varchar(50) NOT NULL DEFAULT '',
  `locale` varchar(20) NOT NULL DEFAULT '',
  `concept_name_id` int NOT NULL,
  PRIMARY KEY (`concept_word_id`),
  KEY `word_in_concept_name` (`word`),
  KEY `word_for_name` (`concept_name_id`),
  KEY `concept_word_concept_idx` (`concept_id`),
  CONSTRAINT `word_for` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`)
) ENGINE=InnoDB AUTO_INCREMENT=36175 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `data_cleaning_supervisions`
--

DROP TABLE IF EXISTS `data_cleaning_supervisions`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `data_cleaning_supervisions` (
  `data_cleaning_tool_id` bigint NOT NULL AUTO_INCREMENT,
  `data_cleaning_datetime` datetime NOT NULL,
  `supervisors` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `creator` int NOT NULL,
  `voided` tinyint(1) NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `comments` text COLLATE utf8mb3_unicode_ci,
  `date_created` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime(6) DEFAULT NULL,
  `date_voided` datetime(6) DEFAULT NULL,
  `void_reason` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `uuid` varchar(38) COLLATE utf8mb3_unicode_ci NOT NULL,
  PRIMARY KEY (`data_cleaning_tool_id`),
  KEY `fk_rails_49c5d63d0f` (`changed_by`),
  KEY `fk_rails_f69409bf54` (`voided_by`),
  CONSTRAINT `fk_rails_49c5d63d0f` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `fk_rails_f69409bf54` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `district`
--

DROP TABLE IF EXISTS `district`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `district` (
  `district_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL DEFAULT '',
  `region_id` int NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`district_id`),
  KEY `region_for_district` (`region_id`),
  KEY `user_who_created_district` (`creator`),
  KEY `user_who_retired_district` (`retired_by`),
  KEY `retired_status` (`retired`),
  CONSTRAINT `region_for_district` FOREIGN KEY (`region_id`) REFERENCES `region` (`region_id`),
  CONSTRAINT `user_who_created_district` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_district` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=293 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `districts`
--

DROP TABLE IF EXISTS `districts`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `districts` (
  `id` int NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `drug`
--

DROP TABLE IF EXISTS `drug`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `drug` (
  `drug_id` int NOT NULL AUTO_INCREMENT,
  `concept_id` int NOT NULL DEFAULT '0',
  `name` text,
  `combination` smallint NOT NULL DEFAULT '0',
  `dosage_form` int DEFAULT NULL,
  `dose_strength` double DEFAULT NULL,
  `maximum_daily_dose` double DEFAULT NULL,
  `minimum_daily_dose` double DEFAULT NULL,
  `route` int DEFAULT NULL,
  `units` varchar(50) DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `retired` smallint NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`drug_id`),
  UNIQUE KEY `drug_uuid_index` (`uuid`),
  KEY `drug_creator` (`creator`),
  KEY `primary_drug_concept` (`concept_id`),
  KEY `dosage_form_concept` (`dosage_form`),
  KEY `route_concept` (`route`),
  KEY `user_who_voided_drug` (`retired_by`),
  CONSTRAINT `dosage_form_concept` FOREIGN KEY (`dosage_form`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `drug_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `drug_retired_by` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `primary_drug_concept` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `route_concept` FOREIGN KEY (`route`) REFERENCES `concept` (`concept_id`)
) ENGINE=InnoDB AUTO_INCREMENT=1352 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `drug_cms`
--

DROP TABLE IF EXISTS `drug_cms`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `drug_cms` (
  `drug_inventory_id` int NOT NULL,
  `name` varchar(255) NOT NULL,
  `code` varchar(255) DEFAULT NULL,
  `short_name` varchar(225) DEFAULT NULL,
  `tabs` varchar(225) DEFAULT NULL,
  `pack_size` int DEFAULT NULL,
  `weight` int DEFAULT NULL,
  `strength` varchar(255) DEFAULT NULL,
  `voided` tinyint DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(225) DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  `id` bigint NOT NULL AUTO_INCREMENT,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=40 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `drug_ingredient`
--

DROP TABLE IF EXISTS `drug_ingredient`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `drug_ingredient` (
  `concept_id` int NOT NULL DEFAULT '0',
  `ingredient_id` int NOT NULL DEFAULT '0',
  KEY `combination_drug` (`concept_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `drug_ingredients`
--

DROP TABLE IF EXISTS `drug_ingredients`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `drug_ingredients` (
  `id` int NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `drug_order`
--

DROP TABLE IF EXISTS `drug_order`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `drug_order` (
  `order_id` int NOT NULL DEFAULT '0',
  `drug_inventory_id` int DEFAULT '0',
  `dose` double DEFAULT NULL,
  `equivalent_daily_dose` double DEFAULT NULL,
  `units` varchar(255) DEFAULT NULL,
  `frequency` varchar(255) DEFAULT NULL,
  `prn` smallint NOT NULL DEFAULT '0',
  `complex` smallint NOT NULL DEFAULT '0',
  `quantity` int DEFAULT NULL,
  PRIMARY KEY (`order_id`),
  KEY `inventory_item` (`drug_inventory_id`),
  KEY `inventory_item_and_order_quantity` (`drug_inventory_id`,`quantity`),
  CONSTRAINT `extends_order` FOREIGN KEY (`order_id`) REFERENCES `orders` (`order_id`),
  CONSTRAINT `inventory_item` FOREIGN KEY (`drug_inventory_id`) REFERENCES `drug` (`drug_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `drug_order_barcodes`
--

DROP TABLE IF EXISTS `drug_order_barcodes`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `drug_order_barcodes` (
  `drug_order_barcode_id` int NOT NULL AUTO_INCREMENT,
  `drug_id` int DEFAULT NULL,
  `tabs` int DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`drug_order_barcode_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `drug_set`
--

DROP TABLE IF EXISTS `drug_set`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `drug_set` (
  `drug_set_id` int NOT NULL AUTO_INCREMENT,
  `drug_inventory_id` int DEFAULT NULL,
  `set_id` int DEFAULT NULL,
  `frequency` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `duration` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `date_created` datetime DEFAULT NULL,
  `date_updated` datetime DEFAULT NULL,
  `creator` int DEFAULT NULL,
  `voided` tinyint(1) NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  PRIMARY KEY (`drug_set_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `dset`
--

DROP TABLE IF EXISTS `dset`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `dset` (
  `set_id` int NOT NULL AUTO_INCREMENT,
  `name` text COLLATE utf8mb3_unicode_ci,
  `description` text COLLATE utf8mb3_unicode_ci,
  `date_created` datetime DEFAULT NULL,
  `date_updated` datetime DEFAULT NULL,
  `creator` int NOT NULL,
  `status` varchar(25) COLLATE utf8mb3_unicode_ci NOT NULL,
  PRIMARY KEY (`set_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `earliest_start_date`
--

DROP TABLE IF EXISTS `earliest_start_date`;
/*!50001 DROP VIEW IF EXISTS `earliest_start_date`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `earliest_start_date` AS SELECT 
 1 AS `patient_id`,
 1 AS `gender`,
 1 AS `birthdate`,
 1 AS `earliest_start_date`,
 1 AS `date_enrolled`,
 1 AS `death_date`,
 1 AS `age_at_initiation`,
 1 AS `age_in_days`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `encounter`
--

DROP TABLE IF EXISTS `encounter`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `encounter` (
  `encounter_id` int NOT NULL AUTO_INCREMENT,
  `encounter_type` int NOT NULL,
  `patient_id` int NOT NULL DEFAULT '0',
  `provider_id` int NOT NULL DEFAULT '0',
  `location_id` varchar(255) DEFAULT NULL,
  `form_id` int DEFAULT NULL,
  `encounter_datetime` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `program_id` int DEFAULT '1',
  PRIMARY KEY (`encounter_id`),
  UNIQUE KEY `encounter_uuid_index` (`uuid`),
  KEY `encounter_location` (`location_id`),
  KEY `encounter_patient` (`patient_id`),
  KEY `encounter_provider` (`provider_id`),
  KEY `encounter_type_id` (`encounter_type`),
  KEY `encounter_creator` (`creator`),
  KEY `encounter_form` (`form_id`),
  KEY `user_who_voided_encounter` (`voided_by`),
  KEY `encounter_changed_by` (`changed_by`),
  KEY `encounter_datetime_idx` (`encounter_datetime`),
  KEY `fk_rails_ad7f416cd0` (`program_id`),
  KEY `idx_person_encounters` (`patient_id`,`encounter_type`),
  KEY `idx_person_encounters_by_date` (`encounter_datetime`,`patient_id`,`encounter_type`),
  CONSTRAINT `encounter_changed_by` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `encounter_form` FOREIGN KEY (`form_id`) REFERENCES `form` (`form_id`),
  CONSTRAINT `encounter_ibfk_1` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `encounter_patient` FOREIGN KEY (`patient_id`) REFERENCES `patient` (`patient_id`) ON UPDATE CASCADE,
  CONSTRAINT `encounter_provider` FOREIGN KEY (`provider_id`) REFERENCES `person` (`person_id`),
  CONSTRAINT `encounter_type_id` FOREIGN KEY (`encounter_type`) REFERENCES `encounter_type` (`encounter_type_id`),
  CONSTRAINT `fk_rails_ad7f416cd0` FOREIGN KEY (`program_id`) REFERENCES `program` (`program_id`),
  CONSTRAINT `user_who_voided_encounter` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=38697 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `encounter_type`
--

DROP TABLE IF EXISTS `encounter_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `encounter_type` (
  `encounter_type_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(50) NOT NULL DEFAULT '',
  `description` text,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `retired` smallint NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`encounter_type_id`),
  UNIQUE KEY `encounter_type_uuid_index` (`uuid`),
  KEY `user_who_created_type` (`creator`),
  KEY `user_who_retired_encounter_type` (`retired_by`),
  KEY `retired_status` (`retired`),
  CONSTRAINT `user_who_created_type` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_encounter_type` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=204 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `ever_registered_obs`
--

DROP TABLE IF EXISTS `ever_registered_obs`;
/*!50001 DROP VIEW IF EXISTS `ever_registered_obs`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `ever_registered_obs` AS SELECT 
 1 AS `obs_id`,
 1 AS `person_id`,
 1 AS `concept_id`,
 1 AS `encounter_id`,
 1 AS `order_id`,
 1 AS `obs_datetime`,
 1 AS `location_id`,
 1 AS `obs_group_id`,
 1 AS `accession_number`,
 1 AS `value_group_id`,
 1 AS `value_boolean`,
 1 AS `value_coded`,
 1 AS `value_coded_name_id`,
 1 AS `value_drug`,
 1 AS `value_datetime`,
 1 AS `value_numeric`,
 1 AS `value_modifier`,
 1 AS `value_text`,
 1 AS `date_started`,
 1 AS `date_stopped`,
 1 AS `comments`,
 1 AS `creator`,
 1 AS `date_created`,
 1 AS `voided`,
 1 AS `voided_by`,
 1 AS `date_voided`,
 1 AS `void_reason`,
 1 AS `value_complex`,
 1 AS `uuid`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `external_source`
--

DROP TABLE IF EXISTS `external_source`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `external_source` (
  `external_source_id` int NOT NULL AUTO_INCREMENT,
  `source` int NOT NULL DEFAULT '0',
  `source_code` varchar(255) NOT NULL,
  `name` varchar(255) DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  PRIMARY KEY (`external_source_id`),
  KEY `map_ext_source` (`source`),
  KEY `map_ext_creator` (`creator`),
  CONSTRAINT `map_ext_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `map_ext_source` FOREIGN KEY (`source`) REFERENCES `concept_source` (`concept_source_id`)
) ENGINE=InnoDB AUTO_INCREMENT=1022 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `facilities`
--

DROP TABLE IF EXISTS `facilities`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `facilities` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `code` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `name` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `common` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `ownership` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `facility_type` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `status` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `regulatory_status` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `district` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `date_opened` date DEFAULT NULL,
  `latitude` decimal(10,6) DEFAULT NULL,
  `longitude` decimal(10,6) DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `index_facilities_on_code` (`code`)
) ENGINE=InnoDB AUTO_INCREMENT=1902 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `field`
--

DROP TABLE IF EXISTS `field`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `field` (
  `field_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL DEFAULT '',
  `description` text,
  `field_type` int DEFAULT NULL,
  `concept_id` int DEFAULT NULL,
  `table_name` varchar(50) DEFAULT NULL,
  `attribute_name` varchar(50) DEFAULT NULL,
  `default_value` text,
  `select_multiple` smallint NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `retired` smallint NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`field_id`),
  UNIQUE KEY `field_uuid_index` (`uuid`),
  KEY `concept_for_field` (`concept_id`),
  KEY `user_who_changed_field` (`changed_by`),
  KEY `user_who_created_field` (`creator`),
  KEY `type_of_field` (`field_type`),
  KEY `user_who_retired_field` (`retired_by`),
  KEY `field_retired_status` (`retired`),
  CONSTRAINT `concept_for_field` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `type_of_field` FOREIGN KEY (`field_type`) REFERENCES `field_type` (`field_type_id`),
  CONSTRAINT `user_who_changed_field` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_created_field` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_field` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=702 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `field_answer`
--

DROP TABLE IF EXISTS `field_answer`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `field_answer` (
  `field_id` int NOT NULL DEFAULT '0',
  `answer_id` int NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`field_id`,`answer_id`),
  UNIQUE KEY `field_answer_uuid_index` (`uuid`),
  KEY `answers_for_field` (`field_id`),
  KEY `field_answer_concept` (`answer_id`),
  KEY `user_who_created_field_answer` (`creator`),
  CONSTRAINT `answers_for_field` FOREIGN KEY (`field_id`) REFERENCES `field` (`field_id`),
  CONSTRAINT `field_answer_concept` FOREIGN KEY (`answer_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `user_who_created_field_answer` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `field_type`
--

DROP TABLE IF EXISTS `field_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `field_type` (
  `field_type_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(50) DEFAULT NULL,
  `description` longtext,
  `is_set` smallint NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`field_type_id`),
  UNIQUE KEY `field_type_uuid_index` (`uuid`),
  KEY `user_who_created_field_type` (`creator`),
  CONSTRAINT `user_who_created_field_type` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=6 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `form`
--

DROP TABLE IF EXISTS `form`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `form` (
  `form_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL DEFAULT '',
  `version` varchar(50) NOT NULL DEFAULT '',
  `build` int DEFAULT NULL,
  `published` smallint NOT NULL DEFAULT '0',
  `description` text,
  `encounter_type` int DEFAULT NULL,
  `template` mediumtext,
  `xslt` mediumtext,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `retired` smallint NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retired_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`form_id`),
  UNIQUE KEY `form_uuid_index` (`uuid`),
  KEY `user_who_created_form` (`creator`),
  KEY `user_who_last_changed_form` (`changed_by`),
  KEY `user_who_retired_form` (`retired_by`),
  KEY `encounter_type` (`encounter_type`),
  CONSTRAINT `form_encounter_type` FOREIGN KEY (`encounter_type`) REFERENCES `encounter_type` (`encounter_type_id`),
  CONSTRAINT `user_who_created_form` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_last_changed_form` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_form` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `form2program_map`
--

DROP TABLE IF EXISTS `form2program_map`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `form2program_map` (
  `program` int NOT NULL,
  `encounter_type` int NOT NULL,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL,
  `changed_by` int NOT NULL,
  `date_changed` datetime NOT NULL,
  `applied` tinyint(1) NOT NULL DEFAULT '0',
  PRIMARY KEY (`program`,`encounter_type`),
  KEY `encounter_type` (`encounter_type`),
  KEY `user_who_created_form2program` (`creator`),
  KEY `user_who_changed_form2program` (`changed_by`),
  CONSTRAINT `form2program_map_ibfk_1` FOREIGN KEY (`program`) REFERENCES `program` (`program_id`),
  CONSTRAINT `form2program_map_ibfk_2` FOREIGN KEY (`encounter_type`) REFERENCES `encounter_type` (`encounter_type_id`),
  CONSTRAINT `user_who_changed_form2program` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_created_form2program` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `form_field`
--

DROP TABLE IF EXISTS `form_field`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `form_field` (
  `form_field_id` int NOT NULL AUTO_INCREMENT,
  `form_id` int NOT NULL DEFAULT '0',
  `field_id` int NOT NULL DEFAULT '0',
  `field_number` int DEFAULT NULL,
  `field_part` varchar(5) DEFAULT NULL,
  `page_number` int DEFAULT NULL,
  `parent_form_field` int DEFAULT NULL,
  `min_occurs` int DEFAULT NULL,
  `max_occurs` int DEFAULT NULL,
  `required` smallint NOT NULL DEFAULT '0',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `sort_weight` float(11,5) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`form_field_id`),
  UNIQUE KEY `form_field_uuid_index` (`uuid`),
  KEY `user_who_last_changed_form_field` (`changed_by`),
  KEY `field_within_form` (`field_id`),
  KEY `form_containing_field` (`form_id`),
  KEY `form_field_hierarchy` (`parent_form_field`),
  KEY `user_who_created_form_field` (`creator`),
  CONSTRAINT `field_within_form` FOREIGN KEY (`field_id`) REFERENCES `field` (`field_id`),
  CONSTRAINT `form_containing_field` FOREIGN KEY (`form_id`) REFERENCES `form` (`form_id`),
  CONSTRAINT `form_field_hierarchy` FOREIGN KEY (`parent_form_field`) REFERENCES `form_field` (`form_field_id`),
  CONSTRAINT `user_who_created_form_field` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_last_changed_form_field` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `formentry_archive`
--

DROP TABLE IF EXISTS `formentry_archive`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `formentry_archive` (
  `formentry_archive_id` int NOT NULL AUTO_INCREMENT,
  `form_data` mediumtext NOT NULL,
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `creator` int NOT NULL DEFAULT '0',
  PRIMARY KEY (`formentry_archive_id`),
  KEY `User who created formentry_archive` (`creator`),
  CONSTRAINT `User who created formentry_archive` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `formentry_error`
--

DROP TABLE IF EXISTS `formentry_error`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `formentry_error` (
  `formentry_error_id` int NOT NULL AUTO_INCREMENT,
  `form_data` mediumtext NOT NULL,
  `error` varchar(255) NOT NULL DEFAULT '',
  `error_details` text,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  PRIMARY KEY (`formentry_error_id`),
  KEY `User who created formentry_error` (`creator`),
  CONSTRAINT `User who created formentry_error` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `formentry_queue`
--

DROP TABLE IF EXISTS `formentry_queue`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `formentry_queue` (
  `formentry_queue_id` int NOT NULL AUTO_INCREMENT,
  `form_data` mediumtext NOT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  PRIMARY KEY (`formentry_queue_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `formentry_xsn`
--

DROP TABLE IF EXISTS `formentry_xsn`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `formentry_xsn` (
  `formentry_xsn_id` int NOT NULL AUTO_INCREMENT,
  `form_id` int NOT NULL,
  `xsn_data` longblob NOT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `archived` int NOT NULL DEFAULT '0',
  `archived_by` int DEFAULT NULL,
  `date_archived` datetime DEFAULT NULL,
  PRIMARY KEY (`formentry_xsn_id`),
  KEY `User who created formentry_xsn` (`creator`),
  KEY `Form with which this xsn is related` (`form_id`),
  KEY `User who archived formentry_xsn` (`archived_by`),
  CONSTRAINT `Form with which this xsn is related` FOREIGN KEY (`form_id`) REFERENCES `form` (`form_id`),
  CONSTRAINT `User who archived formentry_xsn` FOREIGN KEY (`archived_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `User who created formentry_xsn` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `general_sets`
--

DROP TABLE IF EXISTS `general_sets`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `general_sets` (
  `id` int NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `global_property`
--

DROP TABLE IF EXISTS `global_property`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `global_property` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `property` varbinary(255) NOT NULL DEFAULT '',
  `property_value` mediumtext,
  `description` text,
  `uuid` char(38) NOT NULL,
  `location_id` varchar(255) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `idx_global_property_property_location` (`property`,`location_id`)
) ENGINE=InnoDB AUTO_INCREMENT=1183 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `guardians`
--

DROP TABLE IF EXISTS `guardians`;
/*!50001 DROP VIEW IF EXISTS `guardians`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `guardians` AS SELECT 
 1 AS `patient_id`,
 1 AS `guardian_id`,
 1 AS `gender`,
 1 AS `given_name`,
 1 AS `family_name`,
 1 AS `middle_name`,
 1 AS `birthdate_estimated`,
 1 AS `birthdate`,
 1 AS `home_district`,
 1 AS `current_district`,
 1 AS `landmark`,
 1 AS `current_residence`,
 1 AS `traditional_authority`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `heart_beat`
--

DROP TABLE IF EXISTS `heart_beat`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `heart_beat` (
  `id` int NOT NULL AUTO_INCREMENT,
  `ip` varchar(20) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `property` varchar(200) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `value` varchar(200) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `time_stamp` datetime DEFAULT NULL,
  `username` varchar(10) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `url` varchar(100) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `hiv_status_obs`
--

DROP TABLE IF EXISTS `hiv_status_obs`;
/*!50001 DROP VIEW IF EXISTS `hiv_status_obs`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `hiv_status_obs` AS SELECT 
 1 AS `person_id`,
 1 AS `encounter_id`,
 1 AS `hiv_status`,
 1 AS `obs_datetime`*/;
SET character_set_client = @saved_cs_client;

--
-- Temporary view structure for view `hiv_test_and_hiv_test_date_obs`
--

DROP TABLE IF EXISTS `hiv_test_and_hiv_test_date_obs`;
/*!50001 DROP VIEW IF EXISTS `hiv_test_and_hiv_test_date_obs`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `hiv_test_and_hiv_test_date_obs` AS SELECT 
 1 AS `person_id`,
 1 AS `encounter_id`,
 1 AS `hiv_status`,
 1 AS `hiv_test_date`,
 1 AS `obs_datetime`*/;
SET character_set_client = @saved_cs_client;

--
-- Temporary view structure for view `hiv_test_date_obs`
--

DROP TABLE IF EXISTS `hiv_test_date_obs`;
/*!50001 DROP VIEW IF EXISTS `hiv_test_date_obs`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `hiv_test_date_obs` AS SELECT 
 1 AS `person_id`,
 1 AS `encounter_id`,
 1 AS `hiv_test_date`,
 1 AS `obs_datetime`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `hl7_in_archive`
--

DROP TABLE IF EXISTS `hl7_in_archive`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `hl7_in_archive` (
  `hl7_in_archive_id` int NOT NULL AUTO_INCREMENT,
  `hl7_source` int NOT NULL DEFAULT '0',
  `hl7_source_key` varchar(255) DEFAULT NULL,
  `hl7_data` mediumtext NOT NULL,
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `message_state` int DEFAULT '2',
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`hl7_in_archive_id`),
  UNIQUE KEY `hl7_in_archive_uuid_index` (`uuid`),
  KEY `hl7_in_archive_message_state_idx` (`message_state`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `hl7_in_error`
--

DROP TABLE IF EXISTS `hl7_in_error`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `hl7_in_error` (
  `hl7_in_error_id` int NOT NULL AUTO_INCREMENT,
  `hl7_source` int NOT NULL DEFAULT '0',
  `hl7_source_key` text,
  `hl7_data` mediumtext NOT NULL,
  `error` varchar(255) NOT NULL DEFAULT '',
  `error_details` text,
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`hl7_in_error_id`),
  UNIQUE KEY `hl7_in_error_uuid_index` (`uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `hl7_in_queue`
--

DROP TABLE IF EXISTS `hl7_in_queue`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `hl7_in_queue` (
  `hl7_in_queue_id` int NOT NULL AUTO_INCREMENT,
  `hl7_source` int NOT NULL DEFAULT '0',
  `hl7_source_key` text,
  `hl7_data` mediumtext NOT NULL,
  `message_state` int NOT NULL DEFAULT '0',
  `date_processed` datetime DEFAULT NULL,
  `error_msg` text,
  `date_created` datetime DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`hl7_in_queue_id`),
  UNIQUE KEY `hl7_in_queue_uuid_index` (`uuid`),
  KEY `hl7_source` (`hl7_source`),
  CONSTRAINT `hl7_source` FOREIGN KEY (`hl7_source`) REFERENCES `hl7_source` (`hl7_source_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `hl7_source`
--

DROP TABLE IF EXISTS `hl7_source`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `hl7_source` (
  `hl7_source_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL DEFAULT '',
  `description` tinytext,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`hl7_source_id`),
  UNIQUE KEY `hl7_source_uuid_index` (`uuid`),
  KEY `creator` (`creator`),
  CONSTRAINT `creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `htmlformentry_html_form`
--

DROP TABLE IF EXISTS `htmlformentry_html_form`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `htmlformentry_html_form` (
  `id` int NOT NULL AUTO_INCREMENT,
  `form_id` int DEFAULT NULL,
  `name` varchar(100) NOT NULL,
  `xml_data` mediumtext NOT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  PRIMARY KEY (`id`),
  KEY `User who created htmlformentry_htmlform` (`creator`),
  KEY `Form with which this htmlform is related` (`form_id`),
  KEY `User who changed htmlformentry_htmlform` (`changed_by`),
  CONSTRAINT `Form with which this htmlform is related` FOREIGN KEY (`form_id`) REFERENCES `form` (`form_id`),
  CONSTRAINT `User who changed htmlformentry_htmlform` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `User who created htmlformentry_htmlform` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `immunization_cache_data`
--

DROP TABLE IF EXISTS `immunization_cache_data`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `immunization_cache_data` (
  `name` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `value` json NOT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  `location_id` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `id` bigint NOT NULL AUTO_INCREMENT,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `internal_sections`
--

DROP TABLE IF EXISTS `internal_sections`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `internal_sections` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `name` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL,
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `voided` tinyint(1) NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `fk_rails_564f0c6e7f` (`creator`),
  KEY `fk_rails_b4dec3bd71` (`voided_by`),
  CONSTRAINT `fk_rails_564f0c6e7f` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `fk_rails_b4dec3bd71` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `lab_accession_number_counters`
--

DROP TABLE IF EXISTS `lab_accession_number_counters`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `lab_accession_number_counters` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `date` date DEFAULT NULL,
  `value` bigint DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `index_lab_accession_number_counters_on_date` (`date`)
) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `lab_lims_failed_imports`
--

DROP TABLE IF EXISTS `lab_lims_failed_imports`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `lab_lims_failed_imports` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `lims_id` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `tracking_number` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `patient_nhid` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `reason` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `diff` varchar(2048) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `index_lab_lims_failed_imports_on_lims_id` (`lims_id`),
  KEY `index_lab_lims_failed_imports_on_patient_nhid` (`patient_nhid`),
  KEY `index_lab_lims_failed_imports_on_tracking_number` (`tracking_number`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `lab_lims_order_mappings`
--

DROP TABLE IF EXISTS `lab_lims_order_mappings`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `lab_lims_order_mappings` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `lims_id` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `order_id` int NOT NULL,
  `pushed_at` datetime DEFAULT NULL,
  `pulled_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  `revision` varchar(256) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `result_push_status` tinyint(1) DEFAULT '0',
  PRIMARY KEY (`id`),
  KEY `fk_rails_0171384638` (`order_id`),
  KEY `index_lab_lims_order_mappings_on_lims_id` (`lims_id`),
  CONSTRAINT `fk_rails_0171384638` FOREIGN KEY (`order_id`) REFERENCES `orders` (`order_id`)
) ENGINE=InnoDB AUTO_INCREMENT=8 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `labs`
--

DROP TABLE IF EXISTS `labs`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `labs` (
  `id` int NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `last_menstraul_period_date`
--

DROP TABLE IF EXISTS `last_menstraul_period_date`;
/*!50001 DROP VIEW IF EXISTS `last_menstraul_period_date`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `last_menstraul_period_date` AS SELECT 
 1 AS `person_id`,
 1 AS `encounter_id`,
 1 AS `lmp`,
 1 AS `obs_datetime`,
 1 AS `date_created`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `lims_acknowledgement_statuses`
--

DROP TABLE IF EXISTS `lims_acknowledgement_statuses`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `lims_acknowledgement_statuses` (
  `order_id` int NOT NULL AUTO_INCREMENT,
  `test` int NOT NULL,
  `date_received` datetime NOT NULL,
  `date_pushed` datetime DEFAULT NULL,
  `acknowledgement_type` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `pushed` tinyint(1) NOT NULL DEFAULT '0',
  `voided` tinyint(1) DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`order_id`),
  KEY `fk_rails_c856923164` (`test`),
  KEY `fk_rails_331e1d9232` (`voided_by`),
  CONSTRAINT `fk_rails_331e1d9232` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `fk_rails_83a1b79067` FOREIGN KEY (`order_id`) REFERENCES `orders` (`order_id`),
  CONSTRAINT `fk_rails_c856923164` FOREIGN KEY (`test`) REFERENCES `concept` (`concept_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `liquibasechangelog`
--

DROP TABLE IF EXISTS `liquibasechangelog`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `liquibasechangelog` (
  `ID` varchar(63) NOT NULL,
  `AUTHOR` varchar(63) NOT NULL,
  `FILENAME` varchar(200) NOT NULL,
  `DATEEXECUTED` datetime NOT NULL,
  `MD5SUM` varchar(32) DEFAULT NULL,
  `DESCRIPTION` varchar(255) DEFAULT NULL,
  `COMMENTS` varchar(255) DEFAULT NULL,
  `TAG` varchar(255) DEFAULT NULL,
  `LIQUIBASE` varchar(10) DEFAULT NULL,
  PRIMARY KEY (`ID`,`AUTHOR`,`FILENAME`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `liquibasechangeloglock`
--

DROP TABLE IF EXISTS `liquibasechangeloglock`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `liquibasechangeloglock` (
  `ID` int NOT NULL,
  `LOCKED` tinyint(1) NOT NULL,
  `LOCKGRANTED` datetime DEFAULT NULL,
  `LOCKEDBY` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `location`
--

DROP TABLE IF EXISTS `location`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `location` (
  `location_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL DEFAULT '',
  `description` varchar(255) DEFAULT NULL,
  `address1` varchar(50) DEFAULT NULL,
  `address2` varchar(50) DEFAULT NULL,
  `city_village` varchar(50) DEFAULT NULL,
  `state_province` varchar(50) DEFAULT NULL,
  `postal_code` varchar(50) DEFAULT NULL,
  `country` varchar(50) DEFAULT NULL,
  `latitude` varchar(50) DEFAULT NULL,
  `longitude` varchar(50) DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `county_district` varchar(50) DEFAULT NULL,
  `neighborhood_cell` varchar(50) DEFAULT NULL,
  `region` varchar(50) DEFAULT NULL,
  `subregion` varchar(50) DEFAULT NULL,
  `township_division` varchar(50) DEFAULT NULL,
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `location_type_id` int DEFAULT NULL,
  `parent_location` int DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`location_id`),
  UNIQUE KEY `location_uuid_index` (`uuid`),
  KEY `user_who_created_location` (`creator`),
  KEY `name_of_location` (`name`),
  KEY `user_who_retired_location` (`retired_by`),
  KEY `retired_status` (`retired`),
  KEY `type_of_location` (`location_type_id`),
  KEY `parent_location` (`parent_location`),
  CONSTRAINT `location_type` FOREIGN KEY (`location_type_id`) REFERENCES `location_type` (`location_type_id`),
  CONSTRAINT `parent_location` FOREIGN KEY (`parent_location`) REFERENCES `location` (`location_id`),
  CONSTRAINT `user_who_created_location` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_location` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=1138 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `location_tag`
--

DROP TABLE IF EXISTS `location_tag`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `location_tag` (
  `location_tag_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(50) DEFAULT NULL,
  `description` varchar(255) DEFAULT NULL,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL,
  `retired` smallint NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`location_tag_id`),
  UNIQUE KEY `location_tag_uuid_index` (`uuid`),
  KEY `location_tag_creator` (`creator`),
  KEY `location_tag_retired_by` (`retired_by`),
  CONSTRAINT `location_tag_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `location_tag_retired_by` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=12 DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `location_tag_map`
--

DROP TABLE IF EXISTS `location_tag_map`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `location_tag_map` (
  `location_id` int NOT NULL,
  `location_tag_id` int NOT NULL,
  PRIMARY KEY (`location_id`,`location_tag_id`),
  KEY `location_tag_map_tag` (`location_tag_id`),
  CONSTRAINT `location_tag_map_location` FOREIGN KEY (`location_id`) REFERENCES `location` (`location_id`),
  CONSTRAINT `location_tag_map_tag` FOREIGN KEY (`location_tag_id`) REFERENCES `location_tag` (`location_tag_id`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `location_tag_maps`
--

DROP TABLE IF EXISTS `location_tag_maps`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `location_tag_maps` (
  `id` int NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `logic_rule_definition`
--

DROP TABLE IF EXISTS `logic_rule_definition`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `logic_rule_definition` (
  `id` int NOT NULL AUTO_INCREMENT,
  `uuid` char(38) NOT NULL,
  `name` varchar(255) NOT NULL,
  `description` varchar(1000) DEFAULT NULL,
  `rule_content` varchar(2048) NOT NULL,
  `language` varchar(255) NOT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `name` (`name`),
  KEY `creator for rule_definition` (`creator`),
  KEY `changed_by for rule_definition` (`changed_by`),
  KEY `retired_by for rule_definition` (`retired_by`),
  CONSTRAINT `changed_by for rule_definition` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `creator for rule_definition` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `retired_by for rule_definition` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `logic_rule_token`
--

DROP TABLE IF EXISTS `logic_rule_token`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `logic_rule_token` (
  `logic_rule_token_id` int NOT NULL AUTO_INCREMENT,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL DEFAULT '0002-11-30 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `token` varchar(512) NOT NULL,
  `class_name` varchar(512) NOT NULL,
  `state` varchar(512) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`logic_rule_token_id`),
  UNIQUE KEY `logic_rule_token_uuid` (`uuid`),
  KEY `token_creator` (`creator`),
  KEY `token_changed_by` (`changed_by`),
  CONSTRAINT `token_changed_by` FOREIGN KEY (`changed_by`) REFERENCES `person` (`person_id`),
  CONSTRAINT `token_creator` FOREIGN KEY (`creator`) REFERENCES `person` (`person_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `logic_rule_token_tag`
--

DROP TABLE IF EXISTS `logic_rule_token_tag`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `logic_rule_token_tag` (
  `logic_rule_token_id` int NOT NULL,
  `tag` varchar(512) NOT NULL,
  KEY `token_tag` (`logic_rule_token_id`),
  CONSTRAINT `token_tag` FOREIGN KEY (`logic_rule_token_id`) REFERENCES `logic_rule_token` (`logic_rule_token_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `logic_token_registration`
--

DROP TABLE IF EXISTS `logic_token_registration`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `logic_token_registration` (
  `token_registration_id` int NOT NULL AUTO_INCREMENT,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL DEFAULT '0002-11-30 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `token` varchar(512) NOT NULL,
  `provider_class_name` varchar(512) NOT NULL,
  `provider_token` varchar(512) NOT NULL,
  `configuration` varchar(2000) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`token_registration_id`),
  UNIQUE KEY `uuid` (`uuid`),
  KEY `token_registration_creator` (`creator`),
  KEY `token_registration_changed_by` (`changed_by`),
  CONSTRAINT `token_registration_changed_by` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `token_registration_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=18 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `logic_token_registration_tag`
--

DROP TABLE IF EXISTS `logic_token_registration_tag`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `logic_token_registration_tag` (
  `token_registration_id` int NOT NULL,
  `tag` varchar(512) NOT NULL,
  KEY `token_registration_tag` (`token_registration_id`),
  CONSTRAINT `token_registration_tag` FOREIGN KEY (`token_registration_id`) REFERENCES `logic_token_registration` (`token_registration_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `merge_audits`
--

DROP TABLE IF EXISTS `merge_audits`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `merge_audits` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `primary_id` int NOT NULL,
  `secondary_id` int NOT NULL,
  `merge_type` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `secondary_previous_merge_id` bigint DEFAULT NULL,
  `creator` int NOT NULL,
  `voided` tinyint(1) NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `fk_rails_76fdfcb4ed` (`primary_id`),
  KEY `fk_rails_afc7a0f240` (`secondary_id`),
  KEY `fk_rails_d1dc00d9b1` (`creator`),
  KEY `fk_rails_83cf4bb331` (`voided_by`),
  KEY `fk_rails_d71d6f2933` (`secondary_previous_merge_id`),
  CONSTRAINT `fk_rails_76fdfcb4ed` FOREIGN KEY (`primary_id`) REFERENCES `patient` (`patient_id`),
  CONSTRAINT `fk_rails_83cf4bb331` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `fk_rails_afc7a0f240` FOREIGN KEY (`secondary_id`) REFERENCES `patient` (`patient_id`),
  CONSTRAINT `fk_rails_d1dc00d9b1` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `fk_rails_d71d6f2933` FOREIGN KEY (`secondary_previous_merge_id`) REFERENCES `merge_audits` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `merged_patients`
--

DROP TABLE IF EXISTS `merged_patients`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `merged_patients` (
  `patient_id` int NOT NULL,
  `merged_to_id` int NOT NULL,
  PRIMARY KEY (`patient_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `mime_type`
--

DROP TABLE IF EXISTS `mime_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `mime_type` (
  `mime_type_id` int NOT NULL AUTO_INCREMENT,
  `mime_type` varchar(75) NOT NULL DEFAULT '',
  `description` text,
  PRIMARY KEY (`mime_type_id`),
  KEY `mime_type_id` (`mime_type_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `moh_other_medications`
--

DROP TABLE IF EXISTS `moh_other_medications`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `moh_other_medications` (
  `medication_id` int NOT NULL AUTO_INCREMENT,
  `drug_inventory_id` int NOT NULL,
  `dose_id` int NOT NULL,
  `min_weight` float NOT NULL,
  `max_weight` float NOT NULL,
  `category` varchar(1) NOT NULL,
  PRIMARY KEY (`medication_id`)
) ENGINE=InnoDB AUTO_INCREMENT=16 DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `moh_regimen_combination`
--

DROP TABLE IF EXISTS `moh_regimen_combination`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `moh_regimen_combination` (
  `regimen_combination_id` int NOT NULL AUTO_INCREMENT,
  `regimen_name_id` int NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`regimen_combination_id`)
) ENGINE=InnoDB AUTO_INCREMENT=108 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `moh_regimen_combination_drug`
--

DROP TABLE IF EXISTS `moh_regimen_combination_drug`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `moh_regimen_combination_drug` (
  `regimen_combination_drug_id` int NOT NULL AUTO_INCREMENT,
  `regimen_combination_id` int NOT NULL,
  `drug_id` int NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`regimen_combination_drug_id`)
) ENGINE=InnoDB AUTO_INCREMENT=217 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `moh_regimen_doses`
--

DROP TABLE IF EXISTS `moh_regimen_doses`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `moh_regimen_doses` (
  `dose_id` int NOT NULL AUTO_INCREMENT,
  `am` float DEFAULT NULL,
  `pm` float DEFAULT NULL,
  `date_created` datetime DEFAULT NULL,
  `date_updated` datetime DEFAULT NULL,
  `creator` int DEFAULT NULL,
  `voided` tinyint(1) NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  PRIMARY KEY (`dose_id`)
) ENGINE=InnoDB AUTO_INCREMENT=28 DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `moh_regimen_ingredient`
--

DROP TABLE IF EXISTS `moh_regimen_ingredient`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `moh_regimen_ingredient` (
  `ingredient_id` int NOT NULL AUTO_INCREMENT,
  `regimen_id` int DEFAULT NULL,
  `drug_inventory_id` int DEFAULT NULL,
  `dose_id` int DEFAULT NULL,
  `min_weight` float DEFAULT NULL,
  `max_weight` float DEFAULT NULL,
  `date_created` datetime DEFAULT NULL,
  `date_updated` datetime DEFAULT NULL,
  `creator` int DEFAULT NULL,
  `voided` tinyint(1) NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `min_age` int DEFAULT NULL,
  `max_age` int DEFAULT NULL,
  `gender` varchar(255) DEFAULT 'MF',
  `course` varchar(255) DEFAULT NULL,
  `ingredient_active` tinyint(1) NOT NULL DEFAULT '0',
  PRIMARY KEY (`ingredient_id`)
) ENGINE=InnoDB AUTO_INCREMENT=542 DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `moh_regimen_ingredient_starter_packs`
--

DROP TABLE IF EXISTS `moh_regimen_ingredient_starter_packs`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `moh_regimen_ingredient_starter_packs` (
  `ingredient_id` int NOT NULL AUTO_INCREMENT,
  `regimen_id` int DEFAULT NULL,
  `drug_inventory_id` int DEFAULT NULL,
  `dose_id` int DEFAULT NULL,
  `min_weight` float DEFAULT NULL,
  `max_weight` float DEFAULT NULL,
  `date_created` datetime DEFAULT NULL,
  `date_updated` datetime DEFAULT NULL,
  `creator` int DEFAULT NULL,
  `voided` tinyint(1) NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  PRIMARY KEY (`ingredient_id`)
) ENGINE=InnoDB AUTO_INCREMENT=51 DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `moh_regimen_ingredient_tb_treatment`
--

DROP TABLE IF EXISTS `moh_regimen_ingredient_tb_treatment`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `moh_regimen_ingredient_tb_treatment` (
  `ingredient_id` int NOT NULL DEFAULT '0',
  `regimen_id` int DEFAULT NULL,
  `drug_inventory_id` int DEFAULT NULL,
  `dose_id` int DEFAULT NULL,
  `min_weight` float DEFAULT NULL,
  `max_weight` float DEFAULT NULL,
  `date_created` datetime DEFAULT NULL,
  `date_updated` datetime DEFAULT NULL,
  `creator` int DEFAULT NULL,
  `voided` tinyint(1) NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `moh_regimen_lookup`
--

DROP TABLE IF EXISTS `moh_regimen_lookup`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `moh_regimen_lookup` (
  `regimen_lookup_id` int NOT NULL AUTO_INCREMENT,
  `num_of_drug_combination` int DEFAULT NULL,
  `regimen_name` varchar(5) NOT NULL,
  `drug_inventory_id` int DEFAULT NULL,
  `date_created` datetime DEFAULT NULL,
  `date_updated` datetime DEFAULT NULL,
  `creator` int DEFAULT NULL,
  `voided` tinyint(1) NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  PRIMARY KEY (`regimen_lookup_id`)
) ENGINE=InnoDB AUTO_INCREMENT=50 DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `moh_regimen_name`
--

DROP TABLE IF EXISTS `moh_regimen_name`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `moh_regimen_name` (
  `regimen_name_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`regimen_name_id`)
) ENGINE=InnoDB AUTO_INCREMENT=46 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `moh_regimens`
--

DROP TABLE IF EXISTS `moh_regimens`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `moh_regimens` (
  `regimen_id` int NOT NULL AUTO_INCREMENT,
  `regimen_index` int NOT NULL,
  `description` text,
  `date_created` datetime DEFAULT NULL,
  `date_updated` datetime DEFAULT NULL,
  `creator` int NOT NULL,
  `voided` tinyint(1) NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  PRIMARY KEY (`regimen_id`)
) ENGINE=InnoDB AUTO_INCREMENT=21 DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `national_id`
--

DROP TABLE IF EXISTS `national_id`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `national_id` (
  `id` int NOT NULL AUTO_INCREMENT,
  `national_id` varchar(30) NOT NULL DEFAULT '',
  `assigned` tinyint(1) NOT NULL DEFAULT '0',
  `eds` tinyint(1) DEFAULT '0',
  `creator` int DEFAULT NULL,
  `date_issued` datetime DEFAULT NULL,
  `issued_to` text,
  PRIMARY KEY (`id`)
) ENGINE=MyISAM AUTO_INCREMENT=264255 DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `national_ids`
--

DROP TABLE IF EXISTS `national_ids`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `national_ids` (
  `id` int NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `note`
--

DROP TABLE IF EXISTS `note`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `note` (
  `note_id` int NOT NULL DEFAULT '0',
  `note_type` varchar(50) DEFAULT NULL,
  `patient_id` int DEFAULT NULL,
  `obs_id` int DEFAULT NULL,
  `encounter_id` int DEFAULT NULL,
  `text` text NOT NULL,
  `priority` int DEFAULT NULL,
  `parent` int DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`note_id`),
  UNIQUE KEY `note_uuid_index` (`uuid`),
  KEY `patient_note` (`patient_id`),
  KEY `obs_note` (`obs_id`),
  KEY `encounter_note` (`encounter_id`),
  KEY `user_who_created_note` (`creator`),
  KEY `user_who_changed_note` (`changed_by`),
  KEY `note_hierarchy` (`parent`),
  CONSTRAINT `encounter_note` FOREIGN KEY (`encounter_id`) REFERENCES `encounter` (`encounter_id`),
  CONSTRAINT `note_hierarchy` FOREIGN KEY (`parent`) REFERENCES `note` (`note_id`),
  CONSTRAINT `obs_note` FOREIGN KEY (`obs_id`) REFERENCES `obs` (`obs_id`),
  CONSTRAINT `patient_note` FOREIGN KEY (`patient_id`) REFERENCES `patient` (`patient_id`) ON UPDATE CASCADE,
  CONSTRAINT `user_who_changed_note` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_created_note` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `notification_alert`
--

DROP TABLE IF EXISTS `notification_alert`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `notification_alert` (
  `alert_id` int NOT NULL AUTO_INCREMENT,
  `text` text CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci NOT NULL,
  `satisfied_by_any` int NOT NULL DEFAULT '0',
  `alert_read` int NOT NULL DEFAULT '0',
  `date_to_expire` datetime DEFAULT NULL,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`alert_id`),
  UNIQUE KEY `notification_alert_uuid_index` (`uuid`),
  KEY `alert_creator` (`creator`),
  KEY `user_who_changed_alert` (`changed_by`),
  CONSTRAINT `alert_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_changed_alert` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `notification_alert_recipient`
--

DROP TABLE IF EXISTS `notification_alert_recipient`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `notification_alert_recipient` (
  `alert_id` int NOT NULL,
  `user_id` int NOT NULL,
  `alert_read` int NOT NULL DEFAULT '0',
  `date_changed` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `uuid` char(38) NOT NULL,
  `cleared` tinyint(1) DEFAULT '0',
  PRIMARY KEY (`alert_id`,`user_id`),
  KEY `alert_read_by_user` (`user_id`),
  KEY `id_of_alert` (`alert_id`),
  CONSTRAINT `alert_read_by_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`),
  CONSTRAINT `id_of_alert` FOREIGN KEY (`alert_id`) REFERENCES `notification_alert` (`alert_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `notification_template`
--

DROP TABLE IF EXISTS `notification_template`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `notification_template` (
  `template_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(50) DEFAULT NULL,
  `template` text,
  `subject` varchar(100) DEFAULT NULL,
  `sender` varchar(255) DEFAULT NULL,
  `recipients` varchar(512) DEFAULT NULL,
  `ordinal` int DEFAULT '0',
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`template_id`),
  UNIQUE KEY `notification_template_uuid_index` (`uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `notification_tracker`
--

DROP TABLE IF EXISTS `notification_tracker`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `notification_tracker` (
  `tracker_id` int NOT NULL AUTO_INCREMENT,
  `notification_name` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `description` text COLLATE utf8mb3_unicode_ci,
  `notification_response` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `notification_datetime` datetime NOT NULL,
  `patient_id` int NOT NULL,
  `user_id` int NOT NULL,
  PRIMARY KEY (`tracker_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `notification_tracker_user_activities`
--

DROP TABLE IF EXISTS `notification_tracker_user_activities`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `notification_tracker_user_activities` (
  `id` int NOT NULL AUTO_INCREMENT,
  `user_id` int NOT NULL,
  `login_datetime` datetime NOT NULL,
  `selected_activities` text COLLATE utf8mb3_unicode_ci,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `ntp_regimens`
--

DROP TABLE IF EXISTS `ntp_regimens`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `ntp_regimens` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `drug_id` bigint DEFAULT NULL,
  `am_dose` float DEFAULT NULL,
  `noon_dose` float DEFAULT '0',
  `pm_dose` float DEFAULT '0',
  `min_weight` float DEFAULT NULL,
  `max_weight` float DEFAULT NULL,
  `creator` int DEFAULT '0',
  `retired_by` float DEFAULT '0',
  `voided` int DEFAULT '0',
  `void_reason` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `index_ntp_regimens_on_drug_id` (`drug_id`)
) ENGINE=InnoDB AUTO_INCREMENT=74 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `obs`
--

DROP TABLE IF EXISTS `obs`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `obs` (
  `obs_id` int NOT NULL AUTO_INCREMENT,
  `person_id` int NOT NULL,
  `concept_id` int NOT NULL DEFAULT '0',
  `encounter_id` int DEFAULT NULL,
  `order_id` int DEFAULT NULL,
  `obs_datetime` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `location_id` varchar(255) DEFAULT NULL,
  `obs_group_id` int DEFAULT NULL,
  `accession_number` varchar(255) DEFAULT NULL,
  `value_group_id` int DEFAULT NULL,
  `value_boolean` tinyint(1) DEFAULT NULL,
  `value_coded` int DEFAULT NULL,
  `value_coded_name_id` int DEFAULT NULL,
  `value_drug` int DEFAULT NULL,
  `value_datetime` datetime DEFAULT NULL,
  `value_numeric` double DEFAULT NULL,
  `value_modifier` varchar(2) DEFAULT NULL,
  `value_text` text,
  `date_started` datetime DEFAULT NULL,
  `date_stopped` datetime DEFAULT NULL,
  `comments` varchar(255) DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `value_complex` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`obs_id`),
  UNIQUE KEY `obs_uuid_index` (`uuid`),
  KEY `answer_concept` (`value_coded`),
  KEY `encounter_observations` (`encounter_id`),
  KEY `obs_concept` (`concept_id`),
  KEY `obs_enterer` (`creator`),
  KEY `obs_location` (`location_id`),
  KEY `obs_order` (`order_id`),
  KEY `patient_obs` (`person_id`),
  KEY `user_who_voided_obs` (`voided_by`),
  KEY `answer_concept_drug` (`value_drug`),
  KEY `obs_grouping_id` (`obs_group_id`),
  KEY `obs_name_of_coded_value` (`value_coded_name_id`),
  KEY `obs_datetime_idx` (`obs_datetime`),
  KEY `idx_person_obs_answers_by_date` (`obs_datetime`,`person_id`,`concept_id`,`value_coded`),
  KEY `idx_person_obs_answer` (`person_id`,`concept_id`,`value_coded`),
  KEY `idx_obs_grouping` (`person_id`,`obs_group_id`,`value_coded`),
  CONSTRAINT `answer_concept` FOREIGN KEY (`value_coded`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `answer_concept_drug` FOREIGN KEY (`value_drug`) REFERENCES `drug` (`drug_id`),
  CONSTRAINT `encounter_observations` FOREIGN KEY (`encounter_id`) REFERENCES `encounter` (`encounter_id`),
  CONSTRAINT `obs_concept` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `obs_enterer` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `obs_grouping_id` FOREIGN KEY (`obs_group_id`) REFERENCES `obs` (`obs_id`),
  CONSTRAINT `obs_name_of_coded_value` FOREIGN KEY (`value_coded_name_id`) REFERENCES `concept_name` (`concept_name_id`),
  CONSTRAINT `obs_order` FOREIGN KEY (`order_id`) REFERENCES `orders` (`order_id`),
  CONSTRAINT `person_obs` FOREIGN KEY (`person_id`) REFERENCES `person` (`person_id`) ON UPDATE CASCADE,
  CONSTRAINT `user_who_voided_obs` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=208368 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `order_extension`
--

DROP TABLE IF EXISTS `order_extension`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `order_extension` (
  `order_extension_id` int NOT NULL AUTO_INCREMENT,
  `order_id` int NOT NULL,
  `value` varchar(50) NOT NULL DEFAULT '',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `voided` tinyint(1) NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`order_extension_id`),
  KEY `user_who_created_ext` (`creator`),
  KEY `user_who_retired_ext` (`voided_by`),
  KEY `retired_status` (`voided`),
  CONSTRAINT `user_who_created_extension` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_voided_extension` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `order_type`
--

DROP TABLE IF EXISTS `order_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `order_type` (
  `order_type_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL DEFAULT '',
  `description` varchar(255) NOT NULL DEFAULT '',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `retired` smallint NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`order_type_id`),
  UNIQUE KEY `order_type_uuid_index` (`uuid`),
  KEY `type_created_by` (`creator`),
  KEY `user_who_retired_order_type` (`retired_by`),
  KEY `retired_status` (`retired`),
  KEY `index_order_type_on_name` (`name`),
  CONSTRAINT `type_created_by` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_order_type` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=9 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `orders`
--

DROP TABLE IF EXISTS `orders`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `orders` (
  `order_id` int NOT NULL AUTO_INCREMENT,
  `order_type_id` int NOT NULL DEFAULT '0',
  `concept_id` int NOT NULL DEFAULT '0',
  `orderer` int DEFAULT '0',
  `encounter_id` int DEFAULT NULL,
  `instructions` text,
  `start_date` datetime DEFAULT NULL,
  `auto_expire_date` datetime DEFAULT NULL,
  `discontinued` smallint NOT NULL DEFAULT '0',
  `discontinued_date` datetime DEFAULT NULL,
  `discontinued_by` int DEFAULT NULL,
  `discontinued_reason` int DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `patient_id` int NOT NULL,
  `accession_number` varchar(255) DEFAULT NULL,
  `obs_id` int DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  `discontinued_reason_non_coded` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`order_id`),
  UNIQUE KEY `orders_uuid_index` (`uuid`),
  KEY `order_creator` (`creator`),
  KEY `orderer_not_drug` (`orderer`),
  KEY `orders_in_encounter` (`encounter_id`),
  KEY `type_of_order` (`order_type_id`),
  KEY `user_who_discontinued_order` (`discontinued_by`),
  KEY `user_who_voided_order` (`voided_by`),
  KEY `discontinued_because` (`discontinued_reason`),
  KEY `order_for_patient` (`patient_id`),
  KEY `obs_for_order` (`obs_id`),
  KEY `idx_order` (`order_type_id`,`concept_id`,`patient_id`,`start_date`),
  KEY `idx_order_expiry` (`order_type_id`,`auto_expire_date`),
  KEY `order_id_patient_id_temp` (`patient_id`,`order_id`),
  CONSTRAINT `discontinued_because` FOREIGN KEY (`discontinued_reason`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `obs_for_order` FOREIGN KEY (`obs_id`) REFERENCES `obs` (`obs_id`),
  CONSTRAINT `order_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `order_for_patient` FOREIGN KEY (`patient_id`) REFERENCES `patient` (`patient_id`) ON UPDATE CASCADE,
  CONSTRAINT `orderer_not_drug` FOREIGN KEY (`orderer`) REFERENCES `users` (`user_id`),
  CONSTRAINT `orders_in_encounter` FOREIGN KEY (`encounter_id`) REFERENCES `encounter` (`encounter_id`),
  CONSTRAINT `type_of_order` FOREIGN KEY (`order_type_id`) REFERENCES `order_type` (`order_type_id`),
  CONSTRAINT `user_who_discontinued_order` FOREIGN KEY (`discontinued_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_voided_order` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=36683 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `outpatients`
--

DROP TABLE IF EXISTS `outpatients`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `outpatients` (
  `id` int NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `patient`
--

DROP TABLE IF EXISTS `patient`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `patient` (
  `patient_id` int NOT NULL AUTO_INCREMENT,
  `tribe` int DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`patient_id`),
  KEY `belongs_to_tribe` (`tribe`),
  KEY `user_who_created_patient` (`creator`),
  KEY `user_who_voided_patient` (`voided_by`),
  KEY `user_who_changed_pat` (`changed_by`),
  CONSTRAINT `belongs_to_tribe` FOREIGN KEY (`tribe`) REFERENCES `tribe` (`tribe_id`),
  CONSTRAINT `person_id_for_patient` FOREIGN KEY (`patient_id`) REFERENCES `person` (`person_id`) ON UPDATE CASCADE,
  CONSTRAINT `user_who_changed_pat` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_created_patient` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_voided_patient` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=344391 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `patient_defaulted_dates`
--

DROP TABLE IF EXISTS `patient_defaulted_dates`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `patient_defaulted_dates` (
  `id` int NOT NULL AUTO_INCREMENT,
  `patient_id` int DEFAULT NULL,
  `order_id` int DEFAULT NULL,
  `drug_id` int DEFAULT NULL,
  `equivalent_daily_dose` float DEFAULT NULL,
  `amount_dispensed` int DEFAULT NULL,
  `quantity_given` int DEFAULT NULL,
  `start_date` date DEFAULT NULL,
  `end_date` date DEFAULT NULL,
  `defaulted_date` date DEFAULT NULL,
  `date_created` date DEFAULT '2025-11-05',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `patient_first_arv_amount_dispensed`
--

DROP TABLE IF EXISTS `patient_first_arv_amount_dispensed`;
/*!50001 DROP VIEW IF EXISTS `patient_first_arv_amount_dispensed`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `patient_first_arv_amount_dispensed` AS SELECT 
 1 AS `encounter_id`,
 1 AS `encounter_type`,
 1 AS `patient_id`,
 1 AS `provider_id`,
 1 AS `location_id`,
 1 AS `form_id`,
 1 AS `encounter_datetime`,
 1 AS `creator`,
 1 AS `date_created`,
 1 AS `voided`,
 1 AS `voided_by`,
 1 AS `date_voided`,
 1 AS `void_reason`,
 1 AS `uuid`,
 1 AS `changed_by`,
 1 AS `date_changed`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `patient_identifier`
--

DROP TABLE IF EXISTS `patient_identifier`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `patient_identifier` (
  `patient_identifier_id` int NOT NULL AUTO_INCREMENT,
  `patient_id` int NOT NULL DEFAULT '0',
  `identifier` varchar(50) NOT NULL DEFAULT '',
  `identifier_type` int NOT NULL DEFAULT '0',
  `preferred` smallint NOT NULL DEFAULT '0',
  `location_id` int NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`patient_identifier_id`),
  UNIQUE KEY `patient_identifier_uuid_index` (`uuid`),
  KEY `defines_identifier_type` (`identifier_type`),
  KEY `identifier_creator` (`creator`),
  KEY `identifier_voider` (`voided_by`),
  KEY `identifier_location` (`location_id`),
  KEY `identifier_name` (`identifier`),
  KEY `idx_patient_identifier_patient` (`patient_id`),
  KEY `index_patient_identifier_on_identifier_type_and_identifier` (`identifier_type`,`identifier`),
  KEY `index_pi_on_voided_and_identifier_type_and_identifier` (`voided`,`identifier_type`,`identifier`),
  CONSTRAINT `defines_identifier_type` FOREIGN KEY (`identifier_type`) REFERENCES `patient_identifier_type` (`patient_identifier_type_id`),
  CONSTRAINT `identifier_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `identifier_voider` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `identifies_patient` FOREIGN KEY (`patient_id`) REFERENCES `patient` (`patient_id`),
  CONSTRAINT `patient_identifier_ibfk_2` FOREIGN KEY (`location_id`) REFERENCES `location` (`location_id`)
) ENGINE=InnoDB AUTO_INCREMENT=836 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `patient_identifier_type`
--

DROP TABLE IF EXISTS `patient_identifier_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `patient_identifier_type` (
  `patient_identifier_type_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(50) NOT NULL DEFAULT '',
  `description` text NOT NULL,
  `format` varchar(50) DEFAULT NULL,
  `check_digit` smallint NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `required` smallint NOT NULL DEFAULT '0',
  `format_description` varchar(255) DEFAULT NULL,
  `validator` varchar(200) DEFAULT NULL,
  `retired` smallint NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`patient_identifier_type_id`),
  UNIQUE KEY `patient_identifier_type_uuid_index` (`uuid`),
  KEY `type_creator` (`creator`),
  KEY `user_who_retired_patient_identifier_type` (`retired_by`),
  KEY `retired_status` (`retired`),
  CONSTRAINT `type_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_patient_identifier_type` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=32 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `patient_pregnant_obs`
--

DROP TABLE IF EXISTS `patient_pregnant_obs`;
/*!50001 DROP VIEW IF EXISTS `patient_pregnant_obs`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `patient_pregnant_obs` AS SELECT 
 1 AS `obs_id`,
 1 AS `person_id`,
 1 AS `concept_id`,
 1 AS `encounter_id`,
 1 AS `order_id`,
 1 AS `obs_datetime`,
 1 AS `location_id`,
 1 AS `obs_group_id`,
 1 AS `accession_number`,
 1 AS `value_group_id`,
 1 AS `value_boolean`,
 1 AS `value_coded`,
 1 AS `value_coded_name_id`,
 1 AS `value_drug`,
 1 AS `value_datetime`,
 1 AS `value_numeric`,
 1 AS `value_modifier`,
 1 AS `value_text`,
 1 AS `date_started`,
 1 AS `date_stopped`,
 1 AS `comments`,
 1 AS `creator`,
 1 AS `date_created`,
 1 AS `voided`,
 1 AS `voided_by`,
 1 AS `date_voided`,
 1 AS `void_reason`,
 1 AS `value_complex`,
 1 AS `uuid`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `patient_program`
--

DROP TABLE IF EXISTS `patient_program`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `patient_program` (
  `patient_program_id` int NOT NULL AUTO_INCREMENT,
  `patient_id` int NOT NULL DEFAULT '0',
  `program_id` int NOT NULL DEFAULT '0',
  `date_enrolled` datetime DEFAULT NULL,
  `date_completed` datetime DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  `location_id` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`patient_program_id`),
  UNIQUE KEY `patient_program_uuid_index` (`uuid`),
  KEY `patient_in_program` (`patient_id`),
  KEY `program_for_patient` (`program_id`),
  KEY `patient_program_creator` (`creator`),
  KEY `user_who_changed` (`changed_by`),
  KEY `user_who_voided_patient_program` (`voided_by`),
  CONSTRAINT `patient_in_program` FOREIGN KEY (`patient_id`) REFERENCES `patient` (`patient_id`) ON UPDATE CASCADE,
  CONSTRAINT `patient_program_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `program_for_patient` FOREIGN KEY (`program_id`) REFERENCES `program` (`program_id`),
  CONSTRAINT `user_who_changed` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_voided_patient_program` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=4740 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `patient_service_waiting_time`
--

DROP TABLE IF EXISTS `patient_service_waiting_time`;
/*!50001 DROP VIEW IF EXISTS `patient_service_waiting_time`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `patient_service_waiting_time` AS SELECT 
 1 AS `patient_id`,
 1 AS `visit_date`,
 1 AS `start_time`,
 1 AS `finish_time`,
 1 AS `service_time`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `patient_state`
--

DROP TABLE IF EXISTS `patient_state`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `patient_state` (
  `patient_state_id` int NOT NULL AUTO_INCREMENT,
  `patient_program_id` int NOT NULL DEFAULT '0',
  `state` int NOT NULL DEFAULT '0',
  `start_date` date DEFAULT NULL,
  `end_date` date DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `uuid` varchar(38) NOT NULL,
  PRIMARY KEY (`patient_state_id`),
  UNIQUE KEY `patient_state_uuid_index` (`uuid`),
  UNIQUE KEY `uuid` (`uuid`),
  KEY `state_for_patient` (`state`),
  KEY `patient_program_for_state` (`patient_program_id`),
  KEY `patient_state_creator` (`creator`),
  KEY `patient_state_changer` (`changed_by`),
  KEY `patient_state_voider` (`voided_by`),
  CONSTRAINT `patient_program_for_state` FOREIGN KEY (`patient_program_id`) REFERENCES `patient_program` (`patient_program_id`),
  CONSTRAINT `patient_state_changer` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `patient_state_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `patient_state_voider` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `state_for_patient` FOREIGN KEY (`state`) REFERENCES `program_workflow_state` (`program_workflow_state_id`)
) ENGINE=InnoDB AUTO_INCREMENT=1115 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `patient_state_on_arvs`
--

DROP TABLE IF EXISTS `patient_state_on_arvs`;
/*!50001 DROP VIEW IF EXISTS `patient_state_on_arvs`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `patient_state_on_arvs` AS SELECT 
 1 AS `patient_state_id`,
 1 AS `patient_program_id`,
 1 AS `state`,
 1 AS `start_date`,
 1 AS `end_date`,
 1 AS `creator`,
 1 AS `date_created`,
 1 AS `changed_by`,
 1 AS `date_changed`,
 1 AS `voided`,
 1 AS `voided_by`,
 1 AS `date_voided`,
 1 AS `void_reason`,
 1 AS `uuid`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `patientflags_flag`
--

DROP TABLE IF EXISTS `patientflags_flag`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `patientflags_flag` (
  `flag_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `criteria` varchar(5000) NOT NULL,
  `message` varchar(255) NOT NULL,
  `enabled` tinyint(1) NOT NULL,
  `evaluator` varchar(255) NOT NULL,
  `description` varchar(1000) DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`flag_id`)
) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `patientflags_flag_tag`
--

DROP TABLE IF EXISTS `patientflags_flag_tag`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `patientflags_flag_tag` (
  `flag_id` int NOT NULL,
  `tag_id` int NOT NULL,
  KEY `flag_id` (`flag_id`),
  KEY `tag_id` (`tag_id`),
  CONSTRAINT `patientflags_flag_tag_ibfk_1` FOREIGN KEY (`flag_id`) REFERENCES `patientflags_flag` (`flag_id`),
  CONSTRAINT `patientflags_flag_tag_ibfk_2` FOREIGN KEY (`tag_id`) REFERENCES `patientflags_tag` (`tag_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `patientflags_tag`
--

DROP TABLE IF EXISTS `patientflags_tag`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `patientflags_tag` (
  `tag_id` int NOT NULL AUTO_INCREMENT,
  `tag` varchar(255) NOT NULL,
  `description` varchar(1000) DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`tag_id`)
) ENGINE=InnoDB AUTO_INCREMENT=5 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `patients_demographics`
--

DROP TABLE IF EXISTS `patients_demographics`;
/*!50001 DROP VIEW IF EXISTS `patients_demographics`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `patients_demographics` AS SELECT 
 1 AS `patient_id`,
 1 AS `given_name`,
 1 AS `family_name`,
 1 AS `middle_name`,
 1 AS `gender`,
 1 AS `birthdate_estimated`,
 1 AS `birthdate`,
 1 AS `home_district`,
 1 AS `current_district`,
 1 AS `landmark`,
 1 AS `current_residence`,
 1 AS `traditional_authority`,
 1 AS `date_enrolled`,
 1 AS `earliest_start_date`,
 1 AS `death_date`,
 1 AS `age_at_initiation`,
 1 AS `age_in_days`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `patients_for_location`
--

DROP TABLE IF EXISTS `patients_for_location`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `patients_for_location` (
  `patient_id` int NOT NULL,
  PRIMARY KEY (`patient_id`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `patients_on_arvs`
--

DROP TABLE IF EXISTS `patients_on_arvs`;
/*!50001 DROP VIEW IF EXISTS `patients_on_arvs`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `patients_on_arvs` AS SELECT 
 1 AS `patient_id`,
 1 AS `birthdate`,
 1 AS `earliest_start_date`,
 1 AS `death_date`,
 1 AS `gender`,
 1 AS `age_at_initiation`,
 1 AS `age_in_days`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `patients_to_merge`
--

DROP TABLE IF EXISTS `patients_to_merge`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `patients_to_merge` (
  `patient_id` int DEFAULT NULL,
  `to_merge_to_id` int DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `patients_with_has_transfer_letter_yes`
--

DROP TABLE IF EXISTS `patients_with_has_transfer_letter_yes`;
/*!50001 DROP VIEW IF EXISTS `patients_with_has_transfer_letter_yes`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `patients_with_has_transfer_letter_yes` AS SELECT 
 1 AS `person_id`,
 1 AS `gender`,
 1 AS `obs_datetime`,
 1 AS `date_created`,
 1 AS `earliest_start_date`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `person`
--

DROP TABLE IF EXISTS `person`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `person` (
  `person_id` int NOT NULL AUTO_INCREMENT,
  `gender` varchar(50) DEFAULT '',
  `birthdate` date DEFAULT NULL,
  `birthdate_estimated` smallint NOT NULL DEFAULT '0',
  `dead` smallint NOT NULL DEFAULT '0',
  `death_date` datetime DEFAULT NULL,
  `cause_of_death` int DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`person_id`),
  UNIQUE KEY `person_uuid_index` (`uuid`),
  KEY `user_who_created_patient` (`creator`),
  KEY `user_who_voided_patient` (`voided_by`),
  KEY `user_who_changed_pat` (`changed_by`),
  KEY `person_birthdate` (`birthdate`),
  KEY `person_death_date` (`death_date`),
  KEY `person_died_because` (`cause_of_death`),
  CONSTRAINT `person_died_because` FOREIGN KEY (`cause_of_death`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `user_who_changed_person` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_created_person` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_voided_person` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=344391 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `person_address`
--

DROP TABLE IF EXISTS `person_address`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `person_address` (
  `person_address_id` int NOT NULL AUTO_INCREMENT,
  `person_id` int DEFAULT NULL,
  `preferred` smallint NOT NULL DEFAULT '0',
  `address1` varchar(50) DEFAULT NULL,
  `address2` varchar(50) DEFAULT NULL,
  `city_village` varchar(50) DEFAULT NULL,
  `state_province` varchar(50) DEFAULT NULL,
  `postal_code` varchar(50) DEFAULT NULL,
  `country` varchar(50) DEFAULT NULL,
  `latitude` varchar(50) DEFAULT NULL,
  `longitude` varchar(50) DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `county_district` varchar(50) DEFAULT NULL,
  `neighborhood_cell` varchar(50) DEFAULT NULL,
  `region` varchar(50) DEFAULT NULL,
  `subregion` varchar(50) DEFAULT NULL,
  `township_division` varchar(50) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`person_address_id`),
  UNIQUE KEY `person_address_uuid_index` (`uuid`),
  KEY `patient_address_creator` (`creator`),
  KEY `patient_addresses` (`person_id`),
  KEY `patient_address_void` (`voided_by`),
  KEY `index_date_created_on_person_address` (`date_created` DESC),
  CONSTRAINT `address_for_person` FOREIGN KEY (`person_id`) REFERENCES `person` (`person_id`) ON UPDATE CASCADE,
  CONSTRAINT `patient_address_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `patient_address_void` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=381084 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `person_attribute`
--

DROP TABLE IF EXISTS `person_attribute`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `person_attribute` (
  `person_attribute_id` int NOT NULL AUTO_INCREMENT,
  `person_id` int NOT NULL DEFAULT '0',
  `value` varchar(120) NOT NULL DEFAULT '',
  `person_attribute_type_id` int NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`person_attribute_id`),
  UNIQUE KEY `person_attribute_uuid_index` (`uuid`),
  KEY `identifies_person` (`person_id`),
  KEY `defines_attribute_type` (`person_attribute_type_id`),
  KEY `attribute_creator` (`creator`),
  KEY `attribute_changer` (`changed_by`),
  KEY `attribute_voider` (`voided_by`),
  CONSTRAINT `attribute_changer` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `attribute_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `attribute_voider` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `defines_attribute_type` FOREIGN KEY (`person_attribute_type_id`) REFERENCES `person_attribute_type` (`person_attribute_type_id`),
  CONSTRAINT `identifies_person` FOREIGN KEY (`person_id`) REFERENCES `person` (`person_id`)
) ENGINE=InnoDB AUTO_INCREMENT=548812 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `person_attribute_type`
--

DROP TABLE IF EXISTS `person_attribute_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `person_attribute_type` (
  `person_attribute_type_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(50) NOT NULL DEFAULT '',
  `description` text NOT NULL,
  `format` varchar(50) DEFAULT NULL,
  `foreign_key` int DEFAULT NULL,
  `searchable` smallint NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `retired` smallint NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `edit_privilege` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  `sort_weight` double DEFAULT NULL,
  PRIMARY KEY (`person_attribute_type_id`),
  UNIQUE KEY `person_attribute_type_uuid_index` (`uuid`),
  KEY `name_of_attribute` (`name`),
  KEY `type_creator` (`creator`),
  KEY `attribute_type_changer` (`changed_by`),
  KEY `attribute_is_searchable` (`searchable`),
  KEY `user_who_retired_person_attribute_type` (`retired_by`),
  KEY `person_attribute_type_retired_status` (`retired`),
  KEY `privilege_which_can_edit` (`edit_privilege`),
  CONSTRAINT `attribute_type_changer` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `attribute_type_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `privilege_which_can_edit` FOREIGN KEY (`edit_privilege`) REFERENCES `privilege` (`privilege`),
  CONSTRAINT `user_who_retired_person_attribute_type` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=40 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `person_name`
--

DROP TABLE IF EXISTS `person_name`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `person_name` (
  `person_name_id` int NOT NULL AUTO_INCREMENT,
  `preferred` smallint NOT NULL DEFAULT '0',
  `person_id` int DEFAULT NULL,
  `prefix` varchar(50) DEFAULT NULL,
  `given_name` varchar(50) DEFAULT NULL,
  `middle_name` varchar(50) DEFAULT NULL,
  `family_name_prefix` varchar(50) DEFAULT NULL,
  `family_name` varchar(50) DEFAULT NULL,
  `family_name2` varchar(50) DEFAULT NULL,
  `family_name_suffix` varchar(50) DEFAULT NULL,
  `degree` varchar(50) DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`person_name_id`),
  UNIQUE KEY `person_name_uuid_index` (`uuid`),
  KEY `name_for_patient` (`person_id`),
  KEY `user_who_made_name` (`creator`),
  KEY `user_who_voided_name` (`voided_by`),
  KEY `first_name` (`given_name`),
  KEY `middle_name` (`middle_name`),
  KEY `last_name` (`family_name`),
  KEY `family_name2` (`family_name2`),
  CONSTRAINT `name for person` FOREIGN KEY (`person_id`) REFERENCES `person` (`person_id`) ON UPDATE CASCADE,
  CONSTRAINT `user_who_made_name` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_voided_name` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=305061 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `person_name_code`
--

DROP TABLE IF EXISTS `person_name_code`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `person_name_code` (
  `person_name_code_id` int NOT NULL AUTO_INCREMENT,
  `person_name_id` int DEFAULT NULL,
  `given_name_code` varchar(50) DEFAULT NULL,
  `middle_name_code` varchar(50) DEFAULT NULL,
  `family_name_code` varchar(50) DEFAULT NULL,
  `family_name2_code` varchar(50) DEFAULT NULL,
  `family_name_suffix_code` varchar(50) DEFAULT NULL,
  PRIMARY KEY (`person_name_code_id`),
  KEY `name_for_patient` (`person_name_id`),
  KEY `given_name_code` (`given_name_code`),
  KEY `middle_name_code` (`middle_name_code`),
  KEY `family_name_code` (`family_name_code`),
  KEY `given_family_name_code` (`given_name_code`,`family_name_code`),
  CONSTRAINT `code for name` FOREIGN KEY (`person_name_id`) REFERENCES `person_name` (`person_name_id`) ON UPDATE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=47329 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `pharmacies`
--

DROP TABLE IF EXISTS `pharmacies`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `pharmacies` (
  `id` int NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `pharmacy_batch_item_reallocations`
--

DROP TABLE IF EXISTS `pharmacy_batch_item_reallocations`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `pharmacy_batch_item_reallocations` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `reallocation_code` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `batch_item_id` int DEFAULT NULL,
  `quantity` float DEFAULT NULL,
  `location_id` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `reallocation_type` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `date` date DEFAULT NULL,
  `date_created` datetime NOT NULL,
  `creator` int NOT NULL,
  `date_changed` datetime NOT NULL,
  `voided` smallint DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `voided_by` int DEFAULT NULL,
  `void_reason` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `index_pharmacy_batch_item_reallocations_on_reallocation_type` (`reallocation_type`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `pharmacy_batch_items`
--

DROP TABLE IF EXISTS `pharmacy_batch_items`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `pharmacy_batch_items` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `pharmacy_batch_id` int DEFAULT NULL,
  `drug_id` int DEFAULT NULL,
  `delivered_quantity` float DEFAULT NULL,
  `current_quantity` float DEFAULT NULL,
  `delivery_date` date DEFAULT NULL,
  `expiry_date` date DEFAULT NULL,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `date_changed` datetime DEFAULT CURRENT_TIMESTAMP,
  `voided` tinyint(1) DEFAULT NULL,
  `voided_by` int DEFAULT NULL,
  `void_reason` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `changed_by` int DEFAULT NULL,
  `pack_size` int DEFAULT NULL,
  `barcode` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `product_code` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `unit_doses` float DEFAULT NULL,
  `manufacture` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `dosage_form` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `pharmacy_batch_vvms`
--

DROP TABLE IF EXISTS `pharmacy_batch_vvms`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `pharmacy_batch_vvms` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `vvm` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `batch_item_id` int DEFAULT NULL,
  `voided` tinyint(1) DEFAULT NULL,
  `voided_by` int DEFAULT NULL,
  `void_reason` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `pharmacy_batches`
--

DROP TABLE IF EXISTS `pharmacy_batches`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `pharmacy_batches` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `batch_number` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `date_changed` datetime DEFAULT NULL,
  `voided` tinyint(1) DEFAULT NULL,
  `voided_by` int DEFAULT NULL,
  `void_reason` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `changed_by` int DEFAULT NULL,
  `location_id` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `fk_rails_09e680ca40` (`location_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `pharmacy_encounter_type`
--

DROP TABLE IF EXISTS `pharmacy_encounter_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `pharmacy_encounter_type` (
  `pharmacy_encounter_type_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(50) NOT NULL,
  `description` text NOT NULL,
  `format` varchar(50) DEFAULT NULL,
  `foreign_key` int DEFAULT NULL,
  `searchable` tinyint(1) DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(225) DEFAULT NULL,
  PRIMARY KEY (`pharmacy_encounter_type_id`)
) ENGINE=MyISAM AUTO_INCREMENT=6 DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `pharmacy_obs`
--

DROP TABLE IF EXISTS `pharmacy_obs`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `pharmacy_obs` (
  `pharmacy_module_id` int NOT NULL AUTO_INCREMENT,
  `pharmacy_encounter_type` int NOT NULL DEFAULT '0',
  `quantity` double DEFAULT NULL,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `voided` tinyint(1) NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(225) DEFAULT NULL,
  `batch_item_id` int DEFAULT NULL,
  `dispensation_obs_id` int DEFAULT NULL,
  `transaction_reason` text,
  `transaction_date` date DEFAULT NULL,
  `stock_verification_id` bigint DEFAULT NULL,
  `obs_group_id` int DEFAULT NULL,
  PRIMARY KEY (`pharmacy_module_id`),
  KEY `fk_rails_c51641b979` (`dispensation_obs_id`),
  KEY `index_pharmacy_obs_on_stock_verification_id` (`stock_verification_id`),
  KEY `fk_rails_353402f537` (`obs_group_id`),
  CONSTRAINT `fk_rails_353402f537` FOREIGN KEY (`obs_group_id`) REFERENCES `pharmacy_obs` (`pharmacy_module_id`),
  CONSTRAINT `fk_rails_7f4aa3b94b` FOREIGN KEY (`stock_verification_id`) REFERENCES `pharmacy_stock_verifications` (`id`),
  CONSTRAINT `fk_rails_c51641b979` FOREIGN KEY (`dispensation_obs_id`) REFERENCES `obs` (`obs_id`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `pharmacy_stock_balances`
--

DROP TABLE IF EXISTS `pharmacy_stock_balances`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `pharmacy_stock_balances` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `drug_id` bigint NOT NULL,
  `pack_size` int NOT NULL,
  `open_balance` float DEFAULT '0',
  `close_balance` float DEFAULT '0',
  `transaction_date` date NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `index_pharmacy_stock_balances_on_drug_id` (`drug_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `pharmacy_stock_verifications`
--

DROP TABLE IF EXISTS `pharmacy_stock_verifications`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `pharmacy_stock_verifications` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `reason` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `verification_date` datetime DEFAULT NULL,
  `creator` int DEFAULT NULL,
  `date_created` datetime DEFAULT NULL,
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `voided` tinyint(1) DEFAULT NULL,
  `voided_by` int DEFAULT NULL,
  `void_reason` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `potential_duplicates`
--

DROP TABLE IF EXISTS `potential_duplicates`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `potential_duplicates` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `patient_id_a` int NOT NULL,
  `patient_id_b` int NOT NULL,
  `match_percentage` int DEFAULT NULL,
  `merge_status` tinyint(1) NOT NULL DEFAULT '0',
  `voided` tinyint(1) NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime(6) DEFAULT NULL,
  `void_reason` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `changed_by` int DEFAULT NULL,
  `uuid` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  `match_type` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `index_potential_duplicates_on_patient_id_a` (`patient_id_a`),
  KEY `index_potential_duplicates_on_patient_id_b` (`patient_id_b`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `privilege`
--

DROP TABLE IF EXISTS `privilege`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `privilege` (
  `privilege` varchar(50) NOT NULL DEFAULT '',
  `description` varchar(250) NOT NULL DEFAULT '',
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`privilege`),
  UNIQUE KEY `privilege_uuid_index` (`uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `program`
--

DROP TABLE IF EXISTS `program`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `program` (
  `program_id` int NOT NULL AUTO_INCREMENT,
  `concept_id` int NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `retired` smallint NOT NULL DEFAULT '0',
  `name` varchar(50) NOT NULL,
  `description` varchar(500) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`program_id`),
  UNIQUE KEY `program_uuid_index` (`uuid`),
  KEY `program_concept` (`concept_id`),
  KEY `program_creator` (`creator`),
  KEY `user_who_changed_program` (`changed_by`),
  CONSTRAINT `program_concept` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `program_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_changed_program` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=35 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `program_encounter`
--

DROP TABLE IF EXISTS `program_encounter`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `program_encounter` (
  `program_encounter_id` int NOT NULL AUTO_INCREMENT,
  `patient_id` int DEFAULT NULL,
  `date_time` datetime DEFAULT NULL,
  `program_id` int DEFAULT NULL,
  PRIMARY KEY (`program_encounter_id`)
) ENGINE=InnoDB AUTO_INCREMENT=56 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `program_encounter_details`
--

DROP TABLE IF EXISTS `program_encounter_details`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `program_encounter_details` (
  `id` int NOT NULL AUTO_INCREMENT,
  `encounter_id` int DEFAULT NULL,
  `program_encounter_id` int DEFAULT NULL,
  `program_id` int DEFAULT NULL,
  `voided` int DEFAULT '0',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=595 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `program_encounter_type_map`
--

DROP TABLE IF EXISTS `program_encounter_type_map`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `program_encounter_type_map` (
  `program_encounter_type_map_id` int NOT NULL AUTO_INCREMENT,
  `program_id` int DEFAULT NULL,
  `encounter_type_id` int DEFAULT NULL,
  PRIMARY KEY (`program_encounter_type_map_id`),
  KEY `program_mapping` (`program_id`,`encounter_type_id`),
  KEY `referenced_encounter_type` (`encounter_type_id`),
  CONSTRAINT `referenced_encounter_type` FOREIGN KEY (`encounter_type_id`) REFERENCES `encounter_type` (`encounter_type_id`),
  CONSTRAINT `referenced_program_encounter_type_map` FOREIGN KEY (`program_id`) REFERENCES `program` (`program_id`)
) ENGINE=InnoDB AUTO_INCREMENT=15 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `program_location_restriction`
--

DROP TABLE IF EXISTS `program_location_restriction`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `program_location_restriction` (
  `program_location_restriction_id` int NOT NULL AUTO_INCREMENT,
  `program_id` int DEFAULT NULL,
  `location_id` int DEFAULT NULL,
  PRIMARY KEY (`program_location_restriction_id`),
  KEY `program_mapping` (`program_id`,`location_id`),
  KEY `referenced_location` (`location_id`),
  CONSTRAINT `referenced_location` FOREIGN KEY (`location_id`) REFERENCES `location` (`location_id`),
  CONSTRAINT `referenced_program` FOREIGN KEY (`program_id`) REFERENCES `program` (`program_id`)
) ENGINE=InnoDB AUTO_INCREMENT=9 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `program_orders_map`
--

DROP TABLE IF EXISTS `program_orders_map`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `program_orders_map` (
  `program_orders_map_id` int NOT NULL AUTO_INCREMENT,
  `program_id` int DEFAULT NULL,
  `concept_id` int DEFAULT NULL,
  PRIMARY KEY (`program_orders_map_id`),
  KEY `program_mapping` (`program_id`,`concept_id`),
  KEY `referenced_concept_id` (`concept_id`),
  CONSTRAINT `referenced_concept_id` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `referenced_program_orders_type_map` FOREIGN KEY (`program_id`) REFERENCES `program` (`program_id`)
) ENGINE=InnoDB AUTO_INCREMENT=44 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `program_patient_identifier_type_map`
--

DROP TABLE IF EXISTS `program_patient_identifier_type_map`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `program_patient_identifier_type_map` (
  `program_patient_identifier_type_map_id` int NOT NULL AUTO_INCREMENT,
  `program_id` int DEFAULT NULL,
  `patient_identifier_type_id` int DEFAULT NULL,
  PRIMARY KEY (`program_patient_identifier_type_map_id`),
  KEY `program_mapping` (`program_id`,`patient_identifier_type_id`),
  KEY `referenced_patient_identifier_type` (`patient_identifier_type_id`),
  CONSTRAINT `referenced_patient_identifier_type` FOREIGN KEY (`patient_identifier_type_id`) REFERENCES `patient_identifier_type` (`patient_identifier_type_id`),
  CONSTRAINT `referenced_program_patient_identifier_type_map` FOREIGN KEY (`program_id`) REFERENCES `program` (`program_id`)
) ENGINE=InnoDB AUTO_INCREMENT=7 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `program_relationship_type_map`
--

DROP TABLE IF EXISTS `program_relationship_type_map`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `program_relationship_type_map` (
  `program_relationship_type_map_id` int NOT NULL AUTO_INCREMENT,
  `program_id` int DEFAULT NULL,
  `relationship_type_id` int DEFAULT NULL,
  PRIMARY KEY (`program_relationship_type_map_id`),
  KEY `program_mapping` (`program_id`,`relationship_type_id`),
  KEY `referenced_relationship_type` (`relationship_type_id`),
  CONSTRAINT `referenced_program_relationship_type_map` FOREIGN KEY (`program_id`) REFERENCES `program` (`program_id`),
  CONSTRAINT `referenced_relationship_type` FOREIGN KEY (`relationship_type_id`) REFERENCES `relationship_type` (`relationship_type_id`)
) ENGINE=InnoDB AUTO_INCREMENT=9 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `program_workflow`
--

DROP TABLE IF EXISTS `program_workflow`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `program_workflow` (
  `program_workflow_id` int NOT NULL AUTO_INCREMENT,
  `program_id` int NOT NULL DEFAULT '0',
  `concept_id` int NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `retired` smallint NOT NULL DEFAULT '0',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`program_workflow_id`),
  UNIQUE KEY `program_workflow_uuid_index` (`uuid`),
  KEY `program_for_workflow` (`program_id`),
  KEY `workflow_concept` (`concept_id`),
  KEY `workflow_creator` (`creator`),
  KEY `workflow_voided_by` (`changed_by`),
  CONSTRAINT `program_for_workflow` FOREIGN KEY (`program_id`) REFERENCES `program` (`program_id`),
  CONSTRAINT `workflow_changed_by` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `workflow_concept` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `workflow_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=59 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `program_workflow_state`
--

DROP TABLE IF EXISTS `program_workflow_state`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `program_workflow_state` (
  `program_workflow_state_id` int NOT NULL AUTO_INCREMENT,
  `program_workflow_id` int NOT NULL DEFAULT '0',
  `concept_id` int NOT NULL DEFAULT '0',
  `initial` smallint NOT NULL DEFAULT '0',
  `terminal` smallint NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `retired` smallint NOT NULL DEFAULT '0',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`program_workflow_state_id`),
  UNIQUE KEY `program_workflow_state_uuid_index` (`uuid`),
  KEY `workflow_for_state` (`program_workflow_id`),
  KEY `state_concept` (`concept_id`),
  KEY `state_creator` (`creator`),
  KEY `state_voided_by` (`changed_by`),
  CONSTRAINT `state_changed_by` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `state_concept` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`),
  CONSTRAINT `state_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `workflow_for_state` FOREIGN KEY (`program_workflow_id`) REFERENCES `program_workflow` (`program_workflow_id`)
) ENGINE=InnoDB AUTO_INCREMENT=215 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `radiology_accession_number_counters`
--

DROP TABLE IF EXISTS `radiology_accession_number_counters`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `radiology_accession_number_counters` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `date` date DEFAULT NULL,
  `value` bigint DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `index_radiology_accession_number_counters_on_date` (`date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `reason_for_art_eligibility_obs`
--

DROP TABLE IF EXISTS `reason_for_art_eligibility_obs`;
/*!50001 DROP VIEW IF EXISTS `reason_for_art_eligibility_obs`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `reason_for_art_eligibility_obs` AS SELECT 
 1 AS `person_id`,
 1 AS `concept_id`,
 1 AS `obs_datetime`,
 1 AS `name`*/;
SET character_set_client = @saved_cs_client;

--
-- Temporary view structure for view `reason_for_eligibility_obs`
--

DROP TABLE IF EXISTS `reason_for_eligibility_obs`;
/*!50001 DROP VIEW IF EXISTS `reason_for_eligibility_obs`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `reason_for_eligibility_obs` AS SELECT 
 1 AS `patient_id`,
 1 AS `reason_for_eligibility`,
 1 AS `obs_datetime`,
 1 AS `earliest_start_date`,
 1 AS `date_enrolled`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `record_sync_statuses`
--

DROP TABLE IF EXISTS `record_sync_statuses`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `record_sync_statuses` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `record_type_id` int NOT NULL,
  `record_id` int NOT NULL,
  `record_doc_id` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  `database` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_record_type_id` (`record_type_id`),
  KEY `idx_record_id` (`record_id`),
  KEY `idx_database` (`database`),
  KEY `idx_database_record_type_id` (`record_type_id`,`record_id`,`database`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `record_types`
--

DROP TABLE IF EXISTS `record_types`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `record_types` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `name` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=19 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `regimen`
--

DROP TABLE IF EXISTS `regimen`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `regimen` (
  `regimen_id` int NOT NULL AUTO_INCREMENT,
  `concept_id` int NOT NULL DEFAULT '0',
  `regimen_index` varchar(5) DEFAULT NULL,
  `min_weight` float NOT NULL DEFAULT '0',
  `max_weight` float NOT NULL DEFAULT '200',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `retired` smallint NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `program_id` int NOT NULL DEFAULT '0',
  PRIMARY KEY (`regimen_id`),
  KEY `map_concept` (`concept_id`),
  CONSTRAINT `map_concept` FOREIGN KEY (`concept_id`) REFERENCES `concept` (`concept_id`)
) ENGINE=InnoDB AUTO_INCREMENT=247 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `regimen_drug_order`
--

DROP TABLE IF EXISTS `regimen_drug_order`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `regimen_drug_order` (
  `regimen_drug_order_id` int NOT NULL AUTO_INCREMENT,
  `regimen_id` int NOT NULL DEFAULT '0',
  `drug_inventory_id` int DEFAULT '0',
  `dose` double DEFAULT NULL,
  `equivalent_daily_dose` double DEFAULT NULL,
  `units` varchar(255) DEFAULT NULL,
  `frequency` varchar(255) DEFAULT NULL,
  `prn` tinyint(1) NOT NULL DEFAULT '0',
  `complex` tinyint(1) NOT NULL DEFAULT '0',
  `quantity` int DEFAULT NULL,
  `instructions` text,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`regimen_drug_order_id`),
  UNIQUE KEY `regimen_drug_order_uuid_index` (`uuid`),
  KEY `regimen_drug_order_creator` (`creator`),
  KEY `user_who_voided_regimen_drug_order` (`voided_by`),
  KEY `map_regimen` (`regimen_id`),
  KEY `map_drug_inventory` (`drug_inventory_id`),
  CONSTRAINT `map_drug_inventory` FOREIGN KEY (`drug_inventory_id`) REFERENCES `drug` (`drug_id`),
  CONSTRAINT `map_regimen` FOREIGN KEY (`regimen_id`) REFERENCES `regimen` (`regimen_id`),
  CONSTRAINT `regimen_drug_order_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_voided_regimen_drug_order` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=426 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `regimen_observation`
--

DROP TABLE IF EXISTS `regimen_observation`;
/*!50001 DROP VIEW IF EXISTS `regimen_observation`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `regimen_observation` AS SELECT 
 1 AS `obs_id`,
 1 AS `person_id`,
 1 AS `concept_id`,
 1 AS `encounter_id`,
 1 AS `order_id`,
 1 AS `obs_datetime`,
 1 AS `location_id`,
 1 AS `obs_group_id`,
 1 AS `accession_number`,
 1 AS `value_group_id`,
 1 AS `value_boolean`,
 1 AS `value_coded`,
 1 AS `value_coded_name_id`,
 1 AS `value_drug`,
 1 AS `value_datetime`,
 1 AS `value_numeric`,
 1 AS `value_modifier`,
 1 AS `value_text`,
 1 AS `date_started`,
 1 AS `date_stopped`,
 1 AS `comments`,
 1 AS `creator`,
 1 AS `date_created`,
 1 AS `voided`,
 1 AS `voided_by`,
 1 AS `date_voided`,
 1 AS `void_reason`,
 1 AS `value_complex`,
 1 AS `uuid`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `region`
--

DROP TABLE IF EXISTS `region`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `region` (
  `region_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL DEFAULT '',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`region_id`),
  KEY `user_who_created_region` (`creator`),
  KEY `user_who_retired_region` (`retired_by`),
  KEY `retired_status` (`retired`),
  CONSTRAINT `user_who_created_region` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_region` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=5 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `regions`
--

DROP TABLE IF EXISTS `regions`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `regions` (
  `id` int NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `relationship`
--

DROP TABLE IF EXISTS `relationship`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `relationship` (
  `relationship_id` int NOT NULL AUTO_INCREMENT,
  `person_a` int NOT NULL,
  `relationship` int NOT NULL DEFAULT '0',
  `person_b` int NOT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) DEFAULT NULL,
  PRIMARY KEY (`relationship_id`),
  UNIQUE KEY `relationship_uuid_index` (`uuid`),
  KEY `related_person` (`person_a`),
  KEY `related_relative` (`person_b`),
  KEY `relationship_type` (`relationship`),
  KEY `relation_creator` (`creator`),
  KEY `relation_voider` (`voided_by`),
  CONSTRAINT `person_a` FOREIGN KEY (`person_a`) REFERENCES `person` (`person_id`) ON UPDATE CASCADE,
  CONSTRAINT `person_b` FOREIGN KEY (`person_b`) REFERENCES `person` (`person_id`) ON UPDATE CASCADE,
  CONSTRAINT `relation_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `relation_voider` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `relationship_type_id` FOREIGN KEY (`relationship`) REFERENCES `relationship_type` (`relationship_type_id`)
) ENGINE=InnoDB AUTO_INCREMENT=35543 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `relationship_type`
--

DROP TABLE IF EXISTS `relationship_type`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `relationship_type` (
  `relationship_type_id` int NOT NULL AUTO_INCREMENT,
  `a_is_to_b` varchar(50) NOT NULL,
  `b_is_to_a` varchar(50) NOT NULL,
  `preferred` int NOT NULL DEFAULT '0',
  `weight` int NOT NULL DEFAULT '0',
  `description` varchar(255) NOT NULL DEFAULT '',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `uuid` char(38) NOT NULL,
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`relationship_type_id`),
  UNIQUE KEY `relationship_type_uuid_index` (`uuid`),
  KEY `user_who_created_rel` (`creator`),
  KEY `user_who_retired_relationship_type` (`retired_by`),
  CONSTRAINT `user_who_created_rel` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_relationship_type` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=14 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `report_def`
--

DROP TABLE IF EXISTS `report_def`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `report_def` (
  `report_def_id` int NOT NULL AUTO_INCREMENT,
  `name` mediumtext NOT NULL,
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `creator` int NOT NULL DEFAULT '0',
  PRIMARY KEY (`report_def_id`),
  KEY `User who created report_def` (`creator`),
  CONSTRAINT `User who created report_def` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=6 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `report_object`
--

DROP TABLE IF EXISTS `report_object`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `report_object` (
  `report_object_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `description` varchar(1000) DEFAULT NULL,
  `report_object_type` varchar(255) NOT NULL,
  `report_object_sub_type` varchar(255) NOT NULL,
  `xml_data` text,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL,
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `voided` smallint NOT NULL DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`report_object_id`),
  UNIQUE KEY `report_object_uuid_index` (`uuid`),
  KEY `report_object_creator` (`creator`),
  KEY `user_who_changed_report_object` (`changed_by`),
  KEY `user_who_voided_report_object` (`voided_by`),
  CONSTRAINT `report_object_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_changed_report_object` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_voided_report_object` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `report_schema_xml`
--

DROP TABLE IF EXISTS `report_schema_xml`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `report_schema_xml` (
  `report_schema_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `description` text NOT NULL,
  `xml_data` mediumtext NOT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`report_schema_id`),
  UNIQUE KEY `report_schema_xml_uuid_index` (`uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `reporting_report_design`
--

DROP TABLE IF EXISTS `reporting_report_design`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `reporting_report_design` (
  `id` int NOT NULL AUTO_INCREMENT,
  `uuid` char(38) NOT NULL,
  `name` varchar(255) NOT NULL,
  `description` varchar(1000) DEFAULT NULL,
  `report_definition_id` int NOT NULL DEFAULT '0',
  `renderer_type` varchar(255) NOT NULL,
  `properties` text,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `start_date` date DEFAULT NULL,
  `end_date` date DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `report_definition_id for reporting_report_design` (`report_definition_id`),
  KEY `creator for reporting_report_design` (`creator`),
  KEY `changed_by for reporting_report_design` (`changed_by`),
  KEY `retired_by for reporting_report_design` (`retired_by`),
  CONSTRAINT `changed_by for reporting_report_design` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `creator for reporting_report_design` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `report_definition_id for reporting_report_design` FOREIGN KEY (`report_definition_id`) REFERENCES `report_def` (`report_def_id`),
  CONSTRAINT `retired_by for reporting_report_design` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=6 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `reporting_report_design_resource`
--

DROP TABLE IF EXISTS `reporting_report_design_resource`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `reporting_report_design_resource` (
  `id` int NOT NULL AUTO_INCREMENT,
  `uuid` char(38) NOT NULL,
  `name` varchar(255) NOT NULL,
  `description` varchar(1000) DEFAULT NULL,
  `report_design_id` int NOT NULL DEFAULT '0',
  `content_type` varchar(50) DEFAULT NULL,
  `extension` varchar(20) DEFAULT NULL,
  `contents` longblob,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `indicator_name` varchar(255) DEFAULT NULL,
  `indicator_short_name` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `report_design_id for reporting_report_design_resource` (`report_design_id`),
  KEY `creator for reporting_report_design_resource` (`creator`),
  KEY `changed_by for reporting_report_design_resource` (`changed_by`),
  KEY `retired_by for reporting_report_design_resource` (`retired_by`),
  CONSTRAINT `changed_by for reporting_report_design_resource` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `creator for reporting_report_design_resource` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `report_design_id for reporting_report_design_resource` FOREIGN KEY (`report_design_id`) REFERENCES `reporting_report_design` (`id`),
  CONSTRAINT `retired_by for reporting_report_design_resource` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=11 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `role`
--

DROP TABLE IF EXISTS `role`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `role` (
  `role` varchar(50) NOT NULL DEFAULT '',
  `description` varchar(255) NOT NULL DEFAULT '',
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`role`),
  UNIQUE KEY `role_uuid_index` (`uuid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `role_privilege`
--

DROP TABLE IF EXISTS `role_privilege`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `role_privilege` (
  `role` varchar(50) NOT NULL DEFAULT '',
  `privilege` varchar(50) NOT NULL DEFAULT '',
  PRIMARY KEY (`privilege`,`role`),
  KEY `role_privilege` (`role`),
  CONSTRAINT `privilege_definitons` FOREIGN KEY (`privilege`) REFERENCES `privilege` (`privilege`),
  CONSTRAINT `role_privilege` FOREIGN KEY (`role`) REFERENCES `role` (`role`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `role_role`
--

DROP TABLE IF EXISTS `role_role`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `role_role` (
  `parent_role` varchar(50) NOT NULL DEFAULT '',
  `child_role` varchar(255) NOT NULL DEFAULT '',
  PRIMARY KEY (`parent_role`,`child_role`),
  KEY `inherited_role` (`child_role`),
  CONSTRAINT `inherited_role` FOREIGN KEY (`child_role`) REFERENCES `role` (`role`),
  CONSTRAINT `parent_role` FOREIGN KEY (`parent_role`) REFERENCES `role` (`role`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `scheduler_task_config`
--

DROP TABLE IF EXISTS `scheduler_task_config`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `scheduler_task_config` (
  `task_config_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `description` varchar(1024) DEFAULT NULL,
  `schedulable_class` text,
  `start_time` datetime DEFAULT NULL,
  `start_time_pattern` varchar(50) DEFAULT NULL,
  `repeat_interval` int NOT NULL DEFAULT '0',
  `start_on_startup` int NOT NULL DEFAULT '0',
  `started` int NOT NULL DEFAULT '0',
  `created_by` int DEFAULT '0',
  `date_created` datetime DEFAULT '2005-01-01 00:00:00',
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  `last_execution_time` datetime DEFAULT NULL,
  PRIMARY KEY (`task_config_id`),
  UNIQUE KEY `scheduler_task_config_uuid_index` (`uuid`),
  KEY `schedule_creator` (`created_by`),
  KEY `schedule_changer` (`changed_by`),
  CONSTRAINT `scheduler_changer` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `scheduler_creator` FOREIGN KEY (`created_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=8 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `scheduler_task_config_property`
--

DROP TABLE IF EXISTS `scheduler_task_config_property`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `scheduler_task_config_property` (
  `task_config_property_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `value` text,
  `task_config_id` int DEFAULT NULL,
  PRIMARY KEY (`task_config_property_id`),
  KEY `task_config` (`task_config_id`),
  CONSTRAINT `task_config_for_property` FOREIGN KEY (`task_config_id`) REFERENCES `scheduler_task_config` (`task_config_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `schema_info`
--

DROP TABLE IF EXISTS `schema_info`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `schema_info` (
  `version` int DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `schema_migrations`
--

DROP TABLE IF EXISTS `schema_migrations`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `schema_migrations` (
  `version` varchar(255) COLLATE utf8mb3_unicode_ci NOT NULL,
  PRIMARY KEY (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `send_results_to_couchdbs`
--

DROP TABLE IF EXISTS `send_results_to_couchdbs`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `send_results_to_couchdbs` (
  `id` int NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `serialized_object`
--

DROP TABLE IF EXISTS `serialized_object`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `serialized_object` (
  `serialized_object_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL,
  `description` varchar(5000) DEFAULT NULL,
  `type` varchar(255) NOT NULL,
  `subtype` varchar(255) NOT NULL,
  `serialization_class` varchar(255) NOT NULL,
  `serialized_data` text NOT NULL,
  `date_created` datetime NOT NULL,
  `creator` int NOT NULL,
  `date_changed` datetime DEFAULT NULL,
  `changed_by` int DEFAULT NULL,
  `retired` smallint NOT NULL DEFAULT '0',
  `date_retired` datetime DEFAULT NULL,
  `retired_by` int DEFAULT NULL,
  `retire_reason` varchar(1000) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  PRIMARY KEY (`serialized_object_id`),
  UNIQUE KEY `serialized_object_uuid_index` (`uuid`),
  KEY `serialized_object_creator` (`creator`),
  KEY `serialized_object_changed_by` (`changed_by`),
  KEY `serialized_object_retired_by` (`retired_by`),
  CONSTRAINT `serialized_object_changed_by` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `serialized_object_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `serialized_object_retired_by` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `session_schedule_assignees`
--

DROP TABLE IF EXISTS `session_schedule_assignees`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `session_schedule_assignees` (
  `schedule_assignee_id` int NOT NULL AUTO_INCREMENT,
  `session_schedule_id` int DEFAULT NULL,
  `user_id` int DEFAULT NULL,
  `voided` tinyint DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime(6) DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`schedule_assignee_id`),
  KEY `fk_rails_1ee3ac6033` (`user_id`),
  KEY `fk_rails_24bab59c57` (`session_schedule_id`),
  CONSTRAINT `fk_rails_1ee3ac6033` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`),
  CONSTRAINT `fk_rails_24bab59c57` FOREIGN KEY (`session_schedule_id`) REFERENCES `session_schedules` (`session_schedule_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `session_schedule_vaccines`
--

DROP TABLE IF EXISTS `session_schedule_vaccines`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `session_schedule_vaccines` (
  `schedule_vaccine_id` int NOT NULL AUTO_INCREMENT,
  `session_schedule_id` int DEFAULT NULL,
  `drug_id` int DEFAULT NULL,
  `voided` tinyint DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime(6) DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`schedule_vaccine_id`),
  KEY `fk_rails_376ef33ef5` (`drug_id`),
  KEY `fk_rails_ae93f1e553` (`session_schedule_id`),
  CONSTRAINT `fk_rails_376ef33ef5` FOREIGN KEY (`drug_id`) REFERENCES `drug` (`drug_id`),
  CONSTRAINT `fk_rails_ae93f1e553` FOREIGN KEY (`session_schedule_id`) REFERENCES `session_schedules` (`session_schedule_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `session_schedules`
--

DROP TABLE IF EXISTS `session_schedules`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `session_schedules` (
  `session_schedule_id` int NOT NULL AUTO_INCREMENT,
  `start_date` date NOT NULL,
  `end_date` date NOT NULL,
  `session_type` varchar(255) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `repeat_type` varchar(255) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `voided` tinyint(1) DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime(6) DEFAULT NULL,
  `void_reason` varchar(225) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  `session_name` varchar(255) CHARACTER SET utf8mb3 COLLATE utf8mb3_unicode_ci NOT NULL,
  `location_id` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `frequency` int DEFAULT '0',
  PRIMARY KEY (`session_schedule_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `sessions`
--

DROP TABLE IF EXISTS `sessions`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `sessions` (
  `id` int NOT NULL AUTO_INCREMENT,
  `session_id` varchar(255) DEFAULT NULL,
  `data` text,
  `updated_at` datetime DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `sessions_session_id_index` (`session_id`)
) ENGINE=InnoDB AUTO_INCREMENT=18078 DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `stages`
--

DROP TABLE IF EXISTS `stages`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `stages` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `visit_id` bigint NOT NULL,
  `patient_id` int NOT NULL,
  `stage` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `arrivalTime` datetime(6) DEFAULT NULL,
  `status` tinyint(1) DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  `location_id` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `index_stages_on_visit_id` (`visit_id`),
  KEY `fk_rails_83d1394bef` (`patient_id`),
  CONSTRAINT `fk_rails_83d1394bef` FOREIGN KEY (`patient_id`) REFERENCES `patient` (`patient_id`),
  CONSTRAINT `fk_rails_d319d1fd4f` FOREIGN KEY (`visit_id`) REFERENCES `visits` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `start_date_observation`
--

DROP TABLE IF EXISTS `start_date_observation`;
/*!50001 DROP VIEW IF EXISTS `start_date_observation`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `start_date_observation` AS SELECT 
 1 AS `person_id`,
 1 AS `obs_datetime`,
 1 AS `value_datetime`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `task`
--

DROP TABLE IF EXISTS `task`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `task` (
  `task_id` int NOT NULL AUTO_INCREMENT,
  `url` varchar(255) DEFAULT NULL,
  `encounter_type` varchar(255) DEFAULT NULL,
  `description` text,
  `location` varchar(255) DEFAULT NULL,
  `gender` varchar(50) DEFAULT NULL,
  `has_obs_concept_id` int DEFAULT NULL,
  `has_obs_value_coded` int DEFAULT NULL,
  `has_obs_value_drug` int DEFAULT NULL,
  `has_obs_value_datetime` datetime DEFAULT NULL,
  `has_obs_value_numeric` double DEFAULT NULL,
  `has_obs_value_text` text,
  `has_obs_scope` text,
  `has_program_id` int DEFAULT NULL,
  `has_program_workflow_state_id` int DEFAULT NULL,
  `has_identifier_type_id` int DEFAULT NULL,
  `has_relationship_type_id` int DEFAULT NULL,
  `has_order_type_id` int DEFAULT NULL,
  `has_encounter_type_today` varchar(255) DEFAULT NULL,
  `skip_if_has` smallint DEFAULT '0',
  `sort_weight` double DEFAULT NULL,
  `creator` int NOT NULL,
  `date_created` datetime NOT NULL,
  `voided` smallint DEFAULT '0',
  `voided_by` int DEFAULT NULL,
  `date_voided` datetime DEFAULT NULL,
  `void_reason` varchar(255) DEFAULT NULL,
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `uuid` char(38) DEFAULT NULL,
  PRIMARY KEY (`task_id`),
  KEY `task_creator` (`creator`),
  KEY `user_who_voided_task` (`voided_by`),
  KEY `user_who_changed_task` (`changed_by`),
  CONSTRAINT `task_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_changed_task` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_voided_task` FOREIGN KEY (`voided_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=96 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `tb_status_observations`
--

DROP TABLE IF EXISTS `tb_status_observations`;
/*!50001 DROP VIEW IF EXISTS `tb_status_observations`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `tb_status_observations` AS SELECT 
 1 AS `obs_id`,
 1 AS `person_id`,
 1 AS `concept_id`,
 1 AS `encounter_id`,
 1 AS `order_id`,
 1 AS `obs_datetime`,
 1 AS `location_id`,
 1 AS `obs_group_id`,
 1 AS `accession_number`,
 1 AS `value_group_id`,
 1 AS `value_boolean`,
 1 AS `value_coded`,
 1 AS `value_coded_name_id`,
 1 AS `value_drug`,
 1 AS `value_datetime`,
 1 AS `value_numeric`,
 1 AS `value_modifier`,
 1 AS `value_text`,
 1 AS `date_started`,
 1 AS `date_stopped`,
 1 AS `comments`,
 1 AS `creator`,
 1 AS `date_created`,
 1 AS `voided`,
 1 AS `voided_by`,
 1 AS `date_voided`,
 1 AS `void_reason`,
 1 AS `value_complex`,
 1 AS `uuid`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `traditional_authorities`
--

DROP TABLE IF EXISTS `traditional_authorities`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `traditional_authorities` (
  `id` int NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `traditional_authority`
--

DROP TABLE IF EXISTS `traditional_authority`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `traditional_authority` (
  `traditional_authority_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL DEFAULT '',
  `district_id` int NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`traditional_authority_id`),
  KEY `district_for_ta` (`district_id`),
  KEY `user_who_created_traditional_authority` (`creator`),
  KEY `user_who_retired_traditional_authority` (`retired_by`),
  KEY `retired_status` (`retired`),
  CONSTRAINT `district_for_ta` FOREIGN KEY (`district_id`) REFERENCES `district` (`district_id`),
  CONSTRAINT `user_who_created_traditional_authority` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_traditional_authority` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=519 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `tribe`
--

DROP TABLE IF EXISTS `tribe`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `tribe` (
  `tribe_id` int NOT NULL AUTO_INCREMENT,
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  `name` varchar(50) NOT NULL DEFAULT '',
  PRIMARY KEY (`tribe_id`)
) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `user_programs`
--

DROP TABLE IF EXISTS `user_programs`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `user_programs` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `user_id` bigint DEFAULT NULL,
  `program_id` bigint DEFAULT NULL,
  `voided` int DEFAULT '0',
  `void_reason` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `index_user_programs_on_user_id` (`user_id`),
  KEY `index_user_programs_on_program_id` (`program_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `user_property`
--

DROP TABLE IF EXISTS `user_property`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `user_property` (
  `user_id` int NOT NULL DEFAULT '0',
  `property` varchar(100) NOT NULL DEFAULT '',
  `property_value` text,
  PRIMARY KEY (`user_id`,`property`),
  CONSTRAINT `user_property` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `user_role`
--

DROP TABLE IF EXISTS `user_role`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `user_role` (
  `user_id` int NOT NULL DEFAULT '0',
  `role` varchar(50) NOT NULL DEFAULT '',
  PRIMARY KEY (`role`,`user_id`),
  KEY `user_role` (`user_id`),
  CONSTRAINT `role_definitions` FOREIGN KEY (`role`) REFERENCES `role` (`role`),
  CONSTRAINT `user_role` FOREIGN KEY (`user_id`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `user_villages`
--

DROP TABLE IF EXISTS `user_villages`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `user_villages` (
  `user_village_id` bigint NOT NULL AUTO_INCREMENT,
  `village_id` int NOT NULL,
  `user_id` int NOT NULL,
  `creator` int NOT NULL,
  `retired` int DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime(6) DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  PRIMARY KEY (`user_village_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `users`
--

DROP TABLE IF EXISTS `users`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `users` (
  `user_id` int NOT NULL AUTO_INCREMENT,
  `system_id` varchar(50) NOT NULL DEFAULT '',
  `username` varchar(50) DEFAULT NULL,
  `password` varchar(128) DEFAULT NULL,
  `salt` varchar(128) DEFAULT NULL,
  `secret_question` varchar(255) DEFAULT NULL,
  `secret_answer` varchar(255) DEFAULT NULL,
  `creator` int NOT NULL DEFAULT '0',
  `date_created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `changed_by` int DEFAULT NULL,
  `date_changed` datetime DEFAULT NULL,
  `person_id` int DEFAULT NULL,
  `retired` tinyint NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  `uuid` char(38) NOT NULL,
  `authentication_token` varchar(255) DEFAULT NULL,
  `token_expiry_time` datetime DEFAULT NULL,
  `deactivated_on` datetime DEFAULT NULL,
  `location_id` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`user_id`),
  KEY `user_creator` (`creator`),
  KEY `user_who_changed_user` (`changed_by`),
  KEY `person_id_for_user` (`person_id`),
  KEY `user_who_retired_this_user` (`retired_by`),
  KEY `fk_rails_5d96f79c2b` (`location_id`),
  CONSTRAINT `fk_rails_fa67535741` FOREIGN KEY (`person_id`) REFERENCES `person` (`person_id`),
  CONSTRAINT `person_id_for_user` FOREIGN KEY (`person_id`) REFERENCES `person` (`person_id`),
  CONSTRAINT `user_creator` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_changed_user` FOREIGN KEY (`changed_by`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_this_user` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=635 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `uuid_remaps`
--

DROP TABLE IF EXISTS `uuid_remaps`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `uuid_remaps` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `old_uuid` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `new_uuid` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `database` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `model` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `record_id` int DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `index_uuid_remaps_on_old_uuid` (`old_uuid`),
  KEY `index_uuid_remaps_on_new_uuid` (`new_uuid`),
  KEY `index_uuid_remaps_on_database` (`database`),
  KEY `index_uuid_remaps_on_model` (`model`),
  KEY `index_all_fields` (`old_uuid`,`new_uuid`,`database`,`model`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `validation_results`
--

DROP TABLE IF EXISTS `validation_results`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `validation_results` (
  `id` int NOT NULL AUTO_INCREMENT,
  `rule_id` int DEFAULT NULL,
  `failures` int DEFAULT NULL,
  `date_checked` date DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `validation_rules`
--

DROP TABLE IF EXISTS `validation_rules`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `validation_rules` (
  `id` int NOT NULL AUTO_INCREMENT,
  `expr` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `desc` text COLLATE utf8mb3_unicode_ci,
  `type_id` int DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `village`
--

DROP TABLE IF EXISTS `village`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `village` (
  `village_id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(255) NOT NULL DEFAULT '',
  `traditional_authority_id` int NOT NULL DEFAULT '0',
  `creator` int NOT NULL DEFAULT '0',
  `date_created` datetime NOT NULL DEFAULT '1900-01-01 00:00:00',
  `retired` tinyint(1) NOT NULL DEFAULT '0',
  `retired_by` int DEFAULT NULL,
  `date_retired` datetime DEFAULT NULL,
  `retire_reason` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`village_id`),
  KEY `ta_for_village` (`traditional_authority_id`),
  KEY `user_who_created_village` (`creator`),
  KEY `user_who_retired_village` (`retired_by`),
  KEY `retired_status` (`retired`),
  CONSTRAINT `ta_for_village` FOREIGN KEY (`traditional_authority_id`) REFERENCES `traditional_authority` (`traditional_authority_id`),
  CONSTRAINT `user_who_created_village` FOREIGN KEY (`creator`) REFERENCES `users` (`user_id`),
  CONSTRAINT `user_who_retired_village` FOREIGN KEY (`retired_by`) REFERENCES `users` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=33750 DEFAULT CHARSET=utf8mb3;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `villages`
--

DROP TABLE IF EXISTS `villages`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `villages` (
  `id` int NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `visits`
--

DROP TABLE IF EXISTS `visits`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `visits` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `patientId` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `startDate` datetime(6) DEFAULT NULL,
  `closedDateTime` datetime(6) DEFAULT NULL,
  `programId` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  `created_at` datetime(6) NOT NULL,
  `updated_at` datetime(6) NOT NULL,
  `location_id` varchar(255) COLLATE utf8mb3_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `weight_for_height`
--

DROP TABLE IF EXISTS `weight_for_height`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `weight_for_height` (
  `supinecm` double DEFAULT NULL,
  `medianwtht` double DEFAULT NULL,
  `sdlowwtht` double DEFAULT NULL,
  `sdhighwtht` double DEFAULT NULL,
  `sex` smallint DEFAULT NULL,
  `heightsex` char(5) DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `weight_for_heights`
--

DROP TABLE IF EXISTS `weight_for_heights`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `weight_for_heights` (
  `id` int NOT NULL AUTO_INCREMENT,
  `supine_cm` float DEFAULT NULL,
  `median_weight_height` float DEFAULT NULL,
  `standard_low_weight_height` float DEFAULT NULL,
  `standard_high_weight_height` float DEFAULT NULL,
  `sex` int DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=509 DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `weight_height_for_age`
--

DROP TABLE IF EXISTS `weight_height_for_age`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `weight_height_for_age` (
  `agemths` smallint DEFAULT NULL,
  `sex` smallint DEFAULT NULL,
  `medianht` double DEFAULT NULL,
  `sdlowht` double DEFAULT NULL,
  `sdhighht` double DEFAULT NULL,
  `medianwt` double DEFAULT NULL,
  `sdlowwt` double DEFAULT NULL,
  `sdhighwt` double DEFAULT NULL,
  `agesex` char(4) DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `weight_height_for_ages`
--

DROP TABLE IF EXISTS `weight_height_for_ages`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `weight_height_for_ages` (
  `age_in_months` smallint DEFAULT NULL,
  `sex` char(12) DEFAULT NULL,
  `median_height` double DEFAULT NULL,
  `standard_low_height` double DEFAULT NULL,
  `standard_high_height` double DEFAULT NULL,
  `median_weight` double DEFAULT NULL,
  `standard_low_weight` double DEFAULT NULL,
  `standard_high_weight` double DEFAULT NULL,
  `age_sex` char(4) DEFAULT NULL,
  KEY `index_weight_height_for_ages_on_age_in_months` (`age_in_months`),
  KEY `index_weight_height_for_ages_on_sex` (`sex`)
) ENGINE=MyISAM DEFAULT CHARSET=latin1;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Final view structure for view `all_patient_identifiers`
--

/*!50001 DROP VIEW IF EXISTS `all_patient_identifiers`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `all_patient_identifiers` AS select `patient_identifier`.`patient_id` AS `patient_id`,max((case when (`patient_identifier`.`identifier_type` = 1) then `patient_identifier`.`identifier` end)) AS `openmrs_ident_type`,max((case when (`patient_identifier`.`identifier_type` = 3) then `patient_identifier`.`identifier` end)) AS `national_id`,max((case when (`patient_identifier`.`identifier_type` = 4) then `patient_identifier`.`identifier` end)) AS `arv_number`,max((case when (`patient_identifier`.`identifier_type` = 2) then `patient_identifier`.`identifier` end)) AS `legacy_id`,max((case when (`patient_identifier`.`identifier_type` = 5) then `patient_identifier`.`identifier` end)) AS `prev_art_number`,max((case when (`patient_identifier`.`identifier_type` = 7) then `patient_identifier`.`identifier` end)) AS `tb_number`,max((case when (`patient_identifier`.`identifier_type` = 17) then `patient_identifier`.`identifier` end)) AS `filing_number`,max((case when (`patient_identifier`.`identifier_type` = 18) then `patient_identifier`.`identifier` end)) AS `archived_filing_number`,max((case when (`patient_identifier`.`identifier_type` = 22) then `patient_identifier`.`identifier` end)) AS `pre_art_number` from `patient_identifier` where (`patient_identifier`.`voided` = 0) group by `patient_identifier`.`patient_id` */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `all_patients_attributes`
--

/*!50001 DROP VIEW IF EXISTS `all_patients_attributes`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `all_patients_attributes` AS select `person_attribute`.`person_id` AS `person_id`,max((case when (`person_attribute`.`person_attribute_type_id` = 13) then `person_attribute`.`value` end)) AS `occupation`,max((case when (`person_attribute`.`person_attribute_type_id` = 12) then `person_attribute`.`value` end)) AS `cell_phone`,max((case when (`person_attribute`.`person_attribute_type_id` = 14) then `person_attribute`.`value` end)) AS `home_phone`,max((case when (`person_attribute`.`person_attribute_type_id` = 15) then `person_attribute`.`value` end)) AS `office_phone` from `person_attribute` where (`person_attribute`.`voided` = 0) group by `person_attribute`.`person_id` */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `all_person_addresses`
--

/*!50001 DROP VIEW IF EXISTS `all_person_addresses`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `all_person_addresses` AS select `p`.`person_address_id` AS `person_address_id`,`p`.`person_id` AS `person_id`,`p`.`preferred` AS `preferred`,`p`.`address1` AS `address1`,`p`.`address2` AS `address2`,`p`.`city_village` AS `city_village`,`p`.`state_province` AS `state_province`,`p`.`postal_code` AS `postal_code`,`p`.`country` AS `country`,`p`.`latitude` AS `latitude`,`p`.`longitude` AS `longitude`,`p`.`creator` AS `creator`,`p`.`date_created` AS `date_created`,`p`.`voided` AS `voided`,`p`.`voided_by` AS `voided_by`,`p`.`date_voided` AS `date_voided`,`p`.`void_reason` AS `void_reason`,`p`.`county_district` AS `county_district`,`p`.`neighborhood_cell` AS `neighborhood_cell`,`p`.`region` AS `region`,`p`.`subregion` AS `subregion`,`p`.`township_division` AS `township_division`,`p`.`uuid` AS `uuid` from `person_address` `p` where ((`p`.`person_address_id` = (select max(`pad`.`person_address_id`) from `person_address` `pad` where ((`pad`.`person_id` = `p`.`person_id`) and (`pad`.`voided` = 0)))) and (`p`.`voided` = 0)) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `amount_brought_back_obs`
--

/*!50001 DROP VIEW IF EXISTS `amount_brought_back_obs`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `amount_brought_back_obs` AS select `o`.`person_id` AS `person_id`,`o`.`encounter_id` AS `encounter_id`,`o`.`order_id` AS `order_id`,`o`.`obs_datetime` AS `obs_datetime`,`do`.`drug_inventory_id` AS `drug_inventory_id`,`do`.`equivalent_daily_dose` AS `equivalent_daily_dose`,`o`.`value_numeric` AS `value_numeric`,`do`.`quantity` AS `quantity` from ((`obs` `o` join `drug_order` `do` on((`o`.`order_id` = `do`.`order_id`))) join `arv_drug` `ad` on((`do`.`drug_inventory_id` = `ad`.`drug_id`))) where ((`o`.`concept_id` = 2540) and (`o`.`voided` = 0)) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `amount_dispensed_obs`
--

/*!50001 DROP VIEW IF EXISTS `amount_dispensed_obs`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `amount_dispensed_obs` AS select `o`.`person_id` AS `person_id`,`o`.`encounter_id` AS `encounter_id`,`o`.`order_id` AS `order_id`,`o`.`obs_datetime` AS `obs_datetime`,`do`.`drug_inventory_id` AS `drug_inventory_id`,`do`.`equivalent_daily_dose` AS `equivalent_daily_dose`,`ord`.`start_date` AS `start_date`,`o`.`value_numeric` AS `value_numeric` from (((`obs` `o` join `orders` `ord` on(((`o`.`order_id` = `ord`.`order_id`) and (`ord`.`voided` = 0)))) join `drug_order` `do` on((`ord`.`order_id` = `do`.`order_id`))) join `arv_drug` `ad` on((`do`.`drug_inventory_id` = `ad`.`drug_id`))) where ((`o`.`concept_id` = 2834) and (`o`.`voided` = 0)) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `anc_visit_observations`
--

/*!50001 DROP VIEW IF EXISTS `anc_visit_observations`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `anc_visit_observations` AS select `o`.`person_id` AS `person_id`,`e`.`encounter_id` AS `encounter_id`,`o`.`value_numeric` AS `value_numeric`,`e`.`encounter_datetime` AS `encounter_datetime` from (`encounter` `e` join `obs` `o` on(((`o`.`encounter_id` = `e`.`encounter_id`) and (`e`.`encounter_type` = 107) and (`o`.`concept_id` = 6189)))) where ((`o`.`voided` = 0) and (`e`.`voided` = 0)) order by `o`.`person_id`,`e`.`encounter_datetime` desc */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `arv_drug`
--

/*!50001 DROP VIEW IF EXISTS `arv_drug`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `arv_drug` AS select `drug`.`drug_id` AS `drug_id` from `drug` where `drug`.`concept_id` in (select `concept_set`.`concept_id` from `concept_set` where (`concept_set`.`concept_set` = 1085)) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `arv_drugs_orders`
--

/*!50001 DROP VIEW IF EXISTS `arv_drugs_orders`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `arv_drugs_orders` AS select `ord`.`patient_id` AS `patient_id`,`ord`.`encounter_id` AS `encounter_id`,`ord`.`concept_id` AS `concept_id`,`ord`.`start_date` AS `start_date` from `orders` `ord` where ((`ord`.`voided` = 0) and `ord`.`concept_id` in (select `concept_set`.`concept_id` from `concept_set` where (`concept_set`.`concept_set` = 1085))) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `clinic_consultation_encounter`
--

/*!50001 DROP VIEW IF EXISTS `clinic_consultation_encounter`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `clinic_consultation_encounter` AS select `encounter`.`encounter_id` AS `encounter_id`,`encounter`.`encounter_type` AS `encounter_type`,`encounter`.`patient_id` AS `patient_id`,`encounter`.`provider_id` AS `provider_id`,`encounter`.`location_id` AS `location_id`,`encounter`.`form_id` AS `form_id`,`encounter`.`encounter_datetime` AS `encounter_datetime`,`encounter`.`creator` AS `creator`,`encounter`.`date_created` AS `date_created`,`encounter`.`voided` AS `voided`,`encounter`.`voided_by` AS `voided_by`,`encounter`.`date_voided` AS `date_voided`,`encounter`.`void_reason` AS `void_reason`,`encounter`.`uuid` AS `uuid`,`encounter`.`changed_by` AS `changed_by`,`encounter`.`date_changed` AS `date_changed` from `encounter` where ((`encounter`.`encounter_type` = 53) and (`encounter`.`voided` = 0)) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `clinic_registration_encounter`
--

/*!50001 DROP VIEW IF EXISTS `clinic_registration_encounter`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `clinic_registration_encounter` AS select `encounter`.`encounter_id` AS `encounter_id`,`encounter`.`encounter_type` AS `encounter_type`,`encounter`.`patient_id` AS `patient_id`,`encounter`.`provider_id` AS `provider_id`,`encounter`.`location_id` AS `location_id`,`encounter`.`form_id` AS `form_id`,`encounter`.`encounter_datetime` AS `encounter_datetime`,`encounter`.`creator` AS `creator`,`encounter`.`date_created` AS `date_created`,`encounter`.`voided` AS `voided`,`encounter`.`voided_by` AS `voided_by`,`encounter`.`date_voided` AS `date_voided`,`encounter`.`void_reason` AS `void_reason`,`encounter`.`uuid` AS `uuid`,`encounter`.`changed_by` AS `changed_by`,`encounter`.`date_changed` AS `date_changed` from `encounter` where ((`encounter`.`encounter_type` = 9) and (`encounter`.`voided` = 0)) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `earliest_start_date`
--

/*!50001 DROP VIEW IF EXISTS `earliest_start_date`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `earliest_start_date` AS select `p`.`patient_id` AS `patient_id`,`pe`.`gender` AS `gender`,`pe`.`birthdate` AS `birthdate`,`date_antiretrovirals_started`(`p`.`patient_id`,min(`s`.`start_date`)) AS `earliest_start_date`,cast(`patient_date_enrolled`(`p`.`patient_id`) as date) AS `date_enrolled`,`person`.`death_date` AS `death_date`,(select timestampdiff(YEAR,`pe`.`birthdate`,min(`s`.`start_date`))) AS `age_at_initiation`,(select timestampdiff(DAY,`pe`.`birthdate`,min(`s`.`start_date`))) AS `age_in_days` from (((`patient_program` `p` left join `person` `pe` on((`pe`.`person_id` = `p`.`patient_id`))) left join `patient_state` `s` on((`p`.`patient_program_id` = `s`.`patient_program_id`))) left join `person` on((`person`.`person_id` = `p`.`patient_id`))) where ((`p`.`voided` = 0) and (`s`.`voided` = 0) and (`p`.`program_id` = 1) and (`s`.`state` = 7)) group by `p`.`patient_id` */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `ever_registered_obs`
--

/*!50001 DROP VIEW IF EXISTS `ever_registered_obs`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `ever_registered_obs` AS select `obs`.`obs_id` AS `obs_id`,`obs`.`person_id` AS `person_id`,`obs`.`concept_id` AS `concept_id`,`obs`.`encounter_id` AS `encounter_id`,`obs`.`order_id` AS `order_id`,`obs`.`obs_datetime` AS `obs_datetime`,`obs`.`location_id` AS `location_id`,`obs`.`obs_group_id` AS `obs_group_id`,`obs`.`accession_number` AS `accession_number`,`obs`.`value_group_id` AS `value_group_id`,`obs`.`value_boolean` AS `value_boolean`,`obs`.`value_coded` AS `value_coded`,`obs`.`value_coded_name_id` AS `value_coded_name_id`,`obs`.`value_drug` AS `value_drug`,`obs`.`value_datetime` AS `value_datetime`,`obs`.`value_numeric` AS `value_numeric`,`obs`.`value_modifier` AS `value_modifier`,`obs`.`value_text` AS `value_text`,`obs`.`date_started` AS `date_started`,`obs`.`date_stopped` AS `date_stopped`,`obs`.`comments` AS `comments`,`obs`.`creator` AS `creator`,`obs`.`date_created` AS `date_created`,`obs`.`voided` AS `voided`,`obs`.`voided_by` AS `voided_by`,`obs`.`date_voided` AS `date_voided`,`obs`.`void_reason` AS `void_reason`,`obs`.`value_complex` AS `value_complex`,`obs`.`uuid` AS `uuid` from `obs` where ((`obs`.`concept_id` = 7937) and (`obs`.`voided` = 0) and (`obs`.`value_coded` = 1065)) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `guardians`
--

/*!50001 DROP VIEW IF EXISTS `guardians`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `guardians` AS select `r`.`person_a` AS `patient_id`,`r`.`person_b` AS `guardian_id`,`per`.`gender` AS `gender`,`p`.`given_name` AS `given_name`,`p`.`family_name` AS `family_name`,`p`.`middle_name` AS `middle_name`,`per`.`birthdate_estimated` AS `birthdate_estimated`,`per`.`birthdate` AS `birthdate`,`pa`.`address2` AS `home_district`,`pa`.`state_province` AS `current_district`,`pa`.`address1` AS `landmark`,`pa`.`city_village` AS `current_residence`,`pa`.`county_district` AS `traditional_authority` from (((`relationship` `r` join `person_name` `p` on((`p`.`person_id` = `r`.`person_b`))) left join `all_person_addresses` `pa` on((`pa`.`person_id` = `p`.`person_id`))) join `person` `per` on(((`per`.`person_id` = `p`.`person_id`) and (`p`.`voided` = 0)))) where ((`r`.`voided` = 0) and `r`.`person_a` in (select `e`.`patient_id` from `earliest_start_date` `e`)) order by `r`.`person_a` */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `hiv_status_obs`
--

/*!50001 DROP VIEW IF EXISTS `hiv_status_obs`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `hiv_status_obs` AS select `o`.`person_id` AS `person_id`,`o`.`encounter_id` AS `encounter_id`,ifnull(`o`.`value_coded`,`o`.`value_text`) AS `hiv_status`,`o`.`obs_datetime` AS `obs_datetime` from `obs` `o` where ((`o`.`concept_id` = 3753) and (`o`.`voided` = 0)) order by `o`.`person_id`,`o`.`obs_datetime` desc */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `hiv_test_and_hiv_test_date_obs`
--

/*!50001 DROP VIEW IF EXISTS `hiv_test_and_hiv_test_date_obs`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `hiv_test_and_hiv_test_date_obs` AS select `hs`.`person_id` AS `person_id`,`hs`.`encounter_id` AS `encounter_id`,`hs`.`hiv_status` AS `hiv_status`,`ht`.`hiv_test_date` AS `hiv_test_date`,`ht`.`obs_datetime` AS `obs_datetime` from (`hiv_status_obs` `hs` left join `hiv_test_date_obs` `ht` on(((`hs`.`person_id` = `ht`.`person_id`) and (`hs`.`encounter_id` = `ht`.`encounter_id`) and (cast(`hs`.`obs_datetime` as date) = cast(`ht`.`obs_datetime` as date))))) order by `ht`.`person_id`,`ht`.`obs_datetime` desc */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `hiv_test_date_obs`
--

/*!50001 DROP VIEW IF EXISTS `hiv_test_date_obs`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `hiv_test_date_obs` AS select `obs`.`person_id` AS `person_id`,`obs`.`encounter_id` AS `encounter_id`,ifnull(`obs`.`value_datetime`,`obs`.`value_text`) AS `hiv_test_date`,`obs`.`obs_datetime` AS `obs_datetime` from `obs` where ((`obs`.`concept_id` = 1837) and (`obs`.`voided` = 0)) order by `obs`.`person_id`,`obs`.`obs_datetime` desc */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `last_menstraul_period_date`
--

/*!50001 DROP VIEW IF EXISTS `last_menstraul_period_date`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `last_menstraul_period_date` AS select `obs`.`person_id` AS `person_id`,`obs`.`encounter_id` AS `encounter_id`,`obs`.`value_datetime` AS `lmp`,`obs`.`obs_datetime` AS `obs_datetime`,`obs`.`date_created` AS `date_created` from `obs` where ((`obs`.`concept_id` = 968) and (`obs`.`voided` = 0)) order by `obs`.`person_id`,`obs`.`obs_datetime` desc */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `patient_first_arv_amount_dispensed`
--

/*!50001 DROP VIEW IF EXISTS `patient_first_arv_amount_dispensed`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `patient_first_arv_amount_dispensed` AS select `enc`.`encounter_id` AS `encounter_id`,`enc`.`encounter_type` AS `encounter_type`,`enc`.`patient_id` AS `patient_id`,`enc`.`provider_id` AS `provider_id`,`enc`.`location_id` AS `location_id`,`enc`.`form_id` AS `form_id`,`enc`.`encounter_datetime` AS `encounter_datetime`,`enc`.`creator` AS `creator`,`enc`.`date_created` AS `date_created`,`enc`.`voided` AS `voided`,`enc`.`voided_by` AS `voided_by`,`enc`.`date_voided` AS `date_voided`,`enc`.`void_reason` AS `void_reason`,`enc`.`uuid` AS `uuid`,`enc`.`changed_by` AS `changed_by`,`enc`.`date_changed` AS `date_changed` from `encounter` `enc` where ((`enc`.`encounter_type` = 54) and (`enc`.`voided` = 0) and (cast(`enc`.`encounter_datetime` as date) = (select cast(min(`e`.`encounter_datetime`) as date) from `encounter` `e` where ((`e`.`patient_id` = `enc`.`patient_id`) and (`e`.`encounter_type` = `enc`.`encounter_type`) and (`e`.`voided` = 0))))) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `patient_pregnant_obs`
--

/*!50001 DROP VIEW IF EXISTS `patient_pregnant_obs`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `patient_pregnant_obs` AS select `obs`.`obs_id` AS `obs_id`,`obs`.`person_id` AS `person_id`,`obs`.`concept_id` AS `concept_id`,`obs`.`encounter_id` AS `encounter_id`,`obs`.`order_id` AS `order_id`,`obs`.`obs_datetime` AS `obs_datetime`,`obs`.`location_id` AS `location_id`,`obs`.`obs_group_id` AS `obs_group_id`,`obs`.`accession_number` AS `accession_number`,`obs`.`value_group_id` AS `value_group_id`,`obs`.`value_boolean` AS `value_boolean`,`obs`.`value_coded` AS `value_coded`,`obs`.`value_coded_name_id` AS `value_coded_name_id`,`obs`.`value_drug` AS `value_drug`,`obs`.`value_datetime` AS `value_datetime`,`obs`.`value_numeric` AS `value_numeric`,`obs`.`value_modifier` AS `value_modifier`,`obs`.`value_text` AS `value_text`,`obs`.`date_started` AS `date_started`,`obs`.`date_stopped` AS `date_stopped`,`obs`.`comments` AS `comments`,`obs`.`creator` AS `creator`,`obs`.`date_created` AS `date_created`,`obs`.`voided` AS `voided`,`obs`.`voided_by` AS `voided_by`,`obs`.`date_voided` AS `date_voided`,`obs`.`void_reason` AS `void_reason`,`obs`.`value_complex` AS `value_complex`,`obs`.`uuid` AS `uuid` from (`obs` join `person` on((`person`.`person_id` = `obs`.`person_id`))) where ((`obs`.`concept_id` in (6131,1755,7972)) and (`obs`.`value_coded` = 1065) and (`obs`.`voided` = 0) and (`person`.`gender` = 'F')) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `patient_service_waiting_time`
--

/*!50001 DROP VIEW IF EXISTS `patient_service_waiting_time`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `patient_service_waiting_time` AS select `e`.`patient_id` AS `patient_id`,cast(`e`.`encounter_datetime` as date) AS `visit_date`,min(`e`.`encounter_datetime`) AS `start_time`,max(`e`.`encounter_datetime`) AS `finish_time`,timediff(max(`e`.`encounter_datetime`),min(`e`.`encounter_datetime`)) AS `service_time` from (`encounter` `e` join `encounter` `e2` on(((`e`.`patient_id` = `e2`.`patient_id`) and (`e`.`encounter_type` in (7,9,12,25,51,52,53,54,68))))) where ((`e`.`encounter_datetime` between date_format((now() - interval 7 day),'%Y-%m-%d 00:00:00') and date_format((now() - interval 1 day),'%Y-%m-%d 23:59:59')) and (right(`e`.`encounter_datetime`,2) <> '01') and (right(`e`.`encounter_datetime`,2) <> '01')) group by `e`.`patient_id`,cast(`e`.`encounter_datetime` as date) order by `e`.`patient_id`,`e`.`encounter_datetime` */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `patient_state_on_arvs`
--

/*!50001 DROP VIEW IF EXISTS `patient_state_on_arvs`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `patient_state_on_arvs` AS select `patient_state`.`patient_state_id` AS `patient_state_id`,`patient_state`.`patient_program_id` AS `patient_program_id`,`patient_state`.`state` AS `state`,`patient_state`.`start_date` AS `start_date`,`patient_state`.`end_date` AS `end_date`,`patient_state`.`creator` AS `creator`,`patient_state`.`date_created` AS `date_created`,`patient_state`.`changed_by` AS `changed_by`,`patient_state`.`date_changed` AS `date_changed`,`patient_state`.`voided` AS `voided`,`patient_state`.`voided_by` AS `voided_by`,`patient_state`.`date_voided` AS `date_voided`,`patient_state`.`void_reason` AS `void_reason`,`patient_state`.`uuid` AS `uuid` from `patient_state` where ((`patient_state`.`state` = 7) and (`patient_state`.`voided` = 0)) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `patients_demographics`
--

/*!50001 DROP VIEW IF EXISTS `patients_demographics`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `patients_demographics` AS select `esd`.`patient_id` AS `patient_id`,`p`.`given_name` AS `given_name`,`p`.`family_name` AS `family_name`,`p`.`middle_name` AS `middle_name`,`per`.`gender` AS `gender`,`per`.`birthdate_estimated` AS `birthdate_estimated`,`per`.`birthdate` AS `birthdate`,`pa`.`address2` AS `home_district`,`pa`.`state_province` AS `current_district`,`pa`.`address1` AS `landmark`,`pa`.`city_village` AS `current_residence`,`pa`.`county_district` AS `traditional_authority`,`esd`.`date_enrolled` AS `date_enrolled`,`esd`.`earliest_start_date` AS `earliest_start_date`,`esd`.`death_date` AS `death_date`,`esd`.`age_at_initiation` AS `age_at_initiation`,`esd`.`age_in_days` AS `age_in_days` from (((`earliest_start_date` `esd` join `person_name` `p` on(((`p`.`person_id` = `esd`.`patient_id`) and (`p`.`voided` = 0)))) left join `all_person_addresses` `pa` on(((`pa`.`person_id` = `p`.`person_id`) and (`pa`.`voided` = 0)))) join `person` `per` on(((`per`.`person_id` = `p`.`person_id`) and (`per`.`voided` = 0)))) group by `esd`.`patient_id` order by `esd`.`patient_id` */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `patients_on_arvs`
--

/*!50001 DROP VIEW IF EXISTS `patients_on_arvs`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `patients_on_arvs` AS select `p`.`patient_id` AS `patient_id`,`person`.`birthdate` AS `birthdate`,`date_antiretrovirals_started`(`p`.`patient_id`,min(`s`.`start_date`)) AS `earliest_start_date`,`person`.`death_date` AS `death_date`,`person`.`gender` AS `gender`,((to_days(`date_antiretrovirals_started`(`p`.`patient_id`,min(`s`.`start_date`))) - to_days(`person`.`birthdate`)) / 365.25) AS `age_at_initiation`,(to_days(min(`s`.`start_date`)) - to_days(`person`.`birthdate`)) AS `age_in_days` from ((`patient_program` `p` left join `patient_state` `s` on((`p`.`patient_program_id` = `s`.`patient_program_id`))) left join `person` on((`person`.`person_id` = `p`.`patient_id`))) where ((`p`.`voided` = 0) and (`s`.`voided` = 0) and (`p`.`program_id` = 1) and (`s`.`state` = 7)) group by `p`.`patient_id` */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `patients_with_has_transfer_letter_yes`
--

/*!50001 DROP VIEW IF EXISTS `patients_with_has_transfer_letter_yes`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `patients_with_has_transfer_letter_yes` AS select `o`.`person_id` AS `person_id`,`p`.`gender` AS `gender`,`o`.`obs_datetime` AS `obs_datetime`,`o`.`date_created` AS `date_created`,`e`.`earliest_start_date` AS `earliest_start_date` from ((`obs` `o` join `person` `p` on(((`p`.`person_id` = `o`.`person_id`) and (`p`.`voided` = 0) and (`o`.`voided` = 0)))) join `earliest_start_date` `e` on((`e`.`patient_id` = `o`.`person_id`))) where ((`o`.`concept_id` = 6393) and (`o`.`value_coded` = 1065) and (`o`.`voided` = 0)) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `reason_for_art_eligibility_obs`
--

/*!50001 DROP VIEW IF EXISTS `reason_for_art_eligibility_obs`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `reason_for_art_eligibility_obs` AS select `o`.`person_id` AS `person_id`,`o`.`concept_id` AS `concept_id`,`o`.`obs_datetime` AS `obs_datetime`,`n`.`name` AS `name` from (`obs` `o` left join `concept_name` `n` on(((`n`.`concept_id` = `o`.`value_coded`) and (`n`.`concept_name_type` = 'FULLY_SPECIFIED') and (`n`.`voided` = 0)))) where ((`o`.`concept_id` = 7563) and (`o`.`voided` = 0)) order by `o`.`obs_datetime` desc */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `reason_for_eligibility_obs`
--

/*!50001 DROP VIEW IF EXISTS `reason_for_eligibility_obs`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `reason_for_eligibility_obs` AS select `e`.`patient_id` AS `patient_id`,`n`.`name` AS `reason_for_eligibility`,`o`.`obs_datetime` AS `obs_datetime`,`e`.`earliest_start_date` AS `earliest_start_date`,`e`.`date_enrolled` AS `date_enrolled` from ((`earliest_start_date` `e` left join `obs` `o` on(((`e`.`patient_id` = `o`.`person_id`) and (`o`.`concept_id` = 7563) and (`o`.`voided` = 0)))) left join `concept_name` `n` on(((`n`.`concept_id` = `o`.`value_coded`) and (`n`.`concept_name_type` = 'FULLY_SPECIFIED') and (`n`.`voided` = 0)))) order by `e`.`patient_id`,`o`.`obs_datetime` desc */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `regimen_observation`
--

/*!50001 DROP VIEW IF EXISTS `regimen_observation`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `regimen_observation` AS select `obs`.`obs_id` AS `obs_id`,`obs`.`person_id` AS `person_id`,`obs`.`concept_id` AS `concept_id`,`obs`.`encounter_id` AS `encounter_id`,`obs`.`order_id` AS `order_id`,`obs`.`obs_datetime` AS `obs_datetime`,`obs`.`location_id` AS `location_id`,`obs`.`obs_group_id` AS `obs_group_id`,`obs`.`accession_number` AS `accession_number`,`obs`.`value_group_id` AS `value_group_id`,`obs`.`value_boolean` AS `value_boolean`,`obs`.`value_coded` AS `value_coded`,`obs`.`value_coded_name_id` AS `value_coded_name_id`,`obs`.`value_drug` AS `value_drug`,`obs`.`value_datetime` AS `value_datetime`,`obs`.`value_numeric` AS `value_numeric`,`obs`.`value_modifier` AS `value_modifier`,`obs`.`value_text` AS `value_text`,`obs`.`date_started` AS `date_started`,`obs`.`date_stopped` AS `date_stopped`,`obs`.`comments` AS `comments`,`obs`.`creator` AS `creator`,`obs`.`date_created` AS `date_created`,`obs`.`voided` AS `voided`,`obs`.`voided_by` AS `voided_by`,`obs`.`date_voided` AS `date_voided`,`obs`.`void_reason` AS `void_reason`,`obs`.`value_complex` AS `value_complex`,`obs`.`uuid` AS `uuid` from `obs` where ((`obs`.`concept_id` = 2559) and (`obs`.`voided` = 0)) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `start_date_observation`
--

/*!50001 DROP VIEW IF EXISTS `start_date_observation`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `start_date_observation` AS select `obs`.`person_id` AS `person_id`,`obs`.`obs_datetime` AS `obs_datetime`,`obs`.`value_datetime` AS `value_datetime` from `obs` where ((`obs`.`concept_id` = 2516) and (`obs`.`voided` = 0)) group by `obs`.`person_id`,`obs`.`value_datetime` */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `tb_status_observations`
--

/*!50001 DROP VIEW IF EXISTS `tb_status_observations`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = utf8mb3 */;
/*!50001 SET character_set_results     = utf8mb3 */;
/*!50001 SET collation_connection      = utf8mb3_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY INVOKER */
/*!50001 VIEW `tb_status_observations` AS select `obs`.`obs_id` AS `obs_id`,`obs`.`person_id` AS `person_id`,`obs`.`concept_id` AS `concept_id`,`obs`.`encounter_id` AS `encounter_id`,`obs`.`order_id` AS `order_id`,`obs`.`obs_datetime` AS `obs_datetime`,`obs`.`location_id` AS `location_id`,`obs`.`obs_group_id` AS `obs_group_id`,`obs`.`accession_number` AS `accession_number`,`obs`.`value_group_id` AS `value_group_id`,`obs`.`value_boolean` AS `value_boolean`,`obs`.`value_coded` AS `value_coded`,`obs`.`value_coded_name_id` AS `value_coded_name_id`,`obs`.`value_drug` AS `value_drug`,`obs`.`value_datetime` AS `value_datetime`,`obs`.`value_numeric` AS `value_numeric`,`obs`.`value_modifier` AS `value_modifier`,`obs`.`value_text` AS `value_text`,`obs`.`date_started` AS `date_started`,`obs`.`date_stopped` AS `date_stopped`,`obs`.`comments` AS `comments`,`obs`.`creator` AS `creator`,`obs`.`date_created` AS `date_created`,`obs`.`voided` AS `voided`,`obs`.`voided_by` AS `voided_by`,`obs`.`date_voided` AS `date_voided`,`obs`.`void_reason` AS `void_reason`,`obs`.`value_complex` AS `value_complex`,`obs`.`uuid` AS `uuid` from `obs` where ((`obs`.`concept_id` = 7459) and (`obs`.`voided` = 0)) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2026-01-12 15:42:31
