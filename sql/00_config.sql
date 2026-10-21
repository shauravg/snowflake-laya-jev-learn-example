-- Run this in EACH worksheet/session before the numbered script.
-- EDIT these values explicitly for your lab. Nothing in this package runs itself.
-- Use a NEW, disposable database and roles; never point this at production.
SET lab_db = 'JEV_ZENDESK_LAB_V2'; -- Keep historical v1 data/models in their existing database.
SET lab_wh = 'REPLACE_WITH_EXISTING_WAREHOUSE';
SET participant_user = 'REPLACE_WITH_PARTICIPANT_USER';
SET n_cases = 3000; -- 300 for smoke testing; <= 10000
USE WAREHOUSE IDENTIFIER($lab_wh);
