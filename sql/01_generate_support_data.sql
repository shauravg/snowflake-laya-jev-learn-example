-- Synthetic subset of Zendesk Ticketing API exports, not a connector-specific schema.
-- Run 00_config.sql first in a NEW database. No real tenant or customer data.
USE ROLE JEV_LAB_STEWARD;
USE SECONDARY ROLES NONE;
USE DATABASE IDENTIFIER($lab_db);
USE SCHEMA RAW;

CREATE TABLE ZENDESK_ORGANIZATIONS AS
WITH numbers AS (
 SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS id FROM TABLE(GENERATOR(ROWCOUNT => 10000))
)
SELECT id, 'Fictional Organization ' || id AS name,
       OBJECT_CONSTRUCT('support_plan', CASE MOD(id,3) WHEN 0 THEN 'enterprise'
         WHEN 1 THEN 'premium' ELSE 'basic' END,
         'billing_contact', 'billing' || id || '@example.invalid')::VARIANT AS organization_fields
FROM numbers WHERE id <= CEIL($n_cases / 2.0);

CREATE TABLE ZENDESK_USERS AS
SELECT id, 'Fictional Customer ' || id AS name,
       'customer' || id || '@example.invalid' AS email,
       'SYNTHETIC-PHONE-' || id AS phone, 'end-user' AS role, id AS organization_id,
       OBJECT_CONSTRUCT('account_ref', 'ACCOUNT-' || id)::VARIANT AS user_fields
FROM ZENDESK_ORGANIZATIONS
UNION ALL
SELECT 999999, 'Fictional Agent', 'agent@example.invalid', 'SYNTHETIC-PHONE-999999',
       'agent', NULL, OBJECT_CONSTRUCT();

-- Governance metadata is NOT part of the native Zendesk schema.
CREATE TABLE GOVERNANCE.REQUESTER_SCOPE AS
SELECT id AS requester_id, IFF(MOD(id,2)=0,'WEST','EAST') AS region,
       MOD(id,11) <> 0 AS training_eligible,
       CASE MOD(ABS(HASH(id,20261016)),10)
         WHEN 7 THEN 'validation' WHEN 8 THEN 'calibration' WHEN 9 THEN 'test'
         ELSE 'train' END AS split
FROM ZENDESK_USERS WHERE role = 'end-user';

-- IDs are illustrative tenant configuration, NOT Zendesk standard field IDs.
CREATE TABLE ZENDESK_TICKET_FIELDS AS
SELECT 900001 AS id, 'requires_specialist' AS title, 'checkbox' AS type;
CREATE TABLE GOVERNANCE.LABEL_CONFIG AS
SELECT 900001 AS specialist_field_id, 'zendesk_fields_v2' AS label_mapping_version;

CREATE TABLE ZENDESK_TICKETS AS
WITH numbers AS (
 SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS id FROM TABLE(GENERATOR(ROWCOUNT => 10000))
), factors AS (
 SELECT id, CEIL(id / 2.0)::INTEGER AS requester_id,
        MOD(ABS(HASH(id,'type')),4) AS type_index,
        MOD(ABS(HASH(id,'priority')),4) AS priority_index,
        MOD(ABS(HASH(id,'specialist')),2)=1 AS specialist,
        1 + MOD(ABS(HASH(id,'seats')),900) AS affected_seats,
        1 + MOD(ABS(HASH(id,'duration')),240) AS duration_minutes
 FROM numbers WHERE id <= $n_cases
), described AS (
 SELECT f.*, u.name AS requester_name, u.email, u.phone,
        CASE type_index WHEN 0 THEN 'question' WHEN 1 THEN 'incident'
          WHEN 2 THEN 'problem' ELSE 'task' END AS type,
        CASE priority_index WHEN 0 THEN 'low' WHEN 1 THEN 'normal'
          WHEN 2 THEN 'high' ELSE 'urgent' END AS priority,
        CASE WHEN g.split='test' THEN
          CASE type_index WHEN 0 THEN 'Can you explain how to export my workspace?'
            WHEN 1 THEN 'The application stopped responding in this session.'
            WHEN 2 THEN 'Multiple teams see the same recurring failure; please identify the shared cause.'
            ELSE 'Please arrange the scheduled workspace move.' END
        ELSE
          CASE type_index WHEN 0 THEN 'How do I download a copy of my data?'
            WHEN 1 THEN 'I am reporting a single service interruption.'
            WHEN 2 THEN 'Repeated outages affect several users; investigate the underlying defect.'
            ELSE 'Please complete the planned account migration.' END END AS request_text
 FROM factors f JOIN ZENDESK_USERS u ON u.id=f.requester_id
 JOIN GOVERNANCE.REQUESTER_SCOPE g ON g.requester_id=f.requester_id
)
SELECT id, requester_id, requester_id AS organization_id,
       DATEADD('minute',id,'2026-01-01'::TIMESTAMP_NTZ) AS created_at,
       DATEADD('minute',id+10,'2026-01-01'::TIMESTAMP_NTZ) AS updated_at,
       'Support request from ' || requester_name AS subject,
       'I am ' || requester_name || '. Contact ' || email || ', ' || phone ||
       '; reference ACCOUNT-' || requester_id || '. ' || request_text ||
       ' We have ' || affected_seats || ' affected seats; observed for ' || duration_minutes || ' minutes. ' ||
       CASE priority_index WHEN 0 THEN 'This can wait; there is no deadline.'
         WHEN 1 THEN 'The normal queue is fine.' WHEN 2 THEN 'Please prioritize this today; work is impaired.'
         ELSE 'We are completely blocked and need immediate attention.' END || ' ' ||
       IFF(specialist, 'This requires privileged security changes that only an authorized specialist can make.',
         'Standard documented steps should be sufficient; no privileged changes are required.') AS description,
       type, priority, 'open' AS status,
       ARRAY_CONSTRUCT('triaged', type, priority) AS tags,
       ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('id',900001,'value',specialist),
         OBJECT_CONSTRUCT('id',900002,'value',email)) AS custom_fields
FROM described;

-- Separate as-of INPUT snapshot: subject/description were captured before triage.
-- This synthetic export intentionally freezes these fields; never assume that
-- a current-state ticket export can reconstruct historical input fields.
CREATE TABLE GOVERNANCE.TRIAGE_INPUT_SNAPSHOTS AS
SELECT t.id AS ticket_id, t.requester_id, t.organization_id,
       t.created_at AS input_captured_at, DATEADD('second',30,t.created_at) AS prediction_at,
       t.subject, t.description,
       o.organization_fields:support_plan::VARCHAR AS support_plan,
       t.created_at AS organization_context_at
FROM ZENDESK_TICKETS t JOIN ZENDESK_ORGANIZATIONS o ON o.id=t.organization_id;

CREATE TABLE ZENDESK_TICKET_COMMENTS AS
SELECT id*10+1 AS id, id AS ticket_id, requester_id AS author_id,
       created_at, description AS body, TRUE AS public
FROM ZENDESK_TICKETS
UNION ALL
SELECT id*10+2, id, requester_id, DATEADD('second',20,created_at),
       'I can provide more details if needed.', TRUE FROM ZENDESK_TICKETS
UNION ALL
SELECT id*10+3, id, 999999, updated_at,
       'POST_TRIAGE: recorded type=' || type || ', priority=' || priority ||
       ', requires_specialist=' || custom_fields[0]:value::VARCHAR, FALSE
FROM ZENDESK_TICKETS;
-- ticket_id is the export-added parent key; comments API returns it via endpoint path.
-- No reviewer table. Step 03 reads type/priority/custom_fields directly.
-- No raw SELECT grants: step 02 exposes only safe analyst views.
