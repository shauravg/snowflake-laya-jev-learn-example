-- Run 00_config.sql first. Direct labels from recorded ticket fields, no voting.
USE ROLE JEV_LAB_STEWARD;
USE SECONDARY ROLES NONE;
USE DATABASE IDENTIFIER($lab_db);
USE SCHEMA CURATED;

CREATE TABLE QUESTION_SCHEMA AS
SELECT PARSE_JSON($${
 "ticket_type":{"type":"choice","instructions":"Which Zendesk ticket type fits this request?","criteria":{"question":"A request for information or guidance.","incident":"A single unplanned interruption or failure.","problem":"The underlying cause of one or more recurring incidents.","task":"Planned work or a requested activity."}},
 "urgency":{"type":"score","instructions":"What priority should this ticket receive?","criteria":["Low: no time pressure.","Normal: routine support queue.","High: important work impaired; prioritize today.","Urgent: blocked operations; immediate attention."]},
 "needs_human":{"type":"noul","instructions":"Does this request require an authorized specialist?","criteria":{"false":"Standard documented support is sufficient.","true":"Specialist authority or privileged intervention is required."}}
}$$) AS questions;

-- Require one unique configured checkbox. Stop if the mapping configuration is invalid.
EXECUTE IMMEDIATE $$
DECLARE invalid_config EXCEPTION (-20001, 'Expected one specialist checkbox mapping');
BEGIN
 IF ((SELECT COUNT(*) FROM GOVERNANCE.LABEL_CONFIG) <> 1 OR
     (SELECT COUNT(*) FROM GOVERNANCE.LABEL_CONFIG c JOIN RAW.ZENDESK_TICKET_FIELDS f
      ON f.id=c.specialist_field_id WHERE f.type='checkbox') <> 1) THEN
   RAISE invalid_config;
 END IF;
END;
$$;

-- One audit row per joined source record; duplicate/missing source keys fail closed.
CREATE TABLE GOVERNANCE.LABEL_AUDIT AS
WITH custom_values AS (
 SELECT t.id AS ticket_id, COUNT(*) AS n_values,
        COUNT_IF(TYPEOF(f.value:value)='BOOLEAN') AS n_booleans,
        MAX(IFF(TYPEOF(f.value:value)='BOOLEAN',f.value:value::VARCHAR,NULL)) AS specialist
 FROM RAW.ZENDESK_TICKETS t, LATERAL FLATTEN(input=>t.custom_fields) f,
      GOVERNANCE.LABEL_CONFIG cfg
 WHERE TRY_TO_NUMBER(f.value:id::VARCHAR)=cfg.specialist_field_id
 GROUP BY t.id
), joined AS (
 SELECT t.id AS ticket_id, t.requester_id, t.type, t.priority, t.updated_at AS label_at,
        cfg.specialist_field_id, cfg.label_mapping_version, cv.specialist,
        g.split, g.training_eligible, s.prediction_at,
        COUNT(*) OVER (PARTITION BY t.id) AS joined_rows,
        ARRAY_CONSTRUCT_COMPACT(
          IFF(u.id IS NULL,'MISSING_REQUESTER',NULL),
          IFF(o.id IS NULL,'MISSING_ORGANIZATION',NULL),
          IFF(g.requester_id IS NULL,'MISSING_GOVERNANCE_SCOPE',NULL),
          IFF(NOT COALESCE(g.training_eligible,FALSE),'NOT_TRAINING_ELIGIBLE',NULL),
          IFF(s.ticket_id IS NULL,'MISSING_INPUT_SNAPSHOT',NULL),
          IFF(NOT COALESCE(s.requester_id=t.requester_id AND s.organization_id=t.organization_id,FALSE),'SNAPSHOT_KEY_MISMATCH',NULL),
          IFF(NOT COALESCE(s.input_captured_at<=s.prediction_at AND s.organization_context_at<=s.prediction_at
              AND t.created_at<=s.prediction_at AND t.updated_at>s.prediction_at,FALSE),'INVALID_TIMELINE',NULL),
          IFF(NOT COALESCE(t.type IN ('question','incident','problem','task'),FALSE),'INVALID_TICKET_TYPE',NULL),
          IFF(NOT COALESCE(t.priority IN ('low','normal','high','urgent'),FALSE),'INVALID_PRIORITY',NULL),
          IFF(COALESCE(cv.n_values,0)=0,'MISSING_SPECIALIST_FIELD',NULL),
          IFF(cv.n_values>1,'DUPLICATE_SPECIALIST_FIELD',NULL),
          IFF(cv.n_values=1 AND cv.n_booleans<>1,'INVALID_SPECIALIST_BOOLEAN',NULL),
          IFF(NOT COALESCE(s.support_plan IN ('basic','premium','enterprise'),FALSE),'INVALID_SUPPORT_PLAN',NULL),
          IFF(NULLIF(TRIM(s.subject),'') IS NULL OR NULLIF(TRIM(s.description),'') IS NULL,'MISSING_INPUT_TEXT',NULL)
        ) AS reasons
 FROM RAW.ZENDESK_TICKETS t
 LEFT JOIN RAW.ZENDESK_USERS u ON u.id=t.requester_id
 LEFT JOIN RAW.ZENDESK_ORGANIZATIONS o ON o.id=t.organization_id
 LEFT JOIN GOVERNANCE.REQUESTER_SCOPE g ON g.requester_id=t.requester_id
 LEFT JOIN GOVERNANCE.TRIAGE_INPUT_SNAPSHOTS s ON s.ticket_id=t.id
 LEFT JOIN custom_values cv ON cv.ticket_id=t.id
 CROSS JOIN GOVERNANCE.LABEL_CONFIG cfg
)
SELECT * EXCLUDE reasons,
       IFF(joined_rows<>1,ARRAY_APPEND(reasons,'DUPLICATE_SOURCE_KEY'),reasons) AS reasons
FROM joined;

CREATE TABLE DECISION_LABELS AS
WITH eligible AS (SELECT * FROM GOVERNANCE.LABEL_AUDIT WHERE ARRAY_SIZE(reasons)=0),
labels AS (
 SELECT ticket_id, 'ticket_type' AS question_id, type AS label, 'type' AS source_field,
        label_at, label_mapping_version FROM eligible
 UNION ALL
 SELECT ticket_id, 'urgency', CASE priority WHEN 'low' THEN '0' WHEN 'normal' THEN '1'
          WHEN 'high' THEN '2' WHEN 'urgent' THEN '3' END, 'priority', label_at, label_mapping_version FROM eligible
 UNION ALL
 SELECT ticket_id, 'needs_human', specialist, 'custom_fields[id=' || specialist_field_id || '].value',
        label_at, label_mapping_version FROM eligible
)
SELECT *, $lab_db || '.RAW.ZENDESK_TICKETS' AS source_object,
       ticket_id AS source_record_id FROM labels;

-- Bounded synthetic-pattern sanitizer across every included text surface.
-- Arbitrary user_fields/custom_fields/organization_fields/tags are NOT model inputs.
-- Real exports require reviewed PII detection, not this synthetic-only function.
CREATE FUNCTION GOVERNANCE.SANITIZE_LAB_TEXT(value STRING) RETURNS STRING LANGUAGE SQL AS
$$ REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(value,
   '[A-Za-z0-9._%+-]+@example[.]invalid','[EMAIL]'),
   'SYNTHETIC-PHONE-[0-9]+','[PHONE]'), 'ACCOUNT-[0-9]+','[ACCOUNT]'),
   'Fictional Customer [0-9]+|Fictional Agent','[NAME]'),
   'Fictional Organization [0-9]+','[ORGANIZATION]') $$;

CREATE TABLE GOVERNANCE.SANITIZATION_AUDIT AS
WITH surfaces AS (
 SELECT s.ticket_id, 'subject' AS surface, 0 AS source_id, s.input_captured_at AS sent_at,
        'customer' AS speaker, s.subject AS text
 FROM GOVERNANCE.TRIAGE_INPUT_SNAPSHOTS s
 UNION ALL
 SELECT s.ticket_id, 'description', 0, s.input_captured_at, 'customer', s.description
 FROM GOVERNANCE.TRIAGE_INPUT_SNAPSHOTS s
 UNION ALL
 SELECT m.ticket_id, 'comment', m.id, m.created_at,
        CASE WHEN u.role='end-user' THEN 'customer' WHEN u.role IN ('agent','admin') THEN 'agent' END,
        m.body
 FROM RAW.ZENDESK_TICKET_COMMENTS m
 JOIN GOVERNANCE.TRIAGE_INPUT_SNAPSHOTS s ON s.ticket_id=m.ticket_id
 LEFT JOIN RAW.ZENDESK_USERS u ON u.id=m.author_id
 WHERE m.created_at<=s.prediction_at
   AND NOT COALESCE(m.created_at=s.input_captured_at AND m.body=s.description,FALSE)
), cleaned AS (
 SELECT f.*, GOVERNANCE.SANITIZE_LAB_TEXT(f.text) AS clean_text,
        COUNT(*) OVER (PARTITION BY f.ticket_id,f.surface,f.source_id) AS source_rows
 FROM surfaces f JOIN GOVERNANCE.LABEL_AUDIT a ON a.ticket_id=f.ticket_id
 WHERE ARRAY_SIZE(a.reasons)=0
)
SELECT * EXCLUDE text,
       NULLIF(TRIM(clean_text),'') IS NULL OR speaker IS NULL OR source_rows<>1 OR
       REGEXP_LIKE(clean_text,'.*(@|SYNTHETIC-PHONE-|ACCOUNT-[0-9]|Fictional Customer|Fictional Agent|Fictional Organization|POST_TRIAGE).*','is') AS quarantined
FROM cleaned;

CREATE TABLE SANITIZED_MESSAGES AS
SELECT ticket_id, surface, source_id, sent_at, speaker, clean_text
FROM GOVERNANCE.SANITIZATION_AUDIT
WHERE ticket_id NOT IN (SELECT ticket_id FROM GOVERNANCE.SANITIZATION_AUDIT WHERE quarantined);

CREATE TABLE QUESTION_OPTIONS AS
SELECT q.key::VARCHAR AS question_id, q.value:type::VARCHAR AS question_type,
       COALESCE(o.key,o.index::VARCHAR) AS option_key, o.value::VARCHAR AS description
FROM QUESTION_SCHEMA s, LATERAL FLATTEN(input=>s.questions) q,
     LATERAL FLATTEN(input=>q.value:criteria) o;

-- Hard labels: 1 on the recorded option, 0 elsewhere. NOT epistemic certainty.
CREATE TABLE GOLD_OPTIONS AS
SELECT l.ticket_id, o.question_id, o.question_type, o.option_key,
       IFF(l.label=o.option_key,1.0,0.0)::DOUBLE AS probability
FROM DECISION_LABELS l JOIN QUESTION_OPTIONS o ON l.question_id=o.question_id;

CREATE TABLE TYPED_DECISION_CANDIDATES AS
WITH answers AS (
 SELECT g.ticket_id, g.question_id,
        OBJECT_CONSTRUCT('type',g.question_type,'label',l.label,
          'probabilities',OBJECT_AGG(g.option_key,TO_VARIANT(g.probability)),
          'confidence',1.0,
          'score',IFF(g.question_type='score',TRY_TO_NUMBER(l.label),NULL),
          'noul',IFF(g.question_type='noul',IFF(l.label='true',1.0,0.0),NULL)) AS answer
 FROM GOLD_OPTIONS g JOIN DECISION_LABELS l ON l.ticket_id=g.ticket_id AND l.question_id=g.question_id
 GROUP BY g.ticket_id,g.question_id,g.question_type,l.label
), gold AS (
 SELECT ticket_id, OBJECT_AGG(question_id,answer) AS gold FROM answers GROUP BY ticket_id
), threads AS (
 SELECT ticket_id, ARRAY_AGG(OBJECT_CONSTRUCT('role',speaker,'text',clean_text))
   WITHIN GROUP (ORDER BY sent_at,source_id) AS thread
 FROM SANITIZED_MESSAGES WHERE surface<>'subject' GROUP BY ticket_id
)
SELECT 'zendesk_' || a.ticket_id AS id, 'zendesk_triage' AS workflow, a.split,
       OBJECT_CONSTRUCT('subject',m.clean_text,'organization',OBJECT_CONSTRUCT('support_plan',s.support_plan),
         'thread',t.thread) AS state,
       q.questions, g.gold, SHA2('synthetic-requester-' || a.requester_id,256) AS group_id,
       'zendesk_direct_labels_v2' AS dataset_version, 'recorded_ticket_fields' AS label_source,
       a.label_mapping_version, 'typed_v1' AS schema_version, 'synthetic_patterns_v2' AS redaction_version,
       20261016 AS split_seed
FROM GOVERNANCE.LABEL_AUDIT a
JOIN GOVERNANCE.TRIAGE_INPUT_SNAPSHOTS s ON s.ticket_id=a.ticket_id
JOIN SANITIZED_MESSAGES m ON m.ticket_id=a.ticket_id AND m.surface='subject'
JOIN threads t ON t.ticket_id=a.ticket_id JOIN gold g ON g.ticket_id=a.ticket_id
CROSS JOIN QUESTION_SCHEMA q WHERE ARRAY_SIZE(a.reasons)=0;

-- Identical synthetic states can occur across requesters; reject every copy
-- that crosses a split instead of adding identifying noise to model inputs.
CREATE TABLE GOVERNANCE.STATE_OVERLAP_REJECTIONS AS
SELECT TO_JSON(state) AS state_json FROM TYPED_DECISION_CANDIDATES
GROUP BY TO_JSON(state) HAVING COUNT(DISTINCT split)>1;
CREATE TABLE TYPED_DECISIONS AS
SELECT c.* FROM TYPED_DECISION_CANDIDATES c
WHERE NOT EXISTS (SELECT 1 FROM GOVERNANCE.STATE_OVERLAP_REJECTIONS r WHERE r.state_json=TO_JSON(c.state));
SELECT COUNT(*) AS rejected_duplicate_state_tickets FROM TYPED_DECISION_CANDIDATES c
WHERE EXISTS (SELECT 1 FROM GOVERNANCE.STATE_OVERLAP_REJECTIONS r WHERE r.state_json=TO_JSON(c.state));

GRANT SELECT ON TABLE TYPED_DECISIONS TO ROLE JEV_LAB_ML;
GRANT SELECT ON TABLE QUESTION_SCHEMA TO ROLE JEV_LAB_ML;
CREATE SECURE VIEW INFERENCE_INPUTS AS
SELECT id,state,questions FROM TYPED_DECISIONS WHERE split='test';
GRANT SELECT ON VIEW INFERENCE_INPUTS TO ROLE JEV_LAB_CONSUMER;
GRANT SELECT ON VIEW INFERENCE_INPUTS TO ROLE JEV_LAB_ML;

-- Inspect the field -> label -> gold path and all exclusion counts as steward.
SELECT source_object,source_record_id,source_field,question_id,label,label_at,label_mapping_version
FROM DECISION_LABELS ORDER BY ticket_id,question_id LIMIT 9;
SELECT f.value::VARCHAR AS reason, COUNT(DISTINCT a.ticket_id) AS rejected_tickets
FROM GOVERNANCE.LABEL_AUDIT a, LATERAL FLATTEN(input=>a.reasons) f GROUP BY f.value;
SELECT COUNT(DISTINCT ticket_id) AS quarantined_tickets FROM GOVERNANCE.SANITIZATION_AUDIT WHERE quarantined;
SELECT split,COUNT(*) AS tickets FROM TYPED_DECISIONS GROUP BY split;
-- Violations below must return zero rows.
SELECT ticket_id FROM DECISION_LABELS GROUP BY ticket_id HAVING COUNT(*)<>3 OR COUNT(DISTINCT question_id)<>3;
SELECT ticket_id,question_id FROM GOLD_OPTIONS GROUP BY ticket_id,question_id HAVING SUM(probability)<>1;
SELECT group_id FROM TYPED_DECISIONS GROUP BY group_id HAVING COUNT(DISTINCT split)>1;
SELECT TO_JSON(state) FROM TYPED_DECISIONS GROUP BY TO_JSON(state) HAVING COUNT(DISTINCT split)>1;
SELECT id FROM TYPED_DECISIONS WHERE REGEXP_LIKE(TO_JSON(state),
  '.*(@|SYNTHETIC-PHONE-|ACCOUNT-[0-9]|Fictional Customer|POST_TRIAGE|requires_specialist|custom_fields).*','is');
SELECT m.ticket_id FROM SANITIZED_MESSAGES m JOIN GOVERNANCE.TRIAGE_INPUT_SNAPSHOTS s ON s.ticket_id=m.ticket_id
WHERE m.sent_at>s.prediction_at;
USE ROLE JEV_LAB_ML;
USE SECONDARY ROLES NONE;
SELECT id,state,questions,gold,dataset_version,label_mapping_version FROM TYPED_DECISIONS LIMIT 1;
-- Run separately: expected denied.
-- SELECT * FROM RAW.ZENDESK_TICKETS LIMIT 1;
-- SELECT * FROM CURATED.DECISION_LABELS LIMIT 1;
-- SELECT * FROM GOVERNANCE.SANITIZATION_AUDIT LIMIT 1;
